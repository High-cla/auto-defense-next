#!/usr/bin/env bash
# Runs tools/test_integration.lua in an isolated temp copy: the installed mod is
# never touched. The marker file makes the test refuse to run anywhere else.
#
# The copy's config comes from the descriptor defaults, never from the player's
# own pbz-auto-defense.config.json: a menu change (read_frames off, for example)
# must not decide whether the gate passes. CI generates the same fixture on a
# clean checkout, so both routes run the test against the shipped defaults.
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
cp "$here/pbz-auto-defense.modsmenu.json" "$tmp/"
# Native programs need Windows paths once the shell has cd'ed elsewhere.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
py=""
for cand in python3 python py; do
    if "$cand" -c "import sys" >/dev/null 2>&1; then py="$cand"; break; fi
done
if [ -z "$py" ]; then
    printf 'no working python interpreter (python3/python/py) for the config fixture\n' >&2
    exit 1
fi
"$py" "$(win "$here")/tools/ci_prepare_test_fixtures.py" --root "$(win "$tmp")"
# The legacy TXT is part of the fixture: the test asserts it stays byte-identical.
cp "$here/auto_defense.txt" "$tmp/"
: > "$tmp/.ad-menu-test-only"
cd "$tmp"
test_script="$here/tools/test_integration.lua"
if command -v cygpath >/dev/null 2>&1; then
    test_script="$(cygpath -w "$test_script")"
fi
AD_MENU_TEST=1 luajit "$test_script"
echo "temp copy: $tmp (removed on success)"