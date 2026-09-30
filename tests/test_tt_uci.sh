#!/bin/sh
# tt_resolve_active_server, pinned from the active-server contract.
#
# WHY. The resolution is shared by uci-export (the records emitter) and
# the init script (the pinned certificate, the CA-store provisioning):
# both run the same code through tt-uci.sh, and its guard is load-
# bearing — an unnamed endpoint section (empty `name` option) must never
# match an empty main.endpoint reference and leak its fields into the
# records or hand its certificate to the client. The contract test and
# the integration suite only exercise the resolution indirectly; this
# test pins the guard and the stale/empty outcomes without docker or a
# router.
#
# The UCI shell library (config_get/config_foreach from
# /lib/functions.sh) is stubbed exactly like test_init_regenerate.sh:
# the endpoint sections are named by TT_ACTIVE (main.endpoint) and each
# section's own `name` option comes from the case below.
. "$(dirname "$0")/lib.sh"

. packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel/tt-uci.sh

config_load() { :; }

config_foreach() {
	# $1 is the callback, $2 the section type: the three endpoint
	# sections, one of which (Unnamed) has an empty `name` option.
	for _s in Default Backup Unnamed; do
		"$1" "$_s"
	done
}

config_get() {
	_var=$1
	_sec=$2
	_opt=$3
	_val=""
	case "$_opt" in
		endpoint) _val="$TT_ACTIVE" ;;
		name)
			case "$_sec" in
				Default) _val=Default ;;
				Backup) _val=Backup ;;
				Unnamed) _val="" ;;
			esac
			;;
	esac
	eval "$_var=\"\$_val\""
}

# The active server is resolved by NAME: the section whose `name` matches
# main.endpoint wins, other sections are skipped.
TT_ACTIVE=Backup
tt_resolve_active_server
assert_eq "Backup" "$server_sec" "the section named by main.endpoint is the active one"
assert_eq "Backup" "$server_want" "server_want carries the resolved reference"

# A stale reference (no section carries that name) resolves to no server;
# the resolution is not a guess.
TT_ACTIVE=Missing
tt_resolve_active_server
assert_eq "" "$server_sec" "a stale reference yields no active server"
assert_eq "Missing" "$server_want" "the stale reference is reported as requested"

# An empty reference must match NOTHING — in particular not the unnamed
# section, whose empty `name` would otherwise satisfy the comparison and
# leak its fields as the active server's records. This is the guard.
TT_ACTIVE=""
tt_resolve_active_server
assert_eq "" "$server_sec" "an empty reference never matches the unnamed section"
assert_eq "" "$server_want" "an empty reference stays empty"

# A named reference still skips the unnamed section: only the section
# whose name equals the reference wins.
TT_ACTIVE=Default
tt_resolve_active_server
assert_eq "Default" "$server_sec" "the unnamed section is skipped for a named reference"

tt_test_summary
