#!/usr/bin/env bash
# collect-cost.sh - measure the token and dollar cost of a security-audit run.
#
#   collect-cost.sh --mark   --out <dir> [--transcript <file>]
#   collect-cost.sh --report --out <dir> [--transcript <file>] [--pricing <pricing.json>]
#
# --mark   records the transcript path and its current line count.
# --report replays only the lines added since the mark, sums per-model token usage,
#          prices it, and writes <dir>/cost.json.
#
# Dependencies: bash + awk only. No jq, no python, no node.
#
# Accuracy notes:
#   * Assistant messages appear multiple times in the transcript (streaming partials).
#     cost.awk deduplicates by message id - see that file.
#   * Cost is attributed by LINE OFFSET, so it captures this session's audit turns.
#     Work done by subagents is written to separate files under <session-id>/subagents/
#     and is added when those files are newer than the mark.
#   * If anything cannot be determined, the script says so in the JSON rather than
#     emitting a confident wrong number.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_SCRIPT="$HERE/cost.awk"
PRICING="$HERE/../assets/pricing.json"
MODE=""
OUTDIR=""
TRANSCRIPT="${CLAUDE_TRANSCRIPT:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --mark)       MODE="mark"; shift ;;
    --report)     MODE="report"; shift ;;
    --out)        OUTDIR="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --pricing)    PRICING="${2:-}"; shift 2 ;;
    *) echo "collect-cost.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

[ -n "$MODE" ]   || { echo "collect-cost.sh: need --mark or --report" >&2; exit 64; }
[ -n "$OUTDIR" ] || { echo "collect-cost.sh: need --out <dir>" >&2; exit 64; }
mkdir -p "$OUTDIR" 2>/dev/null

MARKFILE="$OUTDIR/cost-watermark"

