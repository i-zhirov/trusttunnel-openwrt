#!/bin/sh
# Choosing the minimal action when applying settings.
#
# WHY. Save & Apply lands in reload_service, which used to always call
# restart: any edit — even a single line in domains.direct — killed the client
# and tore the tunnel for a few seconds. Between stop and start the nft table
# also disappeared, so marked LAN traffic could slip out DIRECTLY. Neither
# consequence is needed: the client reads client.toml only at startup, so an
# edit that never reaches client.toml needs no client restart at all.
#
# The classifier decides what is required, and its whole value lies in
# conservatism. An error toward the "expensive" path costs one extra restart,
# an error toward the "cheap" path means a silently unapplied setting, and
# such a failure is impossible to diagnose: the UI shows the new value while
# the old one still works. So an unknown key must yield the fullest action,
# not the cheapest, and there is a dedicated check for that here.
. "$(dirname "$0")/lib.sh"

INIT="packages/luci-app-trusttunnel/root/etc/init.d/trusttunnel"
SCHEMA_KEYS="tests/fixtures/schema-keys.txt"

sandbox="$TT_TEST_TMP/sandbox"
mkdir -p "$sandbox"

# At the top level the init script only assigns variables and defines
# functions, so it can be sourced without /etc/rc.common, procd and UCI.
# shellcheck disable=SC1090
. "$INIT"

# --- diff_keys ----------------------------------------------------------------

prev="$sandbox/prev.tsv"
next="$sandbox/next.tsv"

cat > "$prev" <<'EOF'
main.enabled	1
endpoint.hostname	a.example
domains.direct	bank.example
EOF

# Absence of changes is checked through class_of_diff below: the empty
# output of diff_keys is indistinguishable from a never-called function,
# and such an assert stays green even when there is no implementation at all.
#
# An added item of the exclusions list. A key repeats in records, so the
# comparison must count occurrences rather than look the key up: with a plain
# comparison of string sets, adding a second value to an existing key would
# be lost.
cp "$prev" "$next"
printf 'domains.direct\tbank2.example\n' >> "$next"
assert_eq "domains.direct" "$(diff_keys "$prev" "$next")" \
	"an added list item is visible"

# A removed item. The diff direction is symmetric: a disappearance must be
# noticed just like an appearance, otherwise an unticked checkbox would not
# be applied.
cp "$prev" "$next"
grep -v 'bank.example' "$prev" > "$next"
assert_eq "domains.direct" "$(diff_keys "$prev" "$next")" \
	"a removed list item is visible"

cp "$prev" "$next"
# `sed -i ''` is BSD-only: GNU sed treats the separate empty string as the
# script and the next token as a file, so the edit fails on CI. awk behaves
# identically on both, hence the temp file + mv.
awk '{ gsub(/a\.example/, "b.example"); print }' "$next" > "$next.tmp" && mv "$next.tmp" "$next"
assert_eq "endpoint.hostname" "$(diff_keys "$prev" "$next")" \
	"a changed scalar value is visible"

cp "$prev" "$next"
awk '{ gsub(/a\.example/, "b.example"); print }' "$next" > "$next.tmp" && mv "$next.tmp" "$next"
printf 'network.mtu\t1400\n' >> "$next"
assert_eq "endpoint.hostname network.mtu" \
	"$(diff_keys "$prev" "$next" | tr '\n' ' ' | sed 's/ $//')" \
	"several changes are listed without repeats"

# --- class_for_key -------------------------------------------------------------

assert_eq "reload" "$(class_for_key network.lan_devices)" \
	"the LAN interface list rebuilds only nft"
assert_eq "reload" "$(class_for_key network.blackhole_on_down)" \
	"killswitch rebuilds only nft"
assert_eq "reload" "$(class_for_key network.include_router_traffic)" \
	"router traffic rebuilds only nft"

assert_eq "restart" "$(class_for_key domains.direct)" \
	"exclusions go into client.toml — a client restart is needed"
assert_eq "restart" "$(class_for_key routing_profile.name)" \
	"the assigned profile name goes into client.toml"
assert_eq "restart" "$(class_for_key routing_profile.mode)" \
	"the profile mode goes into client.toml"
assert_eq "restart" "$(class_for_key routing_profile.vpn_rules)" \
	"the vpn rules go into client.toml"
assert_eq "restart" "$(class_for_key routing_profile.bypass_rules)" \
	"the bypass rules go into client.toml"
assert_eq "restart" "$(class_for_key endpoint.routing_profile)" \
	"switching the assigned profile restarts the client"
assert_eq "restart" "$(class_for_key endpoint.hostname)" \
	"the server address requires a client restart"
