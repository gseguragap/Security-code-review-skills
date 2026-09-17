#!/usr/bin/env bash
# Install the modernization security review skills.
#
# Copies three skill folders into a Claude Code skills directory. Nothing is built and nothing is
# fetched - the skills are Markdown and static assets. This script only copies files.
#
#   ./install.sh                        -> ~/.claude/skills          (every project on this machine)
#   ./install.sh --project /src/acme    -> /src/acme/.claude/skills  (one project only)
#   ./install.sh --force                -> overwrite without asking
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS=(security-audit security-audit-compare security-code-review)

SCOPE="user"
TARGET="$PWD"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) SCOPE="project"; TARGET="${2:-$PWD}"; shift 2 ;;
    --user)    SCOPE="user";    shift ;;
    --force|-f) FORCE=1;        shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Verify the source tree is complete before touching the destination. A half-installed skill fails
# in ways that are much harder to diagnose than a refusal to start.
for s in "${SKILLS[@]}"; do
  [ -d "$HERE/$s" ]            || { echo "Source folder not found: $HERE/$s" >&2; exit 1; }
  [ -f "$HERE/$s/SKILL.md" ]   || { echo "Not a skill folder (no SKILL.md): $HERE/$s" >&2; exit 1; }
done

if [ "$SCOPE" = "user" ]; then
  DEST="$HOME/.claude/skills"
else
  DEST="$(cd "$TARGET" && pwd)/.claude/skills"
fi

echo "Installing to $DEST"
mkdir -p "$DEST"

for s in "${SKILLS[@]}"; do
  if [ -e "$DEST/$s" ] && [ "$FORCE" -eq 0 ]; then
    printf "  %s already exists. Overwrite? [y/N] " "$s"
    read -r answer < /dev/tty || answer="n"
    case "$answer" in
      [Yy]*) ;;
      *) echo "  skipped $s"; continue ;;
    esac
  fi
  rm -rf "$DEST/$s"
  cp -R "$HERE/$s" "$DEST/$s"
  echo "  installed $s"
done

cat <<'EOF'

Done. Start a new Claude Code session, then run:
  /security-code-review

The three skills must stay siblings - security-audit-compare reads
security-audit's cost collectors by relative path.
EOF
