# Shared UCI resolution helpers for the trusttunnel config.
#
# The active server is a repeatable endpoint section selected by name
# through main.endpoint. The resolution is re-implemented in every file
# that needs the ACTIVE server (uci-export to emit its records, the init
# script for the pinned certificate and the CA-store provisioning), and
# it carries a load-bearing guard: an unnamed endpoint section (empty
# `name` option) must never match an empty main.endpoint reference and
# leak its fields into the records. Both callers run the same code, so
# it lives here.
#
# This library works on a LOADED UCI config: it uses config_get /
# config_foreach from /lib/functions.sh, so callers must source that
# (or run under rc.common, which does) and run config_load trusttunnel
# before calling. It is meant to be sourced, not executed; the two
# functions assign the shared $server_sec / $server_want globals, which
# callers read after the call.

# config_foreach callback: record the endpoint section whose name matches
# the active server reference (main.endpoint); other sections are skipped.
# shellcheck disable=SC2317,SC2154
_tt_find_server() {
	_sec=$1
	_name=""
	config_get _name "$_sec" name
	[ "$_name" = "$server_want" ] || return 0
	server_sec="$_sec"
}

# tt_resolve_active_server — populate server_sec with the section id of
# the ACTIVE server, or empty when main.endpoint is absent or stale.
# server_want carries the resolved reference (empty when absent).
# Requires a prior config_load trusttunnel; mirrors uci-export's
# resolution. The guard is load-bearing: without it an unnamed endpoint
# section would match the empty reference and be treated as active.
tt_resolve_active_server() {
	server_sec=""
	server_want=""
	config_get server_want main endpoint
	[ -n "$server_want" ] || return 0
	config_foreach _tt_find_server endpoint
}
