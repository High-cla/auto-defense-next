#!/usr/bin/env bash
# One command, every offline check: the Lua suites, the Python tooling tests, the
# std/reference alignment check, the Lua 5.4 compile smoke and the linter.
# Non-zero exit if anything fails. AD_REQUIRE_SELENE=1 and AD_REQUIRE_LUA54=1 turn a
# missing tool into a failure (CI sets both); locally they are reported as SKIPPED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in test_policy test_async test_timeline test_query test_menu_config test_menu_bridge test_compat test_toast test_api_contract test_inputstate; do
    if out=$(luajit "tools/$t.lua" 2>&1); then
        printf '%-24s %s\n' "$t" "$(printf '%s' "$out" | tail -1)"
    else
        printf '%-24s FAIL\n' "$t"; printf '%s\n' "$out" | tail -12; fail=1
    fi
done
if out=$(bash tools/run_integration.sh 2>&1); then
    printf '%-24s %s\n' test_integration "$(printf '%s' "$out" | grep 'INTEGRATION PASS' | tail -1)"
else
    printf '%-24s FAIL\n' test_integration; printf '%s\n' "$out" | tail -15; fail=1
fi
# On Windows a Store "python3" stub exists that exits without output, so the
# interpreter is chosen by running it once instead of trusting its name.
py=""
for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
        py="$cand"; break
    fi
done
if [ -n "$py" ]; then
    for t in test_nexusmods_resolve_mod test_nexusmods_check_published test_check_std test_check_docs; do
        if out=$(cd tools && "$py" "$t.py" 2>&1); then
            printf '%-24s %s\n' "$t" "$(printf '%s' "$out" | grep -E '^(OK|FAILED)' | tail -1)"
        else
            printf '%-24s FAIL\n' "$t"; printf '%s\n' "$out" | tail -20; fail=1
        fi
    done
    # A documented engine global that ue4ss.yml forgets only surfaces when someone
    # calls it, so the std is compared with the API reference here instead.
    if out=$("$py" tools/check_std.py 2>&1); then
        printf '%-24s %s\n' check_std "$(printf '%s' "$out" | tail -1)"
    else
        printf '%-24s FAIL\n' check_std; printf '%s\n' "$out" | tail -20; fail=1
    fi
    # The numbers MODULES.md and README state must be the numbers on disk.
    if out=$("$py" tools/check_docs.py 2>&1); then
        printf '%-24s %s\n' check_docs "$(printf '%s' "$out" | tail -1)"
    else
        printf '%-24s FAIL\n' check_docs; printf '%s\n' "$out" | tail -20; fail=1
    fi
else
    printf '%-24s SKIPPED (no working python interpreter)\n' python-tooling
fi
# LuaJIT runs the suites with Lua 5.1 semantics, the game runs 5.4: syntax that
# only 5.4 rejects would otherwise fail in game and nowhere else. Compile-only.
lua_compile=""
for cand in lua5.4 lua54; do
    if command -v "$cand" >/dev/null 2>&1; then lua_compile="$cand"; break; fi
done
if [ -n "$lua_compile" ]; then
    lua_files=$(ls Scripts/*.lua | wc -l | tr -d ' ')
    lua_bad=0
    for f in Scripts/*.lua; do
        if ! out=$("$lua_compile" -e "assert(loadfile('$f'))" 2>&1); then
            printf 'lua5.4-compile           FAIL %s\n' "$f"
            printf '%s\n' "$out" | tail -5
            lua_bad=1; fail=1
        fi
    done
    if [ "$lua_bad" -eq 0 ]; then
        printf '%-24s %s files compiled\n' lua5.4-compile "$lua_files"
    fi
elif [ "${AD_REQUIRE_LUA54:-0}" = "1" ]; then
    printf '%-24s FAIL (lua5.4 NOT INSTALLED and AD_REQUIRE_LUA54=1)\n' lua5.4-compile
    fail=1
else
    printf '%-24s lua5.4 NOT INSTALLED (compile smoke skipped)\n' lua5.4-compile
fi
# selene exits non-zero when it only finds warnings: read its verdict, not its code.
# Scripts/ is the mod and tools/ holds the test doubles that overwrite os.clock,
# dofile and friends, so both are linted in one scope.
if command -v selene >/dev/null 2>&1; then
    selene Scripts/ tools/ >/tmp/ad-selene.txt 2>&1 || true
    if grep -q '^0 errors' /tmp/ad-selene.txt && grep -q '^0 parse errors' /tmp/ad-selene.txt; then
        printf '%-24s %s warnings, 0 errors\n' selene "$(grep -c '^warning' /tmp/ad-selene.txt)"
    else
        printf '%-24s FAIL\n' selene
        grep -E '^(error|warning)' /tmp/ad-selene.txt | head -20
        tail -25 /tmp/ad-selene.txt
        fail=1
    fi
elif [ "${AD_REQUIRE_SELENE:-0}" = "1" ]; then
    printf '%-24s FAIL (selene not installed)\n' selene; fail=1
else
    printf '%-24s SKIPPED (not installed; AD_REQUIRE_SELENE=1 makes this fatal)\n' selene
fi
exit $fail
