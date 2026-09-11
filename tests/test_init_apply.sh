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
UCI_EXPORT="packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/uci-export"

sandbox="$TT_TEST_TMP/sandbox"
mkdir -p "$sandbox"

# At the top level the init script only assigns variables and defines
# functions, so it can be sourced without /etc/rc.common, procd and UCI.
# shellcheck disable=SC1090
. "$INIT"

# --- changed_keys -------------------------------------------------------------

old="$sandbox/old.tsv"
new="$sandbox/new.tsv"

cat > "$old" <<'EOF'
main.enabled	1
endpoint.hostname	a.example
domains.direct	bank.example
EOF

# Absence of changes is checked through classify_change below: the empty
# output of changed_keys is indistinguishable from a never-called function,
# and such an assert stays green even when there is no implementation at all.
#
# An added item of the exclusions list. A key repeats in records, so the
# comparison must count occurrences rather than look the key up: with a plain
# comparison of string sets, adding a second value to an existing key would
# be lost.
cp "$old" "$new"
printf 'domains.direct\tbank2.example\n' >> "$new"
assert_eq "domains.direct" "$(changed_keys "$old" "$new")" \
	"an added list item is visible"

# A removed item. The diff direction is symmetric: a disappearance must be
# noticed just like an appearance, otherwise an unticked checkbox would not
# be applied.
cp "$old" "$new"
grep -v 'bank.example' "$old" > "$new"
assert_eq "domains.direct" "$(changed_keys "$old" "$new")" \
	"a removed list item is visible"

cp "$old" "$new"
# `sed -i ''` is BSD-only: GNU sed treats the separate empty string as the
# script and the next token as a file, so the edit fails on CI. awk behaves
# identically on both, hence the temp file + mv.
awk '{ gsub(/a\.example/, "b.example"); print }' "$new" > "$new.tmp" && mv "$new.tmp" "$new"
assert_eq "endpoint.hostname" "$(changed_keys "$old" "$new")" \
	"a changed scalar value is visible"

cp "$old" "$new"
awk '{ gsub(/a\.example/, "b.example"); print }' "$new" > "$new.tmp" && mv "$new.tmp" "$new"
printf 'network.mtu\t1400\n' >> "$new"
assert_eq "endpoint.hostname network.mtu" \
	"$(changed_keys "$old" "$new" | tr '\n' ' ' | sed 's/ $//')" \
	"several changes are listed without repeats"

# --- change_class -------------------------------------------------------------

assert_eq "reload" "$(change_class network.lan_devices)" \
	"the LAN interface list rebuilds only nft"
assert_eq "reload" "$(change_class network.blackhole_on_down)" \
	"killswitch rebuilds only nft"
assert_eq "reload" "$(change_class network.include_router_traffic)" \
	"router traffic rebuilds only nft"

assert_eq "restart" "$(change_class domains.direct)" \
	"exclusions go into client.toml — a client restart is needed"
assert_eq "restart" "$(change_class routing_profile.name)" \
	"the assigned profile name goes into client.toml"
assert_eq "restart" "$(change_class routing_profile.mode)" \
	"the profile mode goes into client.toml"
assert_eq "restart" "$(change_class routing_profile.vpn_rules)" \
	"the vpn rules go into client.toml"
assert_eq "restart" "$(change_class routing_profile.bypass_rules)" \
	"the bypass rules go into client.toml"
assert_eq "restart" "$(change_class endpoint.routing_profile)" \
	"switching the assigned profile restarts the client"
assert_eq "restart" "$(change_class endpoint.hostname)" \
	"the server address requires a client restart"
assert_eq "restart" "$(change_class endpoint.password)" \
	"the password requires a client restart"
assert_eq "restart" "$(change_class endpoint.certificate)" \
	"the certificate requires a client restart"
assert_eq "restart" "$(change_class network.mtu)" \
	"MTU goes into client.toml"
assert_eq "restart" "$(change_class main.log_level)" \
	"the log level goes into client.toml"

# A full restart with a real routing down is needed where otherwise the old
# routing table or the old mark rule would remain hanging.
assert_eq "restart_full" "$(change_class network.table)" \
	"changing the table number must tear down the old one"
assert_eq "restart_full" "$(change_class network.fwmark)" \
	"changing the mark must tear down the old rule"
assert_eq "restart_full" "$(change_class main.enabled)" \
	"disabling the service must tear down routing"

# The main conservatism check: an unknown key yields the same behavior as
# before the classifier existed.
assert_eq "restart_full" "$(change_class network.something_new)" \
	"an unknown key gets a full apply, not a cheap one"
assert_eq "restart_full" "$(change_class totally.unknown)" \
	"an unknown section does too"

# --- classify_change: the total over all changes -------------------------------

cp "$old" "$new"
assert_eq "noop" "$(classify_change "$old" "$new")" \
	"no changes — do nothing"

