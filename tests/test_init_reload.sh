#!/bin/sh
# Applying settings: apply_settings and keeping routing across a restart.
#
# WHY. Save & Apply lands in reload_service. It used to unconditionally call
# restart, and any edit killed the client: the tunnel tore for a few seconds,
# and together with the nft table the marking disappeared for that time, so
# marked LAN traffic could slip out DIRECTLY — an ordinary settings save
# itself opened the leak this package protects against.
#
# Now reload_service asks classify_change what exactly is required, and across
# a restart the routing survives the stop+start cycle. Both decisions are
# checked here and, more importantly, their rollbacks: a failure on the cheap
# path must end in a full restart, and an interrupted start — in a real
# routing teardown, otherwise the table and the mark rule would remain
# hanging, pointing at something that no longer exists.
. "$(dirname "$0")/lib.sh"

INIT="packages/luci-app-trusttunnel/root/etc/init.d/trusttunnel"

sandbox="$TT_TEST_TMP/sandbox"
bin="$sandbox/bin"
mkdir -p "$bin" "$sandbox/lib" "$sandbox/out"

TT_CALLS="$sandbox/calls"
export TT_CALLS

# The stub scripts write their calls to a log: there is no procd, UCI or real
# routing on the developer machine, so it is the only evidence to judge by.
cat > "$sandbox/lib/routing" <<'EOF'
#!/bin/sh
echo "routing $1" >> "$TT_CALLS"
[ "$1" = "up" ] && exit "${ROUTING_UP_RC:-0}"
exit 0
EOF

cat > "$sandbox/lib/uci-export" <<'EOF'
#!/bin/sh
[ "${UCI_EXPORT_RC:-0}" = "0" ] || exit "$UCI_EXPORT_RC"
cat "$TT_NEXT"
EOF

# The certificate never lands in records (PEM is multi-line), so apply_settings
# compares it with a separate uci call.
cat > "$bin/uci" <<'EOF'
#!/bin/sh
cat "$TT_CERT_UCI" 2>/dev/null
exit 0
EOF

chmod +x "$sandbox/lib/routing" "$sandbox/lib/uci-export" "$bin/uci"
PATH="$bin:$PATH"
export PATH

# shellcheck disable=SC1090
. "$INIT"

# The paths are computed at the top level of the init script relative to /var,
# so both are overridden here: the directory and the records file inside it.
OUTDIR="$sandbox/out"
RECORDS="$OUTDIR/settings.tsv"
LIBDIR="$sandbox/lib"

TT_NEXT="$sandbox/next.tsv"
TT_CERT_UCI="$sandbox/cert_uci"
export TT_NEXT TT_CERT_UCI
: > "$TT_CERT_UCI"

# Everything outside the scope of the check is replaced with logging stubs.
# regenerate is stubbed out among others because the real one moves records
# itself — and the test needs to see whether it got that far.
restart() { echo "restart keep_routing=${_TT_KEEP_ROUTING:-0}" >> "$TT_CALLS"; }
regenerate() {
	echo "regenerate" >> "$TT_CALLS"
	[ "${REGEN_RC:-0}" = "0" ] || return "$REGEN_RC"
	cp "$TT_NEXT" "$RECORDS"
}
running() { return "${RUNNING_RC:-0}"; }
logger() { :; }

calls() { tr '\n' ' ' < "$TT_CALLS" | sed 's/ $//'; }
no_call() { grep -F "$1" "$TT_CALLS" 2>/dev/null || true; }

base_records() {
	cat <<'EOF'
main.enabled	1
endpoint.hostname	a.example
network.table	880
network.lan_devices	br-lan
EOF
}

# Prepares the applied state and the presumed new one, clears the log.
setup() {
	base_records > "$RECORDS"
	base_records > "$TT_NEXT"
	: > "$TT_CALLS"
	unset ROUTING_UP_RC REGEN_RC UCI_EXPORT_RC RUNNING_RC _TT_KEEP_ROUTING
	export ROUTING_UP_RC REGEN_RC UCI_EXPORT_RC
}

# --- Cheap path -------------------------------------------------------------

# An edit of the LAN interfaces never reaches client.toml, so there is no
# reason to touch the client: regenerate, reload into the kernel and re-attach
# the route to the LIVE device.
setup
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$TT_NEXT"
apply_settings

assert_eq "" "$(no_call 'restart')" \
	"an edit of the LAN interfaces does not restart the client"
assert_contains "$(calls)" "routing up" \
	"but the rules are reloaded into the kernel"
assert_contains "$(calls)" "routing reattach" \
	"and the route is re-attached to the live device"

# The record of the applied state must keep up: the next apply compares with
# it, and without an update the same edit would count as a change every time.
assert_contains "$(cat "$RECORDS")" "br-guest" \
	"the applied-state record is updated"

# --- Restart keeping routing --------------------------------------------------

setup
# `sed -i ''` is BSD-only: GNU sed treats the separate empty string as the
# script and the next token as a file, so the edit fails on CI. awk behaves
# identically on both, hence the temp file + mv.
awk '{ gsub(/a\.example/, "b.example"); print }' "$TT_NEXT" > "$TT_NEXT.tmp" && mv "$TT_NEXT.tmp" "$TT_NEXT"
apply_settings

