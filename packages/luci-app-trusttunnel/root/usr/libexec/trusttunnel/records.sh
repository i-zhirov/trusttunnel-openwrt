# Accessor helpers for the trusttunnel settings table.
#
# The settings file (path in $TT_RECORDS) is a tab-separated dump of the
# UCI configuration: one record per line, "section.option<TAB>value".
# A key may appear on several lines so that list options survive as
# multiple records. A value ends at the first tab — tabs never occur
# inside a value, while quotes and backslashes are ordinary characters
# and are passed through untouched. Keys are compared as whole fields:
# "edge.x" never matches a longer key such as "edge.x.y".
#
# This file is a library meant to be sourced, not executed. Callers
# usually do not know the table path yet at source time, so sourcing
# must succeed without TT_RECORDS; instead, each accessor refuses to run
# unless the variable names an existing file. The accessors never write
# to the settings file.

# tt_list <key> — every value for the key, one per line, in file order;
# prints nothing when the key is absent.
tt_list() {
    tt_key=$1
    awk -F '\t' -v key="$tt_key" \
        '$1 == key { print $2 }' \
        "${TT_RECORDS:?TT_RECORDS is not set}"
}

# tt_get <key> [default] — the first value for the key; an absent key or
# an empty first value yields the default, and without a default the
# output is an empty line.
tt_get() {
    tt_key=$1
    tt_default=${2-}
    awk -F '\t' -v key="$tt_key" -v fallback="$tt_default" \
        '$1 == key { if ($2 != "") { print $2; found = 1 } exit }
         END { if (!found) print fallback }' \
        "${TT_RECORDS:?TT_RECORDS is not set}"
}

# tt_bool <key> [default] — prints "true" exactly when the effective
# value is the single character 1, otherwise "false". The effective
# value is the stored first value, or the default when the key is
# absent or that value is empty; the default itself defaults to 0, so a
# stored 0 still beats a true default.
tt_bool() {
    tt_key=$1
    tt_default=${2-0}
    awk -F '\t' -v key="$tt_key" -v fallback="$tt_default" \
        '$1 == key { if ($2 != "") { if ($2 == "1") print "true"; else print "false"; found = 1 } exit }
         END { if (!found) { if (fallback == "1") print "true"; else print "false" } }' \
        "${TT_RECORDS:?TT_RECORDS is not set}"
}

# tt_count <key> — how many records carry the key, as a decimal number;
# 0 when the key is absent.
tt_count() {
    tt_key=$1
    awk -F '\t' -v key="$tt_key" \
        '$1 == key { seen = seen + 1 }
         END { print seen + 0 }' \
        "${TT_RECORDS:?TT_RECORDS is not set}"
}
