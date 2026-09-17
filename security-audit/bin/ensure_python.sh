#!/usr/bin/env bash
# ensure_python.sh - resolve a usable Python interpreter, without ever demanding an install.
#
#   ensure_python.sh [--allow-download] [--quiet] [--min 3.9]
#
# Prints the absolute path of a working Python (>= minimum) on stdout and exits 0.
# Exits 1 if none could be resolved - callers MUST fall back, never fail the audit.
#
# Resolution order (first hit wins):
#   1. $SECURITY_AUDIT_PYTHON            explicit override
#   2. PATH candidates, PROBED           see below
#   3. Well-known install locations      catches installs that are not on PATH
#   4. Previously bootstrapped cache
#   5. Bootstrap download                ONLY with --allow-download
#
# Why probing rather than `command -v`:
#   On Windows, %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe is a 0-byte App Execution
#   Alias that shadows real installs. It resolves on PATH, prints a Store advert, and exits
#   non-zero. Anything that trusts PATH picks it and breaks. We run actual code and check
#   the exit status, which the stub cannot fake. Step 3 exists for exactly the same reason:
#   the real interpreter is frequently installed but not on PATH.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/../assets/python-bootstrap.json"
ALLOW_DL=0
QUIET=0
MIN_MAJ=3
MIN_MIN=9

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-download) ALLOW_DL=1; shift ;;
    --quiet)          QUIET=1; shift ;;
    --min)            MIN_MAJ="${2%%.*}"; MIN_MIN="${2##*.}"; shift 2 ;;
    *) shift ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

# Real execution test. A stub, a broken symlink or an ancient interpreter all fail here.
probe() {
  [ -n "${1:-}" ] || return 1
  "$1" -c "import sys; sys.exit(0 if sys.version_info >= ($MIN_MAJ, $MIN_MIN) else 1)" >/dev/null 2>&1
}

emit() { printf '%s\n' "$1"; exit 0; }

# ---------------------------------------------------------------- 1. override
if [ -n "${SECURITY_AUDIT_PYTHON:-}" ]; then
  if probe "$SECURITY_AUDIT_PYTHON"; then emit "$SECURITY_AUDIT_PYTHON"; fi
  say "ensure_python: SECURITY_AUDIT_PYTHON is set but not usable: $SECURITY_AUDIT_PYTHON"
fi

# ---------------------------------------------------------------- 2. PATH
for c in python3 python py; do
  p="$(command -v "$c" 2>/dev/null)" || continue
  probe "$p" && emit "$p"
done

# ---------------------------------------------------------------- 3. well-known
# Ordered newest-first where globs allow. Covers the common "installed but not on PATH" case.
CANDIDATES=""
add() { [ -e "$1" ] && CANDIDATES="$CANDIDATES
$1"; }

for g in \
  "$HOME"/AppData/Local/Programs/Python/Python3*/python.exe \
  "/c/Program Files/Python3"*/python.exe \
  "/c/Python3"*/python.exe \
  /usr/local/bin/python3 /usr/bin/python3 /bin/python3 \
  /opt/homebrew/bin/python3 /usr/local/opt/python*/bin/python3 \
  "$HOME"/.pyenv/versions/*/bin/python3 \
  "$HOME"/.local/bin/python3 \
  /Library/Frameworks/Python.framework/Versions/3.*/bin/python3 ; do
  add "$g"
done

# Newest-looking first.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  probe "$p" && emit "$p"
done <<EOF
$(printf '%s\n' "$CANDIDATES" | grep -v '^$' | sort -Vr 2>/dev/null || printf '%s\n' "$CANDIDATES" | grep -v '^$')
EOF

# ---------------------------------------------------------------- 4. cache
CACHE_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/security-audit/python"
if [ -f "$MANIFEST" ]; then
  VER="$(grep -m1 '"version"' "$MANIFEST" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
else
  VER=""
fi
if [ -n "$VER" ]; then
  for e in "$CACHE_ROOT/$VER/python/bin/python3" "$CACHE_ROOT/$VER/python/python.exe"; do
    probe "$e" && emit "$e"
  done
fi

# ---------------------------------------------------------------- 5. bootstrap
if [ "$ALLOW_DL" -ne 1 ]; then
  say "ensure_python: no usable Python found. Not downloading (pass --allow-download to permit)."
  exit 1
fi
[ -f "$MANIFEST" ] || { say "ensure_python: manifest missing: $MANIFEST"; exit 1; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux*)                    OS=linux ;;
  Darwin*)                   OS=darwin ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) OS=windows ;;
  *)                         say "ensure_python: unrecognised OS"; exit 1 ;;
esac
case "$(uname -m 2>/dev/null || echo unknown)" in
  x86_64|amd64)  ARCH=x86_64 ;;
  arm64|aarch64) ARCH=$([ "$OS" = linux ] && echo aarch64 || echo arm64) ;;
  *)             say "ensure_python: unrecognised architecture"; exit 1 ;;
esac
KEY="$OS-$ARCH"

# Pull this platform's block out of the manifest without a JSON parser.
BLOCK="$(tr -d '\n' < "$MANIFEST" | sed -E "s/.*\"$KEY\"[[:space:]]*:[[:space:]]*\{([^}]*)\}.*/\1/")"
FILE="$(printf '%s' "$BLOCK" | sed -E 's/.*"file"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
SHA="$(printf  '%s' "$BLOCK" | sed -E 's/.*"sha256"[[:space:]]*:[[:space:]]*"([0-9a-f]{64})".*/\1/')"
BASE="$(tr -d '\n' < "$MANIFEST" | sed -E 's/.*"baseUrl"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

if [ -z "$FILE" ] || [ ${#SHA} -ne 64 ]; then
  say "ensure_python: no pinned build for $KEY"; exit 1
fi

command -v curl >/dev/null 2>&1 || { say "ensure_python: curl not available"; exit 1; }
command -v tar  >/dev/null 2>&1 || { say "ensure_python: tar not available";  exit 1; }

DEST="$CACHE_ROOT/$VER"
TMP="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sa-py-$$")"
mkdir -p "$TMP" "$DEST"

say "ensure_python: downloading CPython $VER for $KEY (~30 MB) into $DEST"
if ! curl -fsSL --max-time 300 "$BASE$FILE" -o "$TMP/$FILE"; then
  say "ensure_python: download failed"; rm -rf "$TMP"; exit 1
fi

# Verify BEFORE extracting. Never extract an archive whose hash we have not confirmed.
ACTUAL=""
if command -v sha256sum >/dev/null 2>&1; then ACTUAL="$(sha256sum "$TMP/$FILE" | awk '{print $1}')"
elif command -v shasum   >/dev/null 2>&1; then ACTUAL="$(shasum -a 256 "$TMP/$FILE" | awk '{print $1}')"
else say "ensure_python: no sha256 tool available - refusing to use an unverified archive"; rm -rf "$TMP"; exit 1
fi

if [ "$ACTUAL" != "$SHA" ]; then
  say "ensure_python: CHECKSUM MISMATCH - refusing to extract."
  say "  expected $SHA"
  say "  actual   $ACTUAL"
  rm -rf "$TMP"; exit 1
fi

tar -xzf "$TMP/$FILE" -C "$DEST" || { say "ensure_python: extract failed"; rm -rf "$TMP"; exit 1; }
rm -rf "$TMP"

for e in "$DEST/python/bin/python3" "$DEST/python/python.exe"; do
  probe "$e" && { say "ensure_python: bootstrapped $e"; emit "$e"; }
done

say "ensure_python: bootstrap completed but no working interpreter was produced"
exit 1
