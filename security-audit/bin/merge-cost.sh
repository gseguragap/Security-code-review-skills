#!/usr/bin/env bash
# merge-cost.sh - splice a measured cost.json into a findings.json as its "cost" block.
#
#   merge-cost.sh --findings <findings.json> --cost <cost.json>
#
# Twin of merge-cost.py for machines without a Python. Same placeholder contract, same
# output: the line
#
#     "cost": {},
#
# is replaced by the cost object, re-indented to sit where the placeholder sat. Deterministic
# text work - no model tokens are spent after the cost meter stops.
#
# Dependencies: bash + awk only.

set -uo pipefail

FINDINGS=""; COST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --findings) FINDINGS="${2:-}"; shift 2 ;;
    --cost)     COST="${2:-}"; shift 2 ;;
    *) echo "merge-cost.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

[ -n "$FINDINGS" ] && [ -n "$COST" ] || { echo "merge-cost.sh: need --findings and --cost" >&2; exit 64; }
[ -f "$FINDINGS" ] || { echo "merge-cost.sh: no findings document at $FINDINGS" >&2; exit 66; }
[ -f "$COST" ]     || { echo "merge-cost.sh: no cost file at $COST; leaving findings unchanged" >&2; exit 0; }

TMP="$FINDINGS.merge.$$"
# awk -v expands escape sequences in the value, which corrupts a Windows path such as
# C:\Users\.... ENVIRON passes it through untouched.
COST_FILE="$COST" awk '
BEGIN {
  n = 0
  costfile = ENVIRON["COST_FILE"]
  while ((getline l < costfile) > 0) cost[n++] = l
  close(costfile)
  while (n > 0 && cost[n-1] ~ /^[ \t]*$/) n--
  spliced = 0
}
{
  if (!spliced && $0 ~ /^[ \t]*"cost"[ \t]*:[ \t]*\{[ \t]*\}[ \t]*,?[ \t]*$/) {
    match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH)
    comma = ($0 ~ /,[ \t]*$/) ? "," : ""
    for (i = 0; i < n; i++) {
      if (i == 0)        printf "%s\"cost\": %s\n", indent, cost[i]
      else if (i == n-1) printf "%s%s%s\n", indent, cost[i], comma
      else               printf "%s%s\n", indent, cost[i]
    }
    spliced = 1
    next
  }
  print
}
END { if (!spliced) exit 65 }
' "$FINDINGS" > "$TMP"
STATUS=$?

if [ $STATUS -ne 0 ]; then
  rm -f "$TMP"
  echo "merge-cost.sh: findings document has no placeholder line for the cost block; leaving it unchanged" >&2
  exit 65
fi

mv -f "$TMP" "$FINDINGS"
echo "merge-cost.sh: cost block spliced into $(basename "$FINDINGS")"
