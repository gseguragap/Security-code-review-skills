#!/usr/bin/env python3
"""Splice a measured cost.json into a findings.json as its "cost" block.

    merge-cost.py --findings <findings.json> --cost <cost.json>

Exists so cost collection can run AFTER the findings document is written. Authoring
findings.json is the single largest output of an audit phase; collecting cost before it was
written left that spend outside the measured window and understated every report.

The merge is a deterministic text splice over the placeholder line

    "cost": {},

so it costs no model tokens, and it preserves the surrounding formatting byte for byte.
The bash+awk and PowerShell twins do exactly the same thing; all three are held to that.
Standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r'^(\s*)"cost"\s*:\s*\{\s*\}\s*(,?)\s*$')
NL = chr(10)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--findings", required=True)
    ap.add_argument("--cost", required=True)
    args = ap.parse_args()

    fp, cp = Path(args.findings), Path(args.cost)
    if not fp.is_file():
        print(f"merge-cost: no findings document at {fp}", file=sys.stderr)
        return 66
    if not cp.is_file():
        print(f"merge-cost: no cost file at {cp}; leaving findings unchanged", file=sys.stderr)
        return 0

    cost = cp.read_text(encoding="utf-8").strip()
    lines = fp.read_text(encoding="utf-8").split(NL)

    out, hits = [], 0
    for line in lines:
        m = PLACEHOLDER.match(line)
        if m and not hits:
            indent, comma = m.group(1), m.group(2)
            # Re-indent the cost object so it sits exactly where the placeholder sat.
            nested = (NL + indent).join(cost.split(NL))
            out.append(indent + '"cost": ' + nested + comma)
            hits += 1
        else:
            out.append(line)

    if not hits:
        # A findings document with no placeholder is a contract violation, not something to
        # paper over: a report that silently carries no cost block is the failure this whole
        # change exists to prevent.
        print("merge-cost: findings document has no placeholder line for the cost block; "
              "leaving it unchanged", file=sys.stderr)
        return 65

    # newline="" keeps LF on every platform, so this stays byte-identical to the awk twin.
    with fp.open("w", encoding="utf-8", newline="") as fh:
        fh.write(NL.join(out))
    print(f"merge-cost: cost block spliced into {fp.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
