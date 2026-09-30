#!/usr/bin/env python3
"""Regression tests for the comparison phase gate.

    python tests/test_phase_gate.py [--verbose]

The property under test is the golden rule of the modernization flow: the comparison may start
only after the Legacy audit and then the Modernized audit have each written their report. Every
layout below builds a project folder the way security-code-review does, breaks one part of that
rule, and requires the gate to refuse (exit 3) - plus the one complete layout it must pass.

Both twins (bash, PowerShell) run against every case; one absent from this machine is skipped.
Standard library only. Exit code 0 = all green.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin"
ESC = chr(27)
GREEN, RED, YELLOW, DIM, RESET = f"{ESC}[32m", f"{ESC}[31m", f"{ESC}[33m", f"{ESC}[2m", f"{ESC}[0m"

FINDINGS = '{\n  "meta": {"projectName": "Acme"},\n  "scores": {},\n  "findings": [],\n  "cost": %s\n}\n'
REPORT = "Acme - %s - Security analysis report. - 2026-09-29.html"

PASSED: list = []
FAILED: list = []


def gates() -> dict:
    found = {}
    bash = shutil.which("bash")
    if bash and (BIN / "phase-gate.sh").is_file():
        found["bash"] = lambda l, m: [bash, str(BIN / "phase-gate.sh"), "--legacy", str(l), "--modernized", str(m)]
    ps = shutil.which("powershell") if os.name == "nt" else None
    if ps and (BIN / "phase-gate.ps1").is_file():
        found["powershell"] = lambda l, m: [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                                            str(BIN / "phase-gate.ps1"), "-Legacy", str(l), "-Modernized", str(m)]
    return found


def stamp(p: Path, t: float) -> None:
    os.utime(p, (t, t))


def build(root: Path, *, legacy_done=True, legacy_report=True, modern_done=True,
          modern_report=True, modern_before_legacy=False, stale_report=False) -> tuple[Path, Path]:
    """A project folder in the orchestrated layout, timestamps set explicitly so order is exact."""
    sa = root / ".security-audit"
    (sa / "legacy").mkdir(parents=True)
    (sa / "modernized").mkdir(parents=True)
    t = time.time() - 1000
    lf, mf = sa / "legacy" / "findings.json", sa / "modernized" / "findings.json"

    (sa / "legacy" / "cost-watermark").write_text("x\n"); stamp(sa / "legacy" / "cost-watermark", t)
    lf.write_text(FINDINGS % ('{"source": "transcript"}' if legacy_done else "{}"), encoding="utf-8")
    stamp(lf, t + 10)
    if legacy_report:
        r = root / (REPORT % "Legacy"); r.write_text("<html></html>")
        stamp(r, t + 5 if stale_report else t + 20)

    mt = t + 15 if modern_before_legacy else t + 30
    (sa / "modernized" / "cost-watermark").write_text("x\n"); stamp(sa / "modernized" / "cost-watermark", mt)
    mf.write_text(FINDINGS % ('{"source": "transcript"}' if modern_done else "{}"), encoding="utf-8")
    stamp(mf, t + 40)
    if modern_report:
        r = root / (REPORT % "Modernized"); r.write_text("<html></html>"); stamp(r, t + 50)
    return lf, mf


# label, layout options, expected exit code, text the refusal must contain (the right reason)
CASES = [
    ("both audits complete, in order", {}, 0, "PASS"),
    ("modernized audit never ran", {"modern_done": None}, 3, "Modernized findings document not found"),
    ("modernized findings written, cost not merged", {"modern_done": False}, 3, "Modernized audit has not finished"),
    ("modernized report not rendered yet", {"modern_report": False}, 3, "Modernized report not found"),
    ("legacy report missing", {"legacy_report": False}, 3, "Legacy report not found"),
    ("legacy cost not merged", {"legacy_done": False}, 3, "Legacy audit has not finished"),
    ("modernized started before the legacy report", {"modern_before_legacy": True}, 3, "started before the Legacy report"),
    ("legacy report older than its findings", {"stale_report": True}, 3, "older than its findings"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    impls = gates()
    if not impls:
        print(f"{RED}No phase gate is runnable on this machine.{RESET}")
        return 1
    print(f"Gates under test: {', '.join(sorted(impls))}")

    with tempfile.TemporaryDirectory() as td:
        for n, (label, opts, want, reason) in enumerate(CASES):
            for name, argv in sorted(impls.items()):
                root = Path(td) / f"c{n}_{name}" / "Acme"
                missing_modern = opts.get("modern_done", True) is None
                kw = {k: v for k, v in opts.items() if not (k == "modern_done" and v is None)}
                lf, mf = build(root, **kw)
                if missing_modern:
                    mf.unlink()
                r = subprocess.run(argv(lf, mf), capture_output=True, text=True, timeout=120)
                ok = r.returncode == want and reason in (r.stdout + r.stderr)
                tag = f"[{name}] {label} -> {'PASS' if want == 0 else 'BLOCKED'}"
                if ok:
                    PASSED.append(tag)
                    if args.verbose:
                        print(f"  {GREEN}PASS{RESET}  {tag}  {DIM}{(r.stdout or r.stderr).strip().splitlines()[0]}{RESET}")
                else:
                    FAILED.append(tag)
                    print(f"  {RED}FAIL{RESET}  {tag}  {DIM}rc={r.returncode} {r.stdout.strip()} {r.stderr.strip()}{RESET}")

    print()
    if FAILED:
        print(f"{RED}{len(FAILED)} failed{RESET}, {len(PASSED)} passed")
        return 1
    print(f"{GREEN}all {len(PASSED)} phase-gate checks passed{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