# ---------------------------------------------------------------- transcript discovery
find_transcript() {
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && { printf '%s' "$TRANSCRIPT"; return 0; }
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [ -d "$base" ] || return 1
  # The live session's transcript is the most recently modified top-level .jsonl,
  # because it is being appended to right now.
  find "$base" -mindepth 2 -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------------------------------------------------------------- mark
if [ "$MODE" = "mark" ]; then
  T="$(find_transcript || true)"
  if [ -z "$T" ] || [ ! -f "$T" ]; then
    printf 'unavailable\t0\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKFILE"
    echo "collect-cost: no transcript found; cost will be reported as unavailable." >&2
    exit 0
  fi
  LINES=$(wc -l < "$T" | tr -d ' ')
  printf '%s\t%s\t%s\n' "$T" "$LINES" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKFILE"
  echo "collect-cost: watermark set at line $LINES of $T"
  exit 0
fi

# ---------------------------------------------------------------- report
# A measured figure is only ever produced from a watermark that still resolves. Every other
# path reports "unavailable": rescanning the whole transcript would bill the entire session
# to the audit and label it measured - silent, and confidently wrong.
now_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

unmeasured() {
  rm -f "${USAGE_TSV:-}" 2>/dev/null
  cat > "$OUTDIR/cost.json" <<JSONEOF
{
  "source": "unavailable",
  "reason": "$(json_escape "$1")",
  "startedAt": "$(json_escape "${STARTED:-unknown}")",
  "finishedAt": "$(now_stamp)",
  "byModel": [],
  "totals": { "totalTokens": 0, "totalCostUSD": null },
  "note": "Cost was not measured. Supply an estimate and set source to 'estimate', or state that cost is unavailable. Do not present an unmeasured figure as measured."
}
JSONEOF
  echo "collect-cost: $1 - wrote cost.json with source=unavailable" >&2
  exit 0
}

STARTED=""
command -v awk >/dev/null 2>&1 || unmeasured "awk is not available on this machine."
[ -f "$MARKFILE" ] || unmeasured "No cost-watermark in the output directory: the run never marked a start point, so there is no window to measure."

IFS=$'\t' read -r T SKIP STARTED < "$MARKFILE"
# A watermark written on Windows may carry CRLF; a trailing CR would land inside
# cost.json as a raw control character and make the file unparseable.
T="${T%$'\r'}"; SKIP="${SKIP%$'\r'}"; STARTED="${STARTED%$'\r'}"
[ "${T:-}" != "unavailable" ] || unmeasured "No session transcript was found when the watermark was set."
{ [ -n "${T:-}" ] && [ -n "${STARTED:-}" ]; } || unmeasured "The cost-watermark is malformed and cannot be read."

if [ ! -f "$T" ]; then
  # An explicit --transcript may relocate a file that has moved. The recorded offset still
  # applies, so this re-points at the same transcript - it never selects a different session.
  if [ -n "${TRANSCRIPT:-}" ] && [ -f "$TRANSCRIPT" ]; then
    T="$TRANSCRIPT"
  else
    unmeasured "The transcript recorded in the watermark is no longer readable ($T)."
  fi
fi

TOTAL_LINES=$(wc -l < "$T" | tr -d " ")
[ "${SKIP:-0}" -le "${TOTAL_LINES:-0}" ] || unmeasured "The watermark starts at line $SKIP but the transcript now holds only $TOTAL_LINES lines: it was rotated or truncated mid-run."

FINISHED="$(now_stamp)"

USAGE_TSV="$OUTDIR/.usage.tsv"
awk -v SKIP="${SKIP:-0}" -f "$AWK_SCRIPT" "$T" > "$USAGE_TSV"

# Include subagent transcripts written after the mark, if any.
SESSION_DIR="${T%.jsonl}"
if [ -d "$SESSION_DIR/subagents" ]; then
  for sf in "$SESSION_DIR"/subagents/*.jsonl; do
    [ -f "$sf" ] || continue
    if [ -z "${STARTED:-}" ] || [ "$sf" -nt "$MARKFILE" ]; then
      awk -v SKIP=0 -f "$AWK_SCRIPT" "$sf" >> "$USAGE_TSV"
    fi
  done
fi

[ -s "$USAGE_TSV" ] || unmeasured "No assistant turns were found after line $SKIP of the transcript. The watermark does not line up with this session, so no cost can be attributed to it."

# ---------------------------------------------------------------- price it
# pricing.json keeps one model per line, so a line-oriented lookup is sufficient
# and keeps this script dependency-free.
# Paths go through ENVIRON, not -v: awk expands escape sequences in a -v value and would
# corrupt a Windows path such as C:\Users\... on the way in.
# The transcript path is printed into cost.json, so it must be JSON-escaped first:
# a Windows path such as C:\Users\... is full of invalid JSON escapes otherwise.
COST_PRICING="$PRICING" COST_TRANSCRIPT="$(json_escape "$T")" \
awk -v started="${STARTED:-unknown}" -v finished="$FINISHED" -v skip="${SKIP:-0}" '
BEGIN {
  FS = "\t"
  pricing = ENVIRON["COST_PRICING"]
  transcript = ENVIRON["COST_TRANSCRIPT"]
  # ---- load pricing (one model per line) ----
  while ((getline line < pricing) > 0) {
    if (line !~ /"input"[ \t]*:/) continue
    if (!match(line, /"[a-zA-Z0-9._-]+"[ \t]*:[ \t]*\{/)) continue
    key = substr(line, RSTART + 1, RLENGTH - 1)
    sub(/"[ \t]*:[ \t]*\{$/, "", key)
    if (match(line, /"input"[ \t]*:[ \t]*[0-9.]+/))        { s = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", s); P_input[key]  = s + 0 }
    if (match(line, /"output"[ \t]*:[ \t]*[0-9.]+/))       { s = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", s); P_output[key] = s + 0 }
    if (match(line, /"cacheWrite5m"[ \t]*:[ \t]*[0-9.]+/)) { s = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", s); P_cw5[key]    = s + 0 }
    if (match(line, /"cacheWrite1h"[ \t]*:[ \t]*[0-9.]+/)) { s = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", s); P_cw1[key]    = s + 0 }
    if (match(line, /"cacheRead"[ \t]*:[ \t]*[0-9.]+/))    { s = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", s); P_cr[key]     = s + 0 }
  }
  close(pricing)
}
# ---- accumulate usage rows (subagent rows may repeat a model) ----
{
  m = $1
  msgs[m] += $2; inp[m] += $3; w5[m] += $4; w1[m] += $5; rd[m] += $6; out[m] += $7
  models[m] = 1
}
END {
  print "{"
  printf "  \"source\": \"transcript\",\n"
  printf "  \"startedAt\": \"%s\",\n", started
  printf "  \"finishedAt\": \"%s\",\n", finished
  printf "  \"transcript\": \"%s\",\n", transcript
  printf "  \"fromLine\": %d,\n", skip
  printf "  \"byModel\": [\n"

  first = 1; grandTokens = 0; grandCost = 0; unpriced = 0
  for (m in models) {
    known = (m in P_input)
    c_in = known ? inp[m] * P_input[m]  / 1000000 : 0
    c_w5 = known ? w5[m]  * P_cw5[m]    / 1000000 : 0
    c_w1 = known ? w1[m]  * P_cw1[m]    / 1000000 : 0
    c_rd = known ? rd[m]  * P_cr[m]     / 1000000 : 0
    c_ou = known ? out[m] * P_output[m] / 1000000 : 0
    total = c_in + c_w5 + c_w1 + c_rd + c_ou
    tok = inp[m] + w5[m] + w1[m] + rd[m] + out[m]
    grandTokens += tok
    if (known) grandCost += total; else unpriced++

    if (!first) printf ",\n"
    first = 0
    printf "    {\n"
    printf "      \"model\": \"%s\",\n", m
    printf "      \"priced\": %s,\n", (known ? "true" : "false")
    printf "      \"messages\": %d,\n", msgs[m]
    printf "      \"tokens\": { \"input\": %d, \"cacheWrite5m\": %d, \"cacheWrite1h\": %d, \"cacheRead\": %d, \"output\": %d, \"total\": %d },\n", inp[m], w5[m], w1[m], rd[m], out[m], tok
    if (known) {
      printf "      \"rates\": { \"input\": %.2f, \"cacheWrite5m\": %.2f, \"cacheWrite1h\": %.2f, \"cacheRead\": %.2f, \"output\": %.2f },\n", P_input[m], P_cw5[m], P_cw1[m], P_cr[m], P_output[m]
      printf "      \"costUSD\": { \"input\": %.6f, \"cacheWrite5m\": %.6f, \"cacheWrite1h\": %.6f, \"cacheRead\": %.6f, \"output\": %.6f, \"total\": %.6f }\n", c_in, c_w5, c_w1, c_rd, c_ou, total
    } else {
      printf "      \"rates\": null,\n"
      printf "      \"costUSD\": null\n"
    }
    printf "    }"
  }
  printf "\n  ],\n"
  printf "  \"totals\": { \"totalTokens\": %d, \"totalCostUSD\": %.4f },\n", grandTokens, grandCost
  printf "  \"unpricedModels\": %d,\n", unpriced
  printf "  \"note\": \"Measured from the session transcript. Assistant messages are deduplicated by message id. Dollar figures use the list rates in assets/pricing.json and exclude any enterprise discount, Batch API discount or partner-platform pricing.\"\n"
  print "}"
}
' "$USAGE_TSV" > "$OUTDIR/cost.json"

rm -f "$USAGE_TSV"
echo "collect-cost: wrote $OUTDIR/cost.json"
