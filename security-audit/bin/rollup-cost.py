#!/usr/bin/env python3
"""Roll several phase cost.json files into one multi-phase cost block.

    rollup-cost.py --out <combined.json> \
        --phase "Legacy audit=<dir>/cost.json" \
        --phase "Modernized audit=<dir>/cost.json" \
        --phase "Comparison=<dir>/cost.json"

Emits the `cost` object the comparison report expects: a `phases[]` row per audit phase with
that phase's `byModel[]` copied verbatim, plus the summed totals. Pair it with merge-cost to
splice the result into comparison.json.

This exists so the comparison's cost block is built mechanically rather than transcribed by
hand. Transcribing it costs output tokens *after* the meter has stopped, and any slip silently
changes a number the reader is being asked to trust.

Rules it enforces, because they are easy to get wrong by hand:
  * A phase whose file is missing or unmeasured keeps its row, with `"note": "not collected"`,
    so a gap is visible rather than absent.
  * If any phase is an estimate, the whole block is an estimate.
  * If any phase is missing, the block is flagged partial and the total says so.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

NL = chr(10)


def write_text_lf(path: Path, text: str) -> None:
    """LF on every platform, matching the other tools in bin/."""
    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def load_phase(name: str, path_str: str) -> dict:
    """One phases[] row. Never raises: an unreadable phase becomes a visible gap."""
    row = {"name": name, "byModel": [], "subtotalTokens": 0, "subtotalCostUSD": None}
    p = Path(path_str)
    if not p.is_file():
        row["note"] = "not collected"
        return row
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except ValueError as exc:
        row["note"] = f"not collected ({exc})"
        return row

    source = doc.get("source", "unknown")
    if source == "unavailable":
        row["note"] = doc.get("reason") or "not collected"
        return row

    totals = doc.get("totals") or {}
    row["byModel"] = doc.get("byModel") or []
    row["subtotalTokens"] = totals.get("totalTokens") or 0
    row["subtotalCostUSD"] = totals.get("totalCostUSD")
    row["source"] = source
    if doc.get("pricingVersion"):
        row["pricingVersion"] = doc["pricingVersion"]
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--phase", action="append", required=True,
                    help='"<Phase name>=<path to that phase cost.json>", repeatable')
    args = ap.parse_args()

    rows = []
    for spec in args.phase:
        if "=" not in spec:
            print(f"rollup-cost: --phase needs the form 'Name=path', got {spec!r}", file=sys.stderr)
            return 64
        name, _, path_str = spec.partition("=")
        rows.append(load_phase(name.strip(), path_str.strip()))

    measured = [r for r in rows if r.get("subtotalCostUSD") is not None]
    missing = [r for r in rows if r.get("subtotalCostUSD") is None]

    sources = {r.get("source") for r in measured}
    if not measured:
        source = "unavailable"
    elif "estimate" in sources:
        # A mixed measurement is not a measurement. Degrade the whole block.
        source = "estimate"
    else:
        source = "transcript"

    total_tokens = sum(r["subtotalTokens"] for r in measured)
    total_cost = round(sum(r["subtotalCostUSD"] for r in measured), 4) if measured else None

    versions = {r["pricingVersion"] for r in rows if r.get("pricingVersion")}

    note = ("Measured from the session transcript, segmented per phase by watermark. Assistant "
            "messages are deduplicated by message id. Dollar figures use list rates and exclude "
            "any enterprise or Batch API discount.")
    if missing:
        names = ", ".join(r["name"] for r in missing)
        note += (f" PARTIAL: {names} could not be measured, so the total below covers only the "
                 f"phases that were. Do not present it as the cost of the whole review.")

    block = {
        "source": source,
        "phases": rows,
        "totals": {"totalTokens": total_tokens, "totalCostUSD": total_cost},
        "partial": bool(missing),
        "note": note,
    }
    if len(versions) == 1:
        block["pricingVersion"] = versions.pop()

    write_text_lf(Path(args.out), json.dumps(block, indent=2) + NL)

    shown = f"${total_cost}" if total_cost is not None else "not measured"
    flag = " (PARTIAL)" if missing else ""
    print(f"rollup-cost: {len(rows)} phases -> {args.out} ({total_tokens} tokens, {shown}){flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
