# Accessor helpers and shared constants for the trusttunnel settings table.
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
#
# The constants below are the single source for the fixed defaults and
# paths every component shares (the ucode backend mirrors them in
# /usr/share/ucode/trusttunnel.uc). They are DEFAULTS: a consumer keeps
# its own overridable variable (routing takes an out-dir argument, the
# init script binds the paths for the test harnesses), so nothing here
# is ever hardwired into a script's own assignment. The kernel constants
# are a hard contract with the routing helper and the diagnostics —
# changing a default is a schema change, not a tweak.
TT_OUT_DIR_DEFAULT=/var/etc/trusttunnel
TT_RECORDS_DEFAULT=$TT_OUT_DIR_DEFAULT/settings.tsv
TT_LIBDIR_DEFAULT=/usr/libexec/trusttunnel
TT_CLIENT_DEFAULT=/opt/trusttunnel_client/trusttunnel_client
TT_TABLE_DEFAULT=880
TT_FWMARK_DEFAULT=0x9527
TT_RULE_PRIORITY=30820
TT_BLACKHOLE_METRIC=1000
TT_ZONE_NAME=trusttunnel

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

# tt_mode_is_proxy — true when main.mode is "proxy". The operation mode
# is the one cross-cutting decision every component makes (listener
# block, kernel routing vs. the usage meter, the hotplug hook, the
# backend), so the comparison lives here instead of being re-parsed in
# each file. Absent main.mode means tun — the default and the only mode
# of earlier versions.
tt_mode_is_proxy() {
    [ "$(tt_get main.mode)" = "proxy" ]
}

# tt_assigned_profile_mode — the mode of the routing profile assigned to
# the ACTIVE server: "vpn", "bypass" or empty (no assignment, a stale
# name or an unknown mode). The name check mirrors uci-export's
# resolution: routing_profile.* records are authoritative only when the
# profile's name matches endpoint.routing_profile. gen-config consults
# this; the routing helper's kernel selection reads routing_profile.mode
# directly — the records it gets carry only the assigned profile (see
# routing's comment there).
tt_assigned_profile_mode() {
    tt_ref=$(tt_get endpoint.routing_profile)
    tt_pname=$(tt_get routing_profile.name)
    if [ -n "$tt_ref" ] && [ "$tt_ref" = "$tt_pname" ]; then
        tt_get routing_profile.mode
    fi
}
