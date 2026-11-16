#!/usr/bin/env bash
# Build the release archive: dist/pbz-auto-defense-v<version>.zip
# Version comes from tl.VERSION in Scripts/main.lua (single source of truth).
set -euo pipefail
cd "$(dirname "$0")/.."

# A bare `command -v python3` is not enough on Windows: the Microsoft Store
# stub sits first on PATH, exits without running our script, and would make
# packaging "succeed" with no archive. Probe for a real interpreter instead.
PY=""
for cand in python python3 py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import zipfile" >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "package: no working python found (tried python, python3, py)" >&2
  exit 1
fi
exec "$PY" tools/package.py "$@"