assert_contains "$(calls)" "restart keep_routing=1" \
	"changing the server address restarts the client without tearing down routing"

setup
printf 'domains.direct\tbank.example\n' >> "$TT_NEXT"
apply_settings

assert_contains "$(calls)" "restart keep_routing=1" \
	"a new exclusion restarts the client without tearing down routing"

setup
printf 'routing_profile.mode\tbypass\n' >> "$TT_NEXT"
apply_settings

assert_contains "$(calls)" "restart keep_routing=1" \
	"a routing profile change restarts the client without tearing down routing"

# --- Restart with a full teardown ---------------------------------------------

# The table number and the mark are the only values that tear routing down.
# Keeping the old one and bringing up the new one would leave the old table
# and the old rule hanging forever.
setup
# Not every sed understands \t as an escape in an s/// script (BSD does not),
# while in an awk string it behaves the same everywhere, so the replacement
# goes through awk.
awk 'BEGIN { OFS = "\t" } $1 == "network.table" { $2 = "881" } { print }' \
	"$TT_NEXT" > "$TT_NEXT.tmp" && mv "$TT_NEXT.tmp" "$TT_NEXT"
apply_settings

assert_contains "$(calls)" "restart keep_routing=0" \
	"changing the table number tears routing down completely"

setup
awk 'BEGIN { OFS = "\t" } $1 == "main.enabled" { $2 = "0" } { print }' \
	"$TT_NEXT" > "$TT_NEXT.tmp" && mv "$TT_NEXT.tmp" "$TT_NEXT"
apply_settings

assert_contains "$(calls)" "restart keep_routing=0" \
	"disabling the service tears routing down completely"

# --- Certificate ---------------------------------------------------------------

# The only schema value absent from records: PEM is multi-line. Without a
# separate comparison a certificate change would never be applied — records
# does not change with it, and the cheap path would decide there is nothing
# to do.
setup
printf -- '-----BEGIN CERTIFICATE-----\nnew\n-----END CERTIFICATE-----\n' > "$TT_CERT_UCI"
apply_settings

assert_contains "$(calls)" "restart" \
	"a certificate change restarts the client even though records did not change"

# And vice versa: an unchanged certificate must not by itself cause a restart.
setup
printf -- '-----BEGIN CERTIFICATE-----\nsame\n-----END CERTIFICATE-----\n' > "$TT_CERT_UCI"
cp "$TT_CERT_UCI" "$OUTDIR/endpoint.pem"
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$TT_NEXT"
apply_settings

assert_eq "" "$(no_call 'restart')" \
	"an unchanged certificate does not block the cheap path"
rm -f "$OUTDIR/endpoint.pem"
: > "$TT_CERT_UCI"

# --- Rollbacks -----------------------------------------------------------------

# A failure on the cheap path must end in a full restart: at that moment the
# rules in the kernel are in an unknown state, and leaving things as they are
# would mean showing a working service on top of an under-loaded table.
setup
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$TT_NEXT"
ROUTING_UP_RC=1
apply_settings

assert_contains "$(calls)" "restart keep_routing=0" \
	"a routing up failure rolls back to a full restart"

setup
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$TT_NEXT"
REGEN_RC=1
apply_settings

assert_contains "$(calls)" "restart keep_routing=0" \
	"a regeneration failure rolls back to a full restart"

# There is nothing to compare with — this is a plain start, not an apply on
# top of a known state. /var on OpenWrt lives in tmpfs, so after a reboot
# there is no record.
setup
rm -f "$RECORDS"
apply_settings

assert_contains "$(calls)" "restart" \
	"with no applied-state record — the full path"

# The service is not running: there is nothing to apply on top of.
setup
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$TT_NEXT"
RUNNING_RC=1
apply_settings

assert_contains "$(calls)" "restart" \
	"a stopped service is applied via the full path"
unset RUNNING_RC

# UCI export failed — there is nothing to compare with, no basis for a decision.
setup
UCI_EXPORT_RC=1
apply_settings

assert_contains "$(calls)" "restart" \
	"a UCI export failure rolls back to a full restart"
assert_eq "0" "$(ls "$OUTDIR" | grep -c 'settings.tsv.next' || true)" \
	"and leaves no half-written file with a password behind"

# --- Routing survives a restart ------------------------------------------------

# The real stop_service is checked, not a stub: it is the one that decides
# whether to call routing down.
setup
_TT_KEEP_ROUTING=1
stop_service

assert_eq "" "$(no_call 'routing down')" \
	"on a restart with keep-routing the routing is not torn down"

setup
_TT_KEEP_ROUTING=0
stop_service

assert_contains "$(calls)" "routing down" \
	"a plain stop tears routing down as before"

# An interrupted start. The "no teardown needed" reasoning rests on start
# bringing everything up again; if it does not reach the end, the service is
# off while the table, the mark rule and the blackhole would remain hanging,
# pointing at a non-existent tunnel. Marked traffic would go into the
# blackhole with the bypass off, and in the UI it would look like "no
# internet".
setup
_TT_KEEP_ROUTING=1
abort_restart_cleanup

assert_contains "$(calls)" "routing down" \
	"an interrupted start tears down the kept routing"
assert_eq "0" "${_TT_KEEP_ROUTING}" \
	"the flag is reset so a repeated call does not tear down twice"

tt_test_summary