cp "$old" "$new"
printf 'domains.direct\tbank2.example\n' >> "$new"
assert_eq "restart" "$(classify_change "$old" "$new")" \
	"only exclusions — client restart without tearing down routing"

# The result is the maximum over all changed keys, not the first or the last:
# a cheap edit next to an expensive one must not devalue it.
cp "$old" "$new"
printf 'domains.direct\tbank2.example\n' >> "$new"
awk '{ gsub(/a\.example/, "b.example"); print }' "$new" > "$new.tmp" && mv "$new.tmp" "$new"
assert_eq "restart" "$(classify_change "$old" "$new")" \
	"exclusions together with the server address — restart"

cp "$old" "$new"
printf 'domains.direct\tbank2.example\n' >> "$new"
printf 'network.table\t881\n' >> "$new"
assert_eq "restart_full" "$(classify_change "$old" "$new")" \
	"a table change overrides everything else"

# --- Classifier completeness ---------------------------------------------------

# Every schema key must be listed in change_class EXPLICITLY. Without this
# check a new key in uci-export would silently fall into the "unknown" branch
# and get a full restart: the setting would be applied, but the promised
# seamlessness would quietly vanish for everyone who edits that setting.
#
# The truth comes from uci-export itself, so the check never drifts apart from
# the schema. The parse works like this: `scalar <section> "$o"` inside
# `for o in ...` yields one key per loop word, `listopt <section> <option>` —
# a single key.
schema_keys() {
	awk '
		# The explicit marker in uci-export: the ASSIGNED routing profile is
		# exported under the canonical prefix routing_profile.<option>, and
		# the marker line lists the options so the completeness check stays
		# in sync with them. Must come BEFORE the for-loop branches — this
		# line does not match them, but the order keeps the intent clear.
		/^# schema-keys: / {
			line = $0
			sub(/^# schema-keys: /, "", line)
			n = split(line, a, /[ \t]+/)
			for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
			next
		}
		# One-line loop: `for o in a b c; do scalar <section> "$o"; done`.
		# This branch must stand BEFORE the general one: that one consumes
		# the line whole via `next`, and without this check all main.* keys
		# and both auto-update options would silently drop out of the parse —
		# the completeness check would stay green without checking them.
		/^for o in .*scalar/ {
			line = $0
			sub(/^for o in[ \t]+/, "", line)
			idx = index(line, ";")
			opts = substr(line, 1, idx - 1)
			rest = substr(line, idx)
			sec = ""
			n = split(rest, r, /[ \t]+/)
			for (i = 1; i <= n; i++) if (r[i] == "scalar") sec = r[i + 1]
			m = split(opts, a, /[ \t]+/)
			for (i = 1; i <= m; i++) if (a[i] != "") print sec "." a[i]
			next
		}
		# Multi-line: options accumulate up to the line with `scalar`.
		/^for o in/ {
			# Loop words are gathered up to `;` or `do`; the body may sit
			# on the same line or below after a `\` line continuation.
			opts = ""
			for (i = 4; i <= NF; i++) {
				if ($i == ";" || $i == "do" || $i == ";do") break
				if ($i == "\\") continue
				opts = opts " " $i
			}
			collecting = 1
			buf = opts
			next
		}
		collecting && /^\t\t/ {
			# Continuation of the option list on the next line.
			line = $0
			gsub(/\\/, "", line)
			buf = buf " " line
			next
		}
		collecting && /scalar/ {
			sec = ""
			for (i = 1; i <= NF; i++) if ($i == "scalar") sec = $(i + 1)
			n = split(buf, a, /[ \t]+/)
			for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != "do") print sec "." a[i]
			collecting = 0
			next
		}
		/^listopt / { print $2 "." $3 }
	' "$UCI_EXPORT" | sed 's/;$//' | sort -u
}

keys=$(schema_keys)
count=$(printf '%s\n' "$keys" | grep -c .)

# A sanity check of the parse itself: if it breaks and returns nothing or a
# handful of keys, the completeness check would turn green without checking
# anything. The schema at the time of writing has 25 keys; the threshold is
# deliberately lower so it does not fail on a legitimate addition or removal
# of one, but higher than what a parse with a lost one-line-loop branch
# yields.
if [ "$count" -lt 15 ]; then
	_tt_fail "schema parse of uci-export found only $count keys — it is broken"
else
	_tt_pass "schema parse of uci-export yielded $count keys"
fi

missing=""
for k in $keys; do
	# certificate is intentionally absent from records (PEM is multi-line), but
	# it still needs classifying — apply_settings compares it via a separate
	# file.
	if [ "$(change_class "$k")" = "restart_full" ] \
			&& [ "$k" != "network.table" ] \
			&& [ "$k" != "network.fwmark" ] \
			&& [ "$k" != "main.enabled" ]; then
		missing="$missing $k"
	fi
done
assert_eq "" "$missing" \
	"every schema key is classified explicitly, none fell into the unknown branch"

tt_test_summary
