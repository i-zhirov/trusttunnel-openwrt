#!/bin/sh
# Applying settings: apply_config and keeping routing across a restart.
#
# WHY. Save & Apply lands in reload_service. It used to unconditionally call
# restart, and any edit killed the client: the tunnel tore for a few seconds,
# and together with the nft table the marking disappeared for that time, so
# marked LAN traffic could slip out DIRECTLY — an ordinary settings save
# itself opened the leak this package protects against.
#
# Now reload_service asks class_of_diff what exactly is required, and across
# a restart the routing survives the stop+start cycle. Both decisions are
# checked here and, more importantly, their rollbacks: a failure on the cheap
# path must end in a full restart, and an interrupted start — in a real
# routing teardown, otherwise the table and the mark rule would remain
# hanging, pointing at something that no longer exists.
. "$(dirname "$0")/lib.sh"

INIT="packages/luci-app-trusttunnel/root/etc/init.d/trusttunnel"

lab="$TT_TEST_TMP/lab"
bin="$lab/bin"
mkdir -p "$bin" "$lab/lib" "$lab/out"

CALL_LOG="$lab/calls.log"
export CALL_LOG

# The stub scripts append their calls to a log: there is no procd, UCI or
# real routing on the developer machine, so it is the only evidence to
# judge by. The bodies are written with a quoted heredoc so the exported
# variables resolve at stub runtime, not at write time.
make_stub() {
	_target=$1
	cat > "$_target"
	chmod +x "$_target"
}

make_stub "$lab/lib/routing" <<'EOF'
#!/bin/sh
echo "routing $1" >> "$CALL_LOG"
[ "$1" = "up" ] && exit "${ROUTING_UP_RC:-0}"
exit 0
EOF

make_stub "$lab/lib/uci-export" <<'EOF'
#!/bin/sh
[ "${UCI_EXPORT_RC:-0}" = "0" ] || exit "$UCI_EXPORT_RC"
cat "$NEXT_RECORDS"
EOF

PATH="$bin:$PATH"
export PATH

# shellcheck disable=SC1090
. "$INIT"

# The paths are computed at the top level of the init script relative to
# /var, so they are overridden here: the directory and the records file
# inside it.
OUTDIR="$lab/out"
RECORDS="$OUTDIR/settings.tsv"
LIBDIR="$lab/lib"

NEXT_RECORDS="$lab/next.tsv"
CERT_FROM_UCI="$lab/cert_uci"
export NEXT_RECORDS CERT_FROM_UCI
: > "$CERT_FROM_UCI"

# Everything outside the scope of the check is replaced with logging stubs.
# regen_config is stubbed out among others because the real one moves
# records itself — and the test needs to see whether it got that far.
restart() { echo "restart keep_routing=${_TT_KEEP_ROUTING:-0}" >> "$CALL_LOG"; }
regen_config() {
	echo "regen_config" >> "$CALL_LOG"
	[ "${REGEN_RC:-0}" = "0" ] || return "$REGEN_RC"
	cp "$NEXT_RECORDS" "$RECORDS"
}
running() { return "${RUNNING_RC:-0}"; }
logger() { :; }

# The certificate never lands in records (PEM is multi-line), so apply_config
# compares it with a separate read of the ACTIVE server, resolved through the
# config shell library — stubbed here as one self-named endpoint section
# selected by TT_ACTIVE_SERVER, with the certificate served from CERT_FROM_UCI.
config_load() { :; }
config_foreach() {
	for _s in ${TT_ENDPOINT_SECTIONS:-Default}; do
		"$1" "$_s"
	done
}
config_get() {
	_var=$1
	_sec=$2
	_opt=$3
	_val=""
	case "$_opt" in
		endpoint) _val="${TT_ACTIVE_SERVER:-Default}" ;;
		name) _val="$_sec" ;;
		certificate) _val=$(cat "$CERT_FROM_UCI" 2>/dev/null) ;;
	esac
	eval "$_var=\"\$_val\""
}

