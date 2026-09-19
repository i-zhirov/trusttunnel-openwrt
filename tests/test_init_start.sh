#!/bin/sh
# start_service: the main.enabled gate and the explicit-start bypass.
#
# WHY. The Status page invites "Press Start to run it now" while the
# service is disabled, but start_service used to refuse EVERY start while
# main.enabled was off — the button errored with "The service did not
# start", and the reason lived only in syslog. main.enabled means "start
# on boot": it must gate the AUTOMATIC starts (boot, the wan-up trigger,
# a config reload) while an explicit start from the Status page — the rpcd
# backend sets TT_START_NOW=1 — runs the tunnel now. The automatic paths
# never set the marker, so a disabled service stays off across boot and
# config edits, and unchecking "start on boot" while the service runs
# still stops it (pinned in test_init_reload.sh).
. "$(dirname "$0")/lib.sh"

INIT="packages/luci-app-trusttunnel/root/etc/init.d/trusttunnel"

lab="$TT_TEST_TMP/lab"
bin="$lab/bin"
mkdir -p "$bin" "$lab/lib" "$lab/out"

CALL_LOG="$lab/calls.log"
export CALL_LOG

# The stub scripts append their calls to a log: there is no procd, UCI or
# real routing on the developer machine, so it is the only evidence to
# judge by.
make_stub() {
	_target=$1
	cat > "$_target"
	chmod +x "$_target"
}

make_stub "$lab/lib/routing" <<'EOF'
#!/bin/sh
echo "routing $1" >> "$CALL_LOG"
exit 0
EOF

make_stub "$bin/client" <<'EOF'
#!/bin/sh
exit 0
EOF

PATH="$bin:$PATH"
export PATH

# shellcheck disable=SC1090
. "$INIT"

# The paths and the client binary are computed at the top level of the
# init script, so they are overridden here, like the records file.
OUTDIR="$lab/out"
RECORDS="$OUTDIR/settings.tsv"
LIBDIR="$lab/lib"
CLIENT="$bin/client"

# Everything outside the scope of the check is replaced with logging stubs.
# regen_config is stubbed because the real one needs uci-export and
# gen-config; the markers under test are the enabled gate and the procd
# instance opening.
regen_config() {
	echo "regen_config" >> "$CALL_LOG"
	return 0
}
logger() { echo "logger $*" >> "$CALL_LOG"; }
await_default_route() { return 0; }
await_clock() { return 0; }
highest_ifindex() { echo 0; }
procd_open_instance() { echo "procd_open_instance" >> "$CALL_LOG"; }
procd_set_param() { echo "procd_set_param $1" >> "$CALL_LOG"; }
procd_close_instance() { echo "procd_close_instance" >> "$CALL_LOG"; }

# rc.common dispatches start/stop to start_service/stop_service with procd;
# the harness models that dispatch so restart() keeps working.
start() { start_service; }
stop() { stop_service; }

# There is no /lib/functions.sh on the developer machine: config_load is a
# no-op and config_get_bool is driven by the test's env vars. The values
# the init script reads are main.enabled, main.endpoint (the active-server
# resolution) and the active endpoint's skip_verification (provision_ca_store
# short-circuits on it). The endpoint sections are modeled as one
# self-named section per word of TT_ENDPOINT_SECTIONS, selected by
# TT_ACTIVE_SERVER.
config_load() { :; }
config_foreach() {
	for _s in ${TT_ENDPOINT_SECTIONS:-Default}; do
		"$1" "$_s"
	done
}
config_get_bool() {
	_var=$1
	_sec=$2
	_opt=$3
	_def=${4:-0}
	case "$_sec.$_opt" in
		main.enabled) _val=${MAIN_ENABLED:-$_def} ;;
		*.skip_verification) _val=${SKIP_VERIFICATION:-$_def} ;;
		*) _val=$_def ;;
	esac
	eval "$_var=$_val"
}
config_get() {
	_var=$1
	_sec=$2
	_opt=$3
	_val=""
	case "$_opt" in
		endpoint) _val="${TT_ACTIVE_SERVER:-Default}" ;;
		name) _val="$_sec" ;;
	esac
	eval "$_var=\"\$_val\""
}

# The applied-state record: tun mode, so a successful start must run
# `routing up` — the marker must not skip the kernel wiring.
cat > "$RECORDS" <<'EOF'
main.enabled	0
main.mode	tun
endpoint.hostname	a.example
EOF

# The call log is read as one line for the assertions below.
log_read() { tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//'; }

reset_state() {
	: > "$CALL_LOG"
	unset TT_START_NOW MAIN_ENABLED SKIP_VERIFICATION
	export SKIP_VERIFICATION=1
}

# --- The gate ----------------------------------------------------------------

# While the service is disabled, an ordinary start (the boot path, the
# wan-up trigger, a config reload) must refuse — that is what "disabled"
# means. The refusal is a quiet exit 0: the caller must not see an error
# from the init script itself.
reset_state
MAIN_ENABLED=0
start_service
assert_eq "0" "$?" "a refused start is not an error for the caller"
assert_contains "$(log_read)" "service is disabled in the configuration; not starting" \
	"the disabled start logs the reason"
assert_eq "" "$(grep -F 'procd_open_instance' "$CALL_LOG" || true)" \
	"a refused start never opens a procd instance"
assert_eq "" "$(grep -F 'routing up' "$CALL_LOG" || true)" \
	"a refused start never wires the kernel routing"

# An enabled service starts on the plain path — the marker must not be
# required for the normal case.
reset_state
MAIN_ENABLED=1
start_service
assert_contains "$(log_read)" "procd_open_instance" \
	"an enabled service starts without the marker"
assert_contains "$(log_read)" "routing up" \
	"a successful start wires the kernel routing (tun mode)"

# --- The explicit-start bypass -----------------------------------------------

# The Status page start button (the rpcd backend sets TT_START_NOW=1) must
# run the tunnel now even while the service is disabled for boot.
reset_state
MAIN_ENABLED=0
TT_START_NOW=1
start_service
assert_eq "" "$(grep -F 'service is disabled' "$CALL_LOG" || true)" \
	"an explicit start while disabled is not refused"
assert_contains "$(log_read)" "procd_open_instance" \
	"an explicit start opens the procd instance"
assert_contains "$(log_read)" "routing up" \
	"an explicit start wires the kernel routing (tun mode)"

# The marker also survives a restart — restart is stop + start in the same
# shell, and the env var is what the backend relies on for the Restart
# button while disabled.
reset_state
MAIN_ENABLED=0
TT_START_NOW=1
restart
assert_contains "$(log_read)" "procd_open_instance" \
	"an explicit restart while disabled starts the service"

# Without the marker the same restart stays off: the wan-up trigger and
# the config-reload paths call restart without it, and a disabled service
# must not come up behind the user's back.
reset_state
MAIN_ENABLED=0
restart
assert_eq "" "$(grep -F 'procd_open_instance' "$CALL_LOG" || true)" \
	"an automatic restart while disabled stays off"

tt_test_summary
