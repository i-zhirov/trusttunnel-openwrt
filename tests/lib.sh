# Assertion helpers shared by every test in the suite.
#
# Counters live in plain files under $TT_TEST_TMP so that increments made
# inside a subshell or a command substitution stay visible to the parent
# shell. The runner exports TT_TEST_TMP; when a test runs standalone the
# library creates and exports its own directory instead.

if [ -z "${TT_TEST_TMP:-}" ]; then
    TT_TEST_TMP=$(mktemp -d)
    export TT_TEST_TMP
fi

tt_init_counters() {
    for tt_counter in total failed; do
        tt_counter_file=$TT_TEST_TMP/$tt_counter
        if [ ! -f "$tt_counter_file" ]; then
            printf '0\n' > "$tt_counter_file"
        fi
    done
}

tt_bump_counter() {
    tt_counter_name=$1
    tt_counter_file=$TT_TEST_TMP/$tt_counter_name
    tt_counter_value=$(cat "$tt_counter_file")
    printf '%s\n' "$((tt_counter_value + 1))" > "$tt_counter_file"
}

# assert_eq <expected> <actual> <message>
assert_eq() {
    tt_eq_expected=$1
    tt_eq_actual=$2
    tt_eq_message=$3
    tt_bump_counter total
    if [ "$tt_eq_expected" = "$tt_eq_actual" ]; then
        printf '  ok: %s\n' "$tt_eq_message"
    else
        printf '  FAIL: %s\n' "$tt_eq_message"
        printf '    expected: %s\n' "$tt_eq_expected"
        printf '    actual:   %s\n' "$tt_eq_actual"
        tt_bump_counter failed
    fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
    tt_cc_haystack=$1
    tt_cc_needle=$2
    tt_cc_message=$3
    tt_bump_counter total
    case $tt_cc_haystack in
        *"$tt_cc_needle"*)
            printf '  ok: %s\n' "$tt_cc_message"
            ;;
        *)
            printf '  FAIL: %s\n' "$tt_cc_message"
            printf '    missing:  %s\n' "$tt_cc_needle"
            printf '    haystack: %s\n' "$tt_cc_haystack"
            tt_bump_counter failed
            ;;
    esac
}

# assert_exit <expected-status> <message> <command...>
# The message precedes the command; this is the order every caller uses.
assert_exit() {
    tt_ex_expected=$1
    tt_ex_message=$2
    shift 2
    tt_bump_counter total
    "$@" >/dev/null 2>&1
    tt_ex_actual=$?
    if [ "$tt_ex_actual" -eq "$tt_ex_expected" ]; then
        printf '  ok: %s\n' "$tt_ex_message"
    else
        printf '  FAIL: %s\n' "$tt_ex_message"
        printf '    expected exit status: %s\n' "$tt_ex_expected"
        printf '    actual exit status:   %s\n' "$tt_ex_actual"
        tt_bump_counter failed
    fi
}

# _tt_pass <message> — record an explicitly passing check.
_tt_pass() {
    tt_bump_counter total
    printf '  ok: %s\n' "$1"
}

# _tt_fail <message> — record an explicitly failing check.
_tt_fail() {
    tt_bump_counter total
    printf '  FAIL: %s\n' "$1"
    tt_bump_counter failed
}

# tt_test_summary — prints the tally and exits 0 only when nothing failed.
tt_test_summary() {
	tt_sum_total=$(cat "$TT_TEST_TMP/total")
	tt_sum_failed=$(cat "$TT_TEST_TMP/failed")
	printf '  %s assertions, %s failed\n' "$tt_sum_total" "$tt_sum_failed"
	if [ "$tt_sum_failed" -eq 0 ]; then
		exit 0
	fi
	exit 1
}

# tt_skip <reason> — report an explicitly skipped test and exit with the
# runner's skip status (77): tests/run.sh counts it as skipped and does
# not fail the run.
tt_skip() {
	printf '  SKIP: %s\n' "$1"
	exit 77
}

tt_init_counters