assert_eq "restart" "$(class_for_key endpoint.password)" \
	"the password requires a client restart"
assert_eq "restart" "$(class_for_key endpoint.certificate)" \
	"the certificate requires a client restart"
assert_eq "restart" "$(class_for_key network.mtu)" \
	"MTU goes into client.toml"
assert_eq "restart" "$(class_for_key main.log_level)" \
	"the log level goes into client.toml"

# A full restart with a real routing down is needed where otherwise the old
# routing table or the old mark rule would remain hanging.
assert_eq "restart_full" "$(class_for_key network.table)" \
	"changing the table number must tear down the old one"
assert_eq "restart_full" "$(class_for_key network.fwmark)" \
	"changing the mark must tear down the old rule"
assert_eq "restart_full" "$(class_for_key main.enabled)" \
	"disabling the service must tear down routing"
assert_eq "restart_full" "$(class_for_key main.mode)" \
	"switching the operation mode must rebuild the routing state"
assert_eq "restart" "$(class_for_key proxy.address)" \
	"the proxy address goes into client.toml"
assert_eq "restart" "$(class_for_key proxy.username)" \
	"the proxy user name goes into client.toml"
assert_eq "restart" "$(class_for_key proxy.password)" \
	"the proxy password goes into client.toml"

# The main conservatism check: an unknown key yields the same behavior as
# before the classifier existed.
assert_eq "restart_full" "$(class_for_key network.something_new)" \
	"an unknown key gets a full apply, not a cheap one"
assert_eq "restart_full" "$(class_for_key totally.unknown)" \
	"an unknown section does too"

# --- class_of_diff: the total over all changes ---------------------------------

cp "$prev" "$next"
assert_eq "noop" "$(class_of_diff "$prev" "$next")" \
	"no changes — do nothing"

cp "$prev" "$next"
printf 'domains.direct\tbank2.example\n' >> "$next"
assert_eq "restart" "$(class_of_diff "$prev" "$next")" \
	"only exclusions — client restart without tearing down routing"

# The result is the maximum over all changed keys, not the first or the last:
# a cheap edit next to an expensive one must not devalue it.
cp "$prev" "$next"
printf 'domains.direct\tbank2.example\n' >> "$next"
awk '{ gsub(/a\.example/, "b.example"); print }' "$next" > "$next.tmp" && mv "$next.tmp" "$next"
assert_eq "restart" "$(class_of_diff "$prev" "$next")" \
	"exclusions together with the server address — restart"

cp "$prev" "$next"
printf 'domains.direct\tbank2.example\n' >> "$next"
printf 'network.table\t881\n' >> "$next"
assert_eq "restart_full" "$(class_of_diff "$prev" "$next")" \
	"a table change overrides everything else"

# --- Classifier completeness ---------------------------------------------------

# Every schema key must be listed in class_for_key EXPLICITLY. Without this
# check a new key in uci-export would silently fall into the "unknown" branch
# and get a full restart: the setting would be applied, but the promised
# seamlessness would quietly vanish for everyone who edits that setting.
#
# The key list is pinned by tests/fixtures/schema-keys.txt, which
# tests/tools/dump-schema-keys.sh regenerates from uci-export's schema
# declarations. Regenerate and commit the fixture together with a schema
# change, so this check never drifts apart from the schema.
keys=$(cat "$SCHEMA_KEYS")
count=$(printf '%s\n' "$keys" | grep -c .)

# A sanity check of the fixture itself: if it breaks and returns nothing or a
# handful of keys, the completeness check would turn green without checking
# anything. The schema at the time of writing has 30 keys; the threshold is
# deliberately lower so it does not fail on a legitimate addition or removal
# of one, but higher than what a fixture that lost whole sections yields.
if [ "$count" -lt 15 ]; then
	_tt_fail "schema fixture lists only $count keys — it is broken"
else
	_tt_pass "schema fixture lists $count keys"
fi

missing=""
for k in $keys; do
	# certificate is intentionally absent from records (PEM is multi-line), but
	# it still needs classifying — apply_config compares it via a separate
	# file. The restart_full keys are exempt: they are the expensive actions
	# that are chosen deliberately, not by falling into the unknown branch.
	if [ "$(class_for_key "$k")" = "restart_full" ] \
			&& [ "$k" != "network.table" ] \
			&& [ "$k" != "network.fwmark" ] \
			&& [ "$k" != "main.enabled" ] \
			&& [ "$k" != "main.mode" ]; then
		missing="$missing $k"
	fi
done
assert_eq "" "$missing" \
	"every schema key is classified explicitly, none fell into the unknown branch"

tt_test_summary
