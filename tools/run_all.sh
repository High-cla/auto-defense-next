#!/usr/bin/env bash
# One command, every offline check: the Lua suites, the Python tooling tests and
# the linter. Non-zero exit if anything fails. AD_REQUIRE_SELENE=1 turns a
# missing selene into a failure (CI sets it); locally it is reported as SKIPPED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in test_policy test_async test_timeline test_query test_menu_config test_menu_bridge; do
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
    for t in test_nexusmods_resolve_mod test_nexusmods_check_published; do
        if out=$(cd tools && "$py" "$t.py" 2>&1); then
            printf '%-24s %s\n' "$t" "$(printf '%s' "$out" | grep -E '^(OK|FAILED)' | tail -1)"
        else
            printf '%-24s FAIL\n' "$t"; printf '%s\n' "$out" | tail -20; fail=1
        fi
    done
else
    printf '%-24s SKIPPED (no working python interpreter)\n' python-tooling
fi
# selene exits non-zero when it only finds warnings: read its verdict, not its code
if command -v selene >/dev/null 2>&1; then
    selene Scripts/ >/tmp/ad-selene.txt 2>&1 || true
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
