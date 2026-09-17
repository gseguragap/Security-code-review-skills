#!/usr/bin/env python3
"""Regression tests for cost measurement.

    python tests/test_cost.py [--verbose]

The property under test is honesty, not arithmetic. A collector that cannot determine its
window MUST say so. The failure this pins down: when a watermark could not be resolved,
report mode used to rescan the whole transcript from line 1 and still label the result
`"source": "transcript"` - billing an entire session to one audit phase and presenting it
as measured. In a long session that overstates by more than an order of magnitude, silently.

Also pinned here:
  * streaming partials of one assistant message are counted once, not three times
  * the collectors (python / bash+awk / PowerShell) agree on the same transcript
  * the merge helpers produce byte-identical findings documents
  * merge refuses, without touching the file, when the placeholder is absent

Standard library only. Collectors absent from this machine are skipped, never failed.

Exit code 0 = all green. Non-zero = something regressed.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin"
ESC = chr(27)
GREEN, RED, YELLOW, DIM, RESET = f"{ESC}[32m", f"{ESC}[31m", f"{ESC}[33m", f"{ESC}[2m", f"{ESC}[0m"
NL = chr(10)
TAB = chr(9)

PASSED: list = []
FAILED: list = []
SKIPPED: list = []


def msg(i: int, inp: int = 100, out: int = 1000, read: int = 10000) -> str:
    """One assistant record, in the compact shape the collectors match on."""
    return json.dumps({
        "type": "assistant",
        "message": {
            "id": f"msg_{i}",
            "model": "claude-opus-5",
            "usage": {"input_tokens": inp, "output_tokens": out,
                      "cache_read_input_tokens": read},
        },
    }, separators=(",", ":"))


def collectors() -> dict:
    """name -> callable(outdir) returning argv for `--report --out <outdir>`."""
    found = {}
    if sys.executable and (BIN / "cost.py").is_file():
        found["python"] = lambda d: [sys.executable, str(BIN / "cost.py"),
                                     "--report", "--out", str(d)]
    bash = shutil.which("bash")
    if bash and shutil.which("awk") and (BIN / "collect-cost.sh").is_file():
        found["bash"] = lambda d: [bash, str(BIN / "collect-cost.sh"),
                                   "--report", "--out", str(d)]
    ps = shutil.which("powershell") if os.name == "nt" else None
    if ps and (BIN / "collect-cost.ps1").is_file():
        found["powershell"] = lambda d: [ps, "-NoProfile", "-ExecutionPolicy", "Bypass",
                                         "-File", str(BIN / "collect-cost.ps1"),
                                         "-Report", "-Out", str(d)]
    return found


def mergers(cost_file: Path) -> dict:
    """name -> callable(findings_path) returning argv for the merge helper."""
    found = {}
    if sys.executable and (BIN / "merge-cost.py").is_file():
        found["python"] = lambda f: [sys.executable, str(BIN / "merge-cost.py"),
                                     "--findings", str(f), "--cost", str(cost_file)]
    bash = shutil.which("bash")
    if bash and shutil.which("awk") and (BIN / "merge-cost.sh").is_file():
        found["bash"] = lambda f: [bash, str(BIN / "merge-cost.sh"),
                                   "--findings", str(f), "--cost", str(cost_file)]
    ps = shutil.which("powershell") if os.name == "nt" else None
    if ps and (BIN / "merge-cost.ps1").is_file():
        found["powershell"] = lambda f: [ps, "-NoProfile", "-ExecutionPolicy", "Bypass",
                                         "-File", str(BIN / "merge-cost.ps1"),
                                         "-Findings", str(f), "-Cost", str(cost_file)]
    return found


def run_report(argv: list, outdir: Path, watermark) -> dict:
    outdir.mkdir(parents=True, exist_ok=True)
    if watermark is not None:
        (outdir / "cost-watermark").write_text(watermark + NL, encoding="utf-8")
    subprocess.run(argv, capture_output=True, timeout=180)
    cj = outdir / "cost.json"
    if not cj.is_file():
        return {"source": "<no cost.json written>"}
    try:
        return json.loads(cj.read_text(encoding="utf-8"))
    except ValueError as exc:
        return {"source": f"<unparseable: {exc}>"}


def check(label: str, cond: bool, detail: str = "", verbose: bool = False) -> None:
    if cond:
        PASSED.append(label)
        if verbose:
            print(f"  {GREEN}PASS{RESET}  {label}")
    else:
        FAILED.append((label, detail))
        print(f"  {RED}FAIL{RESET}  {label}  {DIM}{detail}{RESET}")


def total_cost(doc: dict):
    return (doc.get("totals") or {}).get("totalCostUSD")


def total_tokens(doc: dict):
    return (doc.get("totals") or {}).get("totalTokens")


def test_honesty_guards(impls: dict, tmp: Path, transcript: Path, verbose: bool) -> None:
    """Every unresolvable window must report unavailable, with a reason and no number."""
    stamp = "2026-01-01T00:00:00Z"
    cases = [
        ("no watermark at all", None),
        ("watermark says unavailable", f"unavailable{TAB}0{TAB}{stamp}"),
        ("watermark malformed", "garbage-with-no-tabs"),
        ("recorded transcript gone", f"{tmp / 'gone.jsonl'}{TAB}5{TAB}{stamp}"),
        ("watermark past EOF", f"{transcript}{TAB}99999{TAB}{stamp}"),
        ("window spans no turns", f"{transcript}{TAB}3{TAB}{stamp}"),
    ]
    for n, (label, wm) in enumerate(cases):
        for name, build in sorted(impls.items()):
            d = tmp / f"guard{n}_{name}"
            doc = run_report(build(d), d, wm)
            src = doc.get("source")
            check(f"[{name}] {label} -> unavailable", src == "unavailable",
                  f"got source={src!r} cost={total_cost(doc)!r}", verbose)
            if src == "unavailable":
                check(f"[{name}] {label} -> no dollar figure", total_cost(doc) is None,
                      f"got {total_cost(doc)!r}", verbose)
                check(f"[{name}] {label} -> states a reason", bool(doc.get("reason")),
                      "no reason field", verbose)


def test_measured_path(impls: dict, tmp: Path, transcript: Path, verbose: bool) -> None:
    """A resolvable watermark prices the window exactly, and all collectors agree."""
    stamp = "2026-01-01T00:00:00Z"
    # 3 messages x (100 input + 10000 cache read + 1000 output)
    want_tokens = 3 * (100 + 10000 + 1000)
    want_cost = round(300 * 5.0 / 1e6 + 30000 * 0.5 / 1e6 + 3000 * 25.0 / 1e6, 4)

    seen = {}
    for name, build in sorted(impls.items()):
        d = tmp / f"ok_{name}"
        doc = run_report(build(d), d, f"{transcript}{TAB}0{TAB}{stamp}")
        seen[name] = doc
        check(f"[{name}] valid watermark -> measured", doc.get("source") == "transcript",
              f"got {doc.get('source')!r}", verbose)
        check(f"[{name}] token total is exact", total_tokens(doc) == want_tokens,
              f"want {want_tokens}, got {total_tokens(doc)}", verbose)
        c = total_cost(doc)
        check(f"[{name}] dollar total is exact", c is not None and abs(c - want_cost) < 1e-6,
              f"want {want_cost}, got {c}", verbose)

    if len(seen) > 1:
        totals = {n: total_tokens(d) for n, d in seen.items()}
        check("collectors agree on token total", len(set(totals.values())) == 1, repr(totals), verbose)


def test_dedup(impls: dict, tmp: Path, verbose: bool) -> None:
    """One message written three times as streaming partials must be counted once."""
    dup = tmp / "dup.jsonl"
    dup.write_text(NL.join([
        msg(1, inp=50, out=10, read=5000),
        msg(1, inp=100, out=500, read=10000),
        msg(1, inp=100, out=1000, read=10000),
    ]) + NL, encoding="utf-8")

    for name, build in sorted(impls.items()):
        d = tmp / f"dup_{name}"
        doc = run_report(build(d), d, f"{dup}{TAB}0{TAB}2026-01-01T00:00:00Z")
        by = (doc.get("byModel") or [{}])[0]
        check(f"[{name}] streaming partials counted once",
              by.get("messages") == 1 and total_tokens(doc) == 11100,
              f"messages={by.get('messages')} tokens={total_tokens(doc)}", verbose)


def test_merge(tmp: Path, verbose: bool) -> None:
    """Merge helpers agree byte for byte, and refuse a document with no placeholder."""
    cost_file = tmp / "m_cost.json"
    cost_file.write_text(
        "{" + NL +
        '  "source": "transcript",' + NL +
        '  "totals": { "totalTokens": 1, "totalCostUSD": 0.5 }' + NL +
        "}" + NL, encoding="utf-8")

    findings_src = ("{" + NL +
                    '  "meta": { "projectName": "T" },' + NL +
                    '  "findings": [],' + NL +
                    '  "cost": {},' + NL +
                    '  "limitations": []' + NL +
                    "}" + NL)

    impls = mergers(cost_file)
    if not impls:
        SKIPPED.append("merge helpers")
        return

    digests = {}
    for name, build in sorted(impls.items()):
        f = tmp / f"findings_{name}.json"
        f.write_text(findings_src, encoding="utf-8")
        subprocess.run(build(f), capture_output=True, timeout=120)
        raw = f.read_bytes()
        digests[name] = raw
        try:
            doc = json.loads(raw.decode("utf-8"))
            ok = ((doc.get("cost") or {}).get("totals") or {}).get("totalCostUSD") == 0.5
            detail = ""
        except ValueError as exc:
            ok, detail = False, str(exc)
        check(f"[{name}] merge yields valid JSON carrying the cost block", ok, detail, verbose)

    if len(digests) > 1:
        check("merge helpers are byte-identical", len(set(digests.values())) == 1,
              "outputs differ between implementations", verbose)

    for name, build in sorted(impls.items()):
        f = tmp / f"nop_{name}.json"
        original = "{" + NL + '  "meta": {}' + NL + "}" + NL
        f.write_text(original, encoding="utf-8")
        r = subprocess.run(build(f), capture_output=True, timeout=120)
        unchanged = f.read_text(encoding="utf-8") == original
        check(f"[{name}] missing placeholder is refused and file untouched",
              r.returncode == 65 and unchanged,
              f"rc={r.returncode} unchanged={unchanged}", verbose)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    impls = collectors()
    if not impls:
        print(f"{RED}No cost collector is runnable on this machine.{RESET}")
        return 1
    print(f"Collectors under test: {', '.join(sorted(impls))}")
    for name in ("python", "bash", "powershell"):
        if name not in impls:
            SKIPPED.append(f"collector:{name}")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        transcript = tmp / "session.jsonl"
        transcript.write_text(NL.join(msg(i) for i in (1, 2, 3)) + NL, encoding="utf-8")

        test_honesty_guards(impls, tmp, transcript, args.verbose)
        test_measured_path(impls, tmp, transcript, args.verbose)
        test_dedup(impls, tmp, args.verbose)
        test_merge(tmp, args.verbose)

    print()
    if SKIPPED:
        print(f"{YELLOW}skipped:{RESET} {', '.join(SKIPPED)}")
    if FAILED:
        print(f"{RED}{len(FAILED)} failed{RESET}, {len(PASSED)} passed")
        for label, detail in FAILED:
            print(f"  - {label}: {detail}")
        return 1
    print(f"{GREEN}all {len(PASSED)} cost checks passed{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
