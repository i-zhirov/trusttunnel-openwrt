#!/bin/sh
# Records accessors, pinned from the TT-02 contract.
#
# The four accessors read the TSV file at $TT_RECORDS: a line is
# "section.option<TAB>value", a key may repeat for list values, and a
# value ends at the first tab — quotes and backslashes inside a value
# are literal characters, not syntax. The TT_RECORDS guard lives inside
# the accessors: callers source the library before they know the file
# path, so sourcing must succeed without the variable.
. "$(dirname "$0")/lib.sh"

. packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/records.sh

# --- scalar fixture -------------------------------------------------------------

TT_RECORDS=tests/fixtures/records/minimal.tsv

assert_eq "1" "$(tt_get main.enabled)" "tt_get prints the stored value"
assert_eq "" "$(tt_get main.nosuch)" "tt_get prints nothing for an absent key"
assert_eq "fallback" "$(tt_get main.nosuch fallback)" "tt_get falls back to the given default"
assert_eq "" "$(tt_get main.nosuch "")" "tt_get prints nothing for an empty default"
assert_eq "true" "$(tt_bool main.enabled)" "tt_bool maps a stored 1 to true"
assert_eq "false" "$(tt_bool main.nosuch)" "tt_bool prints false for an absent key"
assert_eq "true" "$(tt_bool main.nosuch 1)" "tt_bool honours a true default"
assert_eq "false" "$(tt_bool main.nosuch banana)" "tt_bool maps a non-1 default to false"
assert_eq "1.2.3.4:443" "$(tt_list endpoint.address)" "tt_list prints the single value"
assert_eq "1" "$(tt_count endpoint.address)" "tt_count counts one occurrence"
assert_eq "0" "$(tt_count main.nosuch)" "tt_count prints 0 for an absent key"

# --- list fixture: repeated keys, quotes, backslashes, stored zeroes ------------

TT_RECORDS=tests/fixtures/records/full.tsv

assert_eq "1.2.3.4:443
[2001:db8::1]:443" "$(tt_list endpoint.address)" "tt_list prints every value in file order"
assert_eq "1.2.3.4:443" "$(tt_get endpoint.address)" "tt_get prints only the first value"
assert_eq "" "$(tt_list main.nosuch)" "tt_list prints nothing for an absent key"
assert_eq "2" "$(tt_count endpoint.address)" "tt_count counts repeated keys"
assert_eq "1" "$(tt_count domains.direct)" "tt_count counts the single domains.direct entry"
assert_eq 'pa"ss\with' "$(tt_get endpoint.password)" "a value keeps quotes and backslashes and stops at the first tab"
assert_eq 'pa"ss\with' "$(tt_list endpoint.password)" "tt_list takes the same first-tab slice"
assert_eq "false" "$(tt_bool endpoint.post_quantum 1)" "a stored 0 beats a true default"
assert_eq "false" "$(tt_bool main.log_level)" "a stored non-1 value maps to false"

# --- empty stored value, pinned via a throwaway fixture --------------------------

edge="$TT_TEST_TMP/edge.tsv"
printf 'edge.empty\t\nedge.empty\tvalue\nedge.bool\t\n' > "$edge"
TT_RECORDS="$edge"

assert_eq "" "$(tt_get edge.empty)" "an empty first value is treated as absent"
assert_eq "fallback" "$(tt_get edge.empty fallback)" "an empty first value falls back to the default"
assert_eq "true" "$(tt_bool edge.bool 1)" "an empty stored value honours the default"
assert_eq "2" "$(tt_count edge.empty)" "empty values still count as occurrences"

# --- prefix collision: keys match the whole field, not a prefix ------------------
# edge.x.y sits BEFORE edge.x in the fixture; a prefix-matching
# implementation would answer edge.x with the longer key's data.

printf 'edge.x.y\t2\nedge.x\t1\n' >> "$edge"

assert_eq "1" "$(tt_get edge.x)" "tt_get matches the whole key, not a prefix"
assert_eq "1" "$(tt_list edge.x)" "tt_list emits only the exact key's values"
assert_eq "1" "$(tt_count edge.x)" "tt_count counts only the exact key"

# --- the TT_RECORDS guard ---------------------------------------------------------

assert_exit 0 "sourcing the library needs no TT_RECORDS" sh -c '. packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/records.sh'

_guard_err=$(unset TT_RECORDS; tt_get main.enabled 2>&1)
assert_contains "$_guard_err" "TT_RECORDS is not set" "an accessor without TT_RECORDS names the variable"
(unset TT_RECORDS; tt_get main.enabled >/dev/null 2>&1) && _guard_ok=0 || _guard_ok=1
assert_eq "1" "$_guard_ok" "an accessor without TT_RECORDS fails"

_guard_err=$(TT_RECORDS=; tt_get main.enabled 2>&1)
assert_contains "$_guard_err" "TT_RECORDS is not set" "an accessor with an empty TT_RECORDS names the variable"

tt_test_summary
