#!/usr/bin/env python3
"""Measure the token and dollar cost of a security-audit run.

    cost.py --mark   --out <dir> [--transcript FILE]
    cost.py --report --out <dir> [--transcript FILE] [--pricing pricing.json]

Preferred implementation when a Python is available (see bin/ensure_python.*). The bash+awk
and PowerShell collectors remain as fallbacks and produce byte-identical cost.json; all three
are held to that by tests. Nothing here is imported from outside the standard library.

What this buys over the awk version: pricing.json is parsed by a real JSON parser, so it no
longer has to keep one model per line, and unusual model ids cannot silently break the lookup.

Accuracy notes:
  * A single assistant message is written to the transcript several times (streaming partials
    plus a final record). Summing every line overstates cost by 2-3x, so records are keyed by
    message id and the MAXIMUM value seen per field is kept.
  * 5-minute and 1-hour cache writes bill at different multiples of the input rate and are
    tracked separately.
  * Anything that cannot be determined is reported as such rather than guessed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

MIN_FIELDS = ("input", "w5", "w1", "read", "output", "cc")

RE_ID = re.compile(r'"id":"(msg_[^"]*)"')
RE_MODEL = re.compile(r'"model":"([^"]*)"')
RE_FIELD = {
    "input": re.compile(r'"input_tokens":(\d+)'),
    "output": re.compile(r'"output_tokens":(\d+)'),
    "read": re.compile(r'"cache_read_input_tokens":(\d+)'),
    "w5": re.compile(r'"ephemeral_5m_input_tokens":(\d+)'),
    "w1": re.compile(r'"ephemeral_1h_input_tokens":(\d+)'),
    "cc": re.compile(r'"cache_creation_input_tokens":(\d+)'),
}


def write_text_lf(path: Path, text: str) -> None:
    """Write text with LF endings on every platform.

    The watermark is read back by whichever collector runs at report time, which may not be
    this one. A CRLF watermark leaves a trailing CR in the timestamp, and that CR lands inside
    cost.json as a raw control character - invalid JSON, found only downstream.
    """
    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def write_cost_json(path: Path, doc: dict) -> None:
    """Write cost.json as UTF-8 with LF endings, matching the awk and PowerShell twins."""
    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(json.dumps(doc, indent=2) + chr(10))


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def claude_home() -> Path:
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(norm_path(cfg)) if cfg else Path.home() / ".claude"


def norm_path(p: str | None) -> str:
    """Accept MSYS/Git-Bash paths on Windows.

    The bash collector runs under Git Bash and records paths as /c/Users/... . Native Python
    cannot open those, and silently falling back to a full-file scan would inflate the reported
    cost by an order of magnitude - so translate rather than fail. Harmless elsewhere: a real
    POSIX path only matches this shape if /c/ genuinely exists, which is checked first.
    """
    if not p:
        return ""
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])/(.*)$", p)
        if m and not Path(p).exists():
            return f"{m.group(1).upper()}:\\" + m.group(2).replace("/", "\\")
    return p


def find_transcript(explicit: str | None) -> Path | None:
    cand = norm_path(explicit)
    if cand and Path(cand).is_file():
        return Path(cand)
    env = norm_path(os.environ.get("CLAUDE_TRANSCRIPT"))
    if env and Path(env).is_file():
        return Path(env)
    base = claude_home() / "projects"
    if not base.is_dir():
        return None
    # The live session's transcript is the most recently written top-level .jsonl,
    # because it is being appended to right now.
    best, best_mtime = None, -1.0
    for proj in base.iterdir():
        if not proj.is_dir():
            continue
        for f in proj.glob("*.jsonl"):
            try:
                m = f.stat().st_mtime
            except OSError:
                continue
            if m > best_mtime:
                best, best_mtime = f, m
    return best


def scan(path: Path, skip: int, msgs: dict) -> int:
    """Accumulate per-message maxima from a transcript, skipping the first `skip` lines.

    Returns the total number of lines in the file - the caller uses it to tell a live
    transcript from one that has been rotated out from under a watermark.
    """
    n = 0
    try:
        fh = path.open("r", encoding="utf-8", errors="replace")
    except OSError:
        return 0
    with fh:
        for n, line in enumerate(fh, start=1):
            if n <= skip:
                continue
            if '"type":"assistant"' not in line:
                continue
            m = RE_ID.search(line)
            if not m:
                continue
            mid = m.group(1)
            rec = msgs.get(mid)
            if rec is None:
                rec = msgs[mid] = {"model": "unknown", **{k: 0 for k in MIN_FIELDS}}
            mm = RE_MODEL.search(line)
            if mm:
                rec["model"] = mm.group(1)
            for key, rx in RE_FIELD.items():
                hit = rx.search(line)
                if hit:
                    v = int(hit.group(1))
                    if v > rec[key]:
                        rec[key] = v
    return n


def load_pricing(path: Path) -> tuple[dict, str]:
    if not path.is_file():
        return {}, "unknown"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"cost.py: pricing file unreadable ({exc}); costs will be null", file=sys.stderr)
        return {}, "unknown"
    return doc.get("models", {}) or {}, doc.get("pricingVersion", "unknown")


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--mark", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--out", required=True)
    ap.add_argument("--transcript")
    ap.add_argument("--pricing")
    args = ap.parse_args()

    if args.mark == args.report:
        print("cost.py: pass exactly one of --mark / --report", file=sys.stderr)
        return 64

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    mark_file = out / "cost-watermark"
    cost_file = out / "cost.json"

    # ------------------------------------------------------------------ mark
    if args.mark:
        t = find_transcript(args.transcript)
        stamp = utcnow()
        if t is None:
            write_text_lf(mark_file, f"unavailable\t0\t{stamp}\n")
            print("cost.py: no transcript found; cost will be reported as unavailable.", file=sys.stderr)
            return 0
        with t.open("r", encoding="utf-8", errors="replace") as fh:
            lines = sum(1 for _ in fh)
        write_text_lf(mark_file, f"{t}\t{lines}\t{stamp}\n")
        print(f"cost.py: watermark set at line {lines} of {t}")
        return 0

    # ---------------------------------------------------------------- report
    # A measured figure is only ever produced from a watermark that still resolves.
    # Every other path reports "unavailable". Falling back to a full-transcript rescan
    # would bill the whole session to the audit and label it measured - the single worst
    # failure this tool can have, because it is silent and confidently wrong.
    started, skip, t = "unknown", 0, None

    def unmeasured(why: str) -> int:
        write_cost_json(cost_file, {
            "source": "unavailable",
            "reason": why,
            "startedAt": started,
            "finishedAt": utcnow(),
            "byModel": [],
            "totals": {"totalTokens": 0, "totalCostUSD": None},
            "note": ("Cost was not measured. Supply an estimate and set source to 'estimate', or "
                     "state that cost is unavailable. Do not present an unmeasured figure as measured."),
        })
        print(f"cost.py: {why} - wrote cost.json with source=unavailable", file=sys.stderr)
        return 0

    if not mark_file.is_file():
        return unmeasured("No cost-watermark in the output directory: the run never marked a start "
                          "point, so there is no window to measure.")

    parts = mark_file.read_text(encoding="utf-8").splitlines()[0].split("\t")
    if len(parts) < 3:
        return unmeasured("The cost-watermark is malformed and cannot be read.")
    started = parts[2]
    if parts[0] == "unavailable":
        return unmeasured("No session transcript was found when the watermark was set.")

    skip = int(parts[1] or 0)
    cand = Path(norm_path(parts[0]))
    if cand.is_file():
        t = cand
    elif args.transcript and Path(norm_path(args.transcript)).is_file():
        # An explicit --transcript may point at a transcript that has moved. The recorded
        # offset is still honoured: a line number means nothing against a file it was not
        # taken from, so this relocates the same file - it never selects a different session.
        t = Path(norm_path(args.transcript))
    else:
        return unmeasured("The transcript recorded in the watermark is no longer readable "
                          f"({parts[0]}).")

    finished = utcnow()

    msgs: dict = {}
    total_lines = scan(t, skip, msgs)
    if skip > total_lines:
        return unmeasured(f"The watermark starts at line {skip} but the transcript now holds only "
                          f"{total_lines} lines: it was rotated or truncated mid-run.")

    # Subagent transcripts written after the mark.
    sub = t.with_suffix("") / "subagents"
    if sub.is_dir():
        mark_mtime = mark_file.stat().st_mtime if mark_file.is_file() else 0.0
        for sf in sub.glob("*.jsonl"):
            try:
                if sf.stat().st_mtime < mark_mtime:
                    continue
            except OSError:
                continue
            scan(sf, 0, msgs)

    if not msgs:
        return unmeasured(f"No assistant turns were found after line {skip} of the transcript. "
                          "The watermark does not line up with this session, so no cost can be "
                          "attributed to it.")

    agg: dict = {}
    for rec in msgs.values():
        w5, w1 = rec["w5"], rec["w1"]
        # No per-TTL breakdown (older transcript): attribute to the 5-minute rate, the cheaper
        # of the two. This understates rather than overstates - the honest way to err.
        if w5 == 0 and w1 == 0 and rec["cc"] > 0:
            w5 = rec["cc"]
        a = agg.setdefault(rec["model"], {"messages": 0, "input": 0, "w5": 0, "w1": 0, "read": 0, "output": 0})
        a["messages"] += 1
        a["input"] += rec["input"]
        a["w5"] += w5
        a["w1"] += w1
        a["read"] += rec["read"]
        a["output"] += rec["output"]

    pricing_path = Path(args.pricing) if args.pricing else Path(__file__).resolve().parent.parent / "assets" / "pricing.json"
    rates, pricing_version = load_pricing(pricing_path)

    by_model, grand_tokens, grand_cost, unpriced = [], 0, 0.0, 0
    for model in sorted(agg):
        a = agg[model]
        total_tokens = a["input"] + a["w5"] + a["w1"] + a["read"] + a["output"]
        grand_tokens += total_tokens
        tokens = {
            "input": a["input"], "cacheWrite5m": a["w5"], "cacheWrite1h": a["w1"],
            "cacheRead": a["read"], "output": a["output"], "total": total_tokens,
        }
        r = rates.get(model)
        if not r:
            unpriced += 1
            by_model.append({"model": model, "priced": False, "messages": a["messages"],
                             "tokens": tokens, "rates": None, "costUSD": None})
            continue
        c = {
            "input": a["input"] * float(r["input"]) / 1_000_000,
            "cacheWrite5m": a["w5"] * float(r["cacheWrite5m"]) / 1_000_000,
            "cacheWrite1h": a["w1"] * float(r["cacheWrite1h"]) / 1_000_000,
            "cacheRead": a["read"] * float(r["cacheRead"]) / 1_000_000,
            "output": a["output"] * float(r["output"]) / 1_000_000,
        }
        c["total"] = sum(c.values())
        grand_cost += c["total"]
        by_model.append({
            "model": model, "priced": True, "messages": a["messages"], "tokens": tokens,
            "rates": {k: round(float(r[k]), 2) for k in
                      ("input", "cacheWrite5m", "cacheWrite1h", "cacheRead", "output")},
            "costUSD": {k: round(v, 6) for k, v in c.items()},
        })

    write_cost_json(cost_file, {
        "source": "transcript",
        "startedAt": started,
        "finishedAt": finished,
        "transcript": str(t),
        "fromLine": skip,
        "byModel": by_model,
        "totals": {"totalTokens": grand_tokens, "totalCostUSD": round(grand_cost, 4)},
        "unpricedModels": unpriced,
        "pricingVersion": pricing_version,
        "note": ("Measured from the session transcript. Assistant messages are deduplicated by "
                 "message id. Dollar figures use the list rates in assets/pricing.json and exclude "
                 "any enterprise discount, Batch API discount or partner-platform pricing."),
    })
    print(f"cost.py: wrote {cost_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
