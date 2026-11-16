#!/usr/bin/env bash
# Runs tools/test_integration.lua in an isolated temp copy: the installed mod is
# never touched. The marker file makes the test refuse to run anywhere else.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="${TMPDIR:-/tmp}/ad-int-$$"
rm -rf "$tmp"; mkdir -p "$tmp"
cp -r "$here/Scripts" "$tmp/"
[ -d "$here/data" ] && cp -r "$here/data" "$tmp/"
cp "$here/pbz-auto-defense.config.json" "$here/pbz-auto-defense.modsmenu.json" "$here/auto_defense.txt" "$tmp/"
: > "$tmp/.ad-menu-test-only"
cd "$tmp"
AD_MENU_TEST=1 luajit "$(cygpath -w "$here/tools/test_integration.lua")"
echo "temp copy: $tmp"