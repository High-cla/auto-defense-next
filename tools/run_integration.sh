#!/usr/bin/env bash
# Runs tools/test_integration.lua in an isolated temp copy: the installed mod is
# never touched. The marker file makes the test refuse to run anywhere else.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="${TMPDIR:-/tmp}/ad-int-$$"
rm -rf "$tmp"; mkdir -p "$tmp"
# Keep the copy when the test fails - that is the evidence - and remove it on
# success, so repeated runs no longer leave /tmp/ad-int-* behind.
cleanup() {
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -rf "$tmp"
    else
        printf 'temp copy kept: %s\n' "$tmp" >&2
    fi
}
trap cleanup EXIT
cp -r "$here/Scripts" "$tmp/"
[ -d "$here/data" ] && cp -r "$here/data" "$tmp/"
cp "$here/pbz-auto-defense.config.json" "$here/pbz-auto-defense.modsmenu.json" "$here/auto_defense.txt" "$tmp/"
: > "$tmp/.ad-menu-test-only"
cd "$tmp"
test_script="$here/tools/test_integration.lua"
if command -v cygpath >/dev/null 2>&1; then
    test_script="$(cygpath -w "$test_script")"
fi
AD_MENU_TEST=1 luajit "$test_script"
echo "temp copy: $tmp (removed on success)"