# The call log is read as one line for the assertions below.
log_read() { tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//'; }

assert_log() {
	assert_contains "$(log_read)" "$1" "$2"
}

assert_no_log() {
	assert_eq "" "$(grep -F "$1" "$CALL_LOG" 2>/dev/null || true)" "$2"
}

seed_records() {
	cat <<'EOF'
main.enabled	1
endpoint.hostname	a.example
network.table	880
network.lan_devices	br-lan
EOF
}

# Prepares the applied state and the presumed new one, clears the log.
reset_state() {
	seed_records > "$RECORDS"
	seed_records > "$NEXT_RECORDS"
	: > "$CALL_LOG"
	unset ROUTING_UP_RC REGEN_RC UCI_EXPORT_RC RUNNING_RC _TT_KEEP_ROUTING
	export ROUTING_UP_RC REGEN_RC UCI_EXPORT_RC
}

# --- Cheap path -------------------------------------------------------------

# An edit of the LAN interfaces never reaches client.toml, so there is no
# reason to touch the client: regen_config, reload into the kernel and re-attach
# the route to the LIVE device.
reset_state
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
apply_config

assert_no_log 'restart' \
	"an edit of the LAN interfaces does not restart the client"
assert_log "routing up" \
	"but the rules are reloaded into the kernel"
assert_log "routing reattach" \
	"and the route is re-attached to the live device"

# The record of the applied state must keep up: the next apply compares with
# it, and without an update the same edit would count as a change every time.
assert_contains "$(cat "$RECORDS")" "br-guest" \
	"the applied-state record is updated"

# --- Proxy mode: no kernel routing ---------------------------------------------

# In proxy mode the routing options are inert: a reload-class edit still
# regenerates the records, but nothing is loaded into the kernel.
reset_state
printf 'main.mode\tproxy\n' >> "$RECORDS"
printf 'main.mode\tproxy\n' >> "$NEXT_RECORDS"
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
apply_config

assert_no_log 'restart' \
	"in proxy mode a LAN-interfaces edit does not restart the client"
assert_no_log 'routing up' \
	"in proxy mode no routing is loaded into the kernel"
assert_log "regen_config" \
	"in proxy mode the records are still regenerated"

# A mode switch rebuilds everything: the tun routing must come down with the
# old mode before the client starts in the new one.
reset_state
printf 'main.mode\tproxy\n' >> "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=0" \
	"switching the operation mode tears the routing down completely"

# --- Restart keeping routing --------------------------------------------------

reset_state
# `sed -i ''` is BSD-only: GNU sed treats the separate empty string as the
# script and the next token as a file, so the edit fails on CI. awk behaves
# identically on both, hence the temp file + mv.
awk '{ gsub(/a\.example/, "b.example"); print }' "$NEXT_RECORDS" > "$NEXT_RECORDS.tmp" && mv "$NEXT_RECORDS.tmp" "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=1" \
	"changing the server address restarts the client without tearing down routing"

reset_state
printf 'domains.direct\tbank.example\n' >> "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=1" \
	"a new exclusion restarts the client without tearing down routing"

reset_state
printf 'routing_profile.mode\tbypass\n' >> "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=1" \
	"a routing profile change restarts the client without tearing down routing"

# A pure REORDER of a list is a change too: the multiset of key/value
# pairs is identical, but the client measures the endpoint addresses in
# order, so keeping the old config would silently diverge from what the
# settings page shows.
reset_state
printf 'endpoint.address\t1.2.3.4:443\nendpoint.address\t[2001:db8::1]:443\n' >> "$RECORDS"
printf 'endpoint.address\t[2001:db8::1]:443\nendpoint.address\t1.2.3.4:443\n' >> "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=1" \
	"reordering the endpoint addresses restarts the client without tearing down routing"

# --- Restart with a full teardown ---------------------------------------------

# The table number and the mark are the only values that tear routing down.
# Keeping the old one and bringing up the new one would leave the old table
# and the old rule hanging forever.
reset_state
# Not every sed understands \t as an escape in an s/// script (BSD does not),
# while in an awk string it behaves the same everywhere, so the replacement
# goes through awk.
awk 'BEGIN { OFS = "\t" } $1 == "network.table" { $2 = "881" } { print }' \
	"$NEXT_RECORDS" > "$NEXT_RECORDS.tmp" && mv "$NEXT_RECORDS.tmp" "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=0" \
	"changing the table number tears routing down completely"

reset_state
awk 'BEGIN { OFS = "\t" } $1 == "main.enabled" { $2 = "0" } { print }' \
	"$NEXT_RECORDS" > "$NEXT_RECORDS.tmp" && mv "$NEXT_RECORDS.tmp" "$NEXT_RECORDS"
apply_config

assert_log "restart keep_routing=0" \
	"disabling the service tears routing down completely"

# --- Certificate ---------------------------------------------------------------

# The only schema value absent from records: PEM is multi-line. Without a
# separate comparison a certificate change would never be applied — records
# does not change with it, and the cheap path would decide there is nothing
# to do.
reset_state
printf -- '-----BEGIN CERTIFICATE-----\nnew\n-----END CERTIFICATE-----\n' > "$CERT_FROM_UCI"
apply_config

assert_log "restart" \
	"a certificate change restarts the client even though records did not change"

# And vice versa: an unchanged certificate must not by itself cause a restart.
reset_state
printf -- '-----BEGIN CERTIFICATE-----\nsame\n-----END CERTIFICATE-----\n' > "$CERT_FROM_UCI"
cp "$CERT_FROM_UCI" "$OUTDIR/endpoint.pem"
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
apply_config

assert_no_log 'restart' \
	"an unchanged certificate does not block the cheap path"
rm -f "$OUTDIR/endpoint.pem"
: > "$CERT_FROM_UCI"

# --- Rollbacks -----------------------------------------------------------------

# A failure on the cheap path must end in a full restart: at that moment the
# rules in the kernel are in an unknown state, and leaving things as they are
# would mean showing a working service on top of an under-loaded table.
reset_state
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
ROUTING_UP_RC=1
apply_config

assert_log "restart keep_routing=0" \
	"a routing up failure rolls back to a full restart"

reset_state
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
REGEN_RC=1
apply_config

assert_log "restart keep_routing=0" \
	"a regeneration failure rolls back to a full restart"

# There is nothing to compare with — this is a plain start, not an apply on
# top of a known state. /var on OpenWrt lives in tmpfs, so after a reboot
# there is no record.
reset_state
rm -f "$RECORDS"
apply_config

assert_log "restart" \
	"with no applied-state record — the full path"

# The service is not running: there is nothing to apply on top of.
reset_state
printf 'network.lan_devices\tbr-lan br-guest\n' >> "$NEXT_RECORDS"
RUNNING_RC=1
apply_config

assert_log "restart" \
	"a stopped service is applied via the full path"
unset RUNNING_RC

# UCI export failed — there is nothing to compare with, no basis for a decision.
reset_state
UCI_EXPORT_RC=1
apply_config

assert_log "restart" \
	"a UCI export failure rolls back to a full restart"
assert_eq "0" "$(ls "$OUTDIR" | grep -c 'settings.tsv.next' || true)" \
	"and leaves no half-written file with a password behind"

# --- Routing survives a restart ------------------------------------------------

# The real stop_service is checked, not a stub: it is the one that decides
# whether to call routing down.
reset_state
_TT_KEEP_ROUTING=1
stop_service

assert_no_log 'routing down' \
	"on a restart with keep-routing the routing is not torn down"

reset_state
_TT_KEEP_ROUTING=0
stop_service

assert_log "routing down" \
	"a plain stop tears routing down as before"

# An interrupted start. The "no teardown needed" reasoning rests on start
# bringing everything up again; if it does not reach the end, the service is
# off while the table, the mark rule and the blackhole would remain hanging,
# pointing at a non-existent tunnel. Marked traffic would go into the
# blackhole with the bypass off, and in the UI it would look like "no
# internet".
reset_state
_TT_KEEP_ROUTING=1
teardown_hanging_routing

assert_log "routing down" \
	"an interrupted start tears down the kept routing"
assert_eq "0" "${_TT_KEEP_ROUTING}" \
	"the flag is reset so a repeated call does not tear down twice"

tt_test_summary
