#!/bin/sh
# Self-test of the assertion helpers: proves they accept both a passing
# and a failing check, and that a failure inside a subshell is recorded
# in the counter files. Exits non-zero whenever the harness misbehaves.

. "$(dirname "$0")/lib.sh"

# The positive path: each helper accepts its expected outcome.
assert_eq "abc" "abc" "equal strings compare equal"
assert_contains "hello world" "lo wo" "a substring is found inside the haystack"
assert_exit 0 "a successful command is accepted" true
assert_exit 1 "a failing command is accepted" false

# The negative path: an intentionally failing assertion runs inside a
# subshell with its output hidden. The failed counter must show exactly
# one recorded failure, proving the helpers are not silently swallowing
# failures; the counter is then reset so the summary stays clean.
( assert_eq "a" "b" "intentional failure" ) >/dev/null 2>&1
if [ "$(cat "$TT_TEST_TMP/failed")" -eq 1 ]; then
    echo "  ok: a failing check is recorded in the counters"
    printf '0\n' > "$TT_TEST_TMP/failed"
else
    echo "  FAIL: assert_eq did not record a failure"
    exit 1
fi

tt_test_summary
