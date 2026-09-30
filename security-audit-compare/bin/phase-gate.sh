#!/usr/bin/env bash
# phase-gate.sh - refuse to start a comparison until both audits have finished, in order.
#
#   phase-gate.sh --legacy <legacy findings.json> --modernized <modernized findings.json>
#
# Enforces the golden rule of the modernization flow (security-code-review/SKILL.md):
#   inputs -> Legacy audit + Legacy report -> Modernized audit + Modernized report -> Comparison.
# The comparison reads what the two audits wrote, so it may start only once both are complete.
#
# A side is complete when, on disk:
#   * its findings.json exists and is a security-audit findings document,
#   * its cost block has been merged (the "cost": {} placeholder is gone - the last step of an
#     audit before rendering), and
#   * its HTML report exists and is not older than its findings.json.
# When both audits live in one project folder (the orchestrated layout), the Modernized phase
# must also have started after the Legacy report was written.
#
# Exit 0 = PASS. Exit 3 = BLOCKED, with the reason on stderr. Exit 64 = bad arguments.
# Dependencies: bash + coreutils only. The PowerShell twin, phase-gate.ps1, applies the same checks.

set -uo pipefail

LEGACY=""
MODERNIZED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --legacy)     LEGACY="${2:-}"; shift 2 ;;
    --modernized) MODERNIZED="${2:-}"; shift 2 ;;
    *) echo "phase-gate.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
{ [ -n "$LEGACY" ] && [ -n "$MODERNIZED" ]; } || {
  echo "phase-gate.sh: need --legacy <findings.json> and --modernized <findings.json>" >&2; exit 64; }

block() {
  echo "phase-gate: BLOCKED - $1" >&2
  echo "phase-gate: the comparison must not start until the Legacy and then the Modernized audit have each written their report." >&2
  exit 3
}

# The folder the audit rendered its report into: the parent of the .security-audit directory
# that holds the findings document, or the findings document's own folder if there is none.
report_dir_of() {
  local d
  d="$(cd "$(dirname "$1")" && pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ "$(basename "$d")" = ".security-audit" ]; then dirname "$d"; return; fi
    d="$(dirname "$d")"
  done
  cd "$(dirname "$1")" && pwd
}

# Newest report for one side. A variant-labelled audit (findings under .security-audit/legacy or
# .security-audit/modernized) must have the matching labelled report; a standalone audit may
# have any non-comparison report.
report_of() {
  local label="$1" findings="$2" rdir="$3" variant newest="" f name
  variant="$(basename "$(dirname "$findings")")"
  # Match on the basename with case patterns: report names contain spaces, and an unquoted glob
  # built from a variable would be word-split into "*", "-", ... and match every file.
  for f in "$rdir"/*.html; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in *" - Comparison - "*) continue ;; esac
    case "$variant" in
      legacy|modernized) case "$name" in *" - $label - Security analysis report"*) ;; *) continue ;; esac ;;
      *)                 case "$name" in *"Security analysis report"*) ;; *) continue ;; esac ;;
    esac
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done
  printf '%s' "$newest"
}

check_side() {
  local label="$1" f="$2" rdir report
  [ -f "$f" ] || block "$label findings document not found: $f. The $label audit has not run, or has not finished."
  [ -s "$f" ] || block "$label findings document is empty: $f."
  { grep -q '"meta"' "$f" && grep -q '"findings"' "$f"; } \
    || block "$f is not a security-audit findings document."
  if grep -Eq '^[[:space:]]*"cost"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}[[:space:]]*,?[[:space:]]*$' "$f"; then
    block "$label audit has not finished: its cost block is still the placeholder, so its final steps (cost merge, report) have not run."
  fi
  rdir="$(report_dir_of "$f")"
  report="$(report_of "$label" "$f" "$rdir")"
  [ -n "$report" ] || block "$label report not found in $rdir. A phase is complete only once its HTML report is written."
  [ "$f" -nt "$report" ] && block "$label report ($(basename "$report")) is older than its findings document - it was not rendered from the finished audit."
  printf '%s' "$report"
}

L_REPORT="$(check_side "Legacy" "$LEGACY")" || exit $?
M_REPORT="$(check_side "Modernized" "$MODERNIZED")" || exit $?

# Order: in the orchestrated layout, nothing the Modernized phase wrote may predate the Legacy report.
L_RDIR="$(report_dir_of "$LEGACY")"; M_RDIR="$(report_dir_of "$MODERNIZED")"
if [ "$L_RDIR" = "$M_RDIR" ]; then
  M_DIR="$(cd "$(dirname "$MODERNIZED")" && pwd)"
  EARLY="$(find "$M_DIR" -maxdepth 1 -type f ! -newer "$L_REPORT" -print 2>/dev/null | head -1)"
  [ -z "$EARLY" ] || block "the Modernized phase started before the Legacy report existed ($(basename "$EARLY") predates $(basename "$L_REPORT")). Re-run the Modernized audit after the Legacy report."
fi

echo "phase-gate: PASS - Legacy report: $(basename "$L_REPORT"); Modernized report: $(basename "$M_REPORT")"
exit 0
