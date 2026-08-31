#!/bin/sh
# Test suite runner: executes every tests/test_*.sh in its own scratch
# directory with stdin closed, and fails the run when any test fails.
# A test that reports a skip (tt_skip, exit status 77) is counted as
# skipped and does not fail the run.

set -u

# Work from the repository root, wherever the runner is invoked.
cd "$(dirname "$0")/.." || exit 1

suite_failed=0
suite_skipped=0

for test_file in tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo "== $test_file"

    tmp_dir=$(mktemp -d) || exit 1
    export TT_TEST_TMP=$tmp_dir

    sh "$test_file" < /dev/null
    test_status=$?

    rm -rf "$tmp_dir"
    case "$test_status" in
        77) suite_skipped=$((suite_skipped + 1)) ;;
        0) ;;
        *) suite_failed=1 ;;
    esac
done

if [ "$suite_failed" -eq 0 ]; then
    if [ "$suite_skipped" -eq 0 ]; then
        echo "== all tests passed"
    else
        echo "== all tests passed ($suite_skipped skipped)"
    fi
    exit 0
fi
echo "== FAILURES"
exit 1
