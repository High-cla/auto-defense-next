#!/usr/bin/env bash
# One command, every offline suite, plus the linter. Non-zero exit if anything fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in test_policy test_async test_timeline test_menu_config test_menu_bridge; do
    if out=$(luajit "tools/$t.lua" 2>&1); then
        printf '%-20s %s\n' "$t" "$(printf '%s' "$out" | tail -1)"
    else
        printf '%-20s FAIL\n' "$t"; printf '%s\n' "$out" | tail -12; fail=1
    fi
done
if out=$(bash tools/run_integration.sh 2>&1); then
    printf '%-20s %s\n' test_integration "$(printf '%s' "$out" | grep 'INTEGRATION PASS' | tail -1)"
else
    printf '%-20s FAIL\n' test_integration; printf '%s\n' "$out" | tail -15; fail=1
fi
# selene exits non-zero when it only finds warnings: read its verdict, not its code
if command -v selene >/dev/null 2>&1; then
    selene Scripts/ >/tmp/ad-selene.txt 2>&1 || true
    if grep -q '^0 errors' /tmp/ad-selene.txt; then
        printf '%-20s %s warnings, 0 errors\n' selene "$(grep -c '^warning' /tmp/ad-selene.txt)"
    else
        printf '%-20s FAIL\n' selene; grep -E '^error' -A3 /tmp/ad-selene.txt | head -20; fail=1
    fi
fi
exit $fail