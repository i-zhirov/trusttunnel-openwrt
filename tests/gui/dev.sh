#!/bin/sh
# Manual UI development server — develop and test the LuCI views in a real
# browser with no OpenWrt build, no docker and no release.
#
# The server (tests/gui/stub/server.js) serves the real views from
# packages/luci-app-trusttunnel/htdocs over the pinned luci-base loader
# (tests/gui/.cache — the same pin and cache as tests/gui/run.sh) with the
# backend contract goldens (tests/backend/goldens) standing in for the
# router, plus a live in-memory UCI state, so Save & Apply, the Import
# modal and the routing-profile editor all work.
#
# Usage:
#   sh tests/gui/dev.sh                      # serve on :8123, print the URLs
#   sh tests/gui/dev.sh --open               # ... and open the browser
#   sh tests/gui/dev.sh --port 9000          # different port (STUB_PORT too)
#   sh tests/gui/dev.sh --no-fetch           # skip the cache check (offline)
#
# To fake router state, hit the /__stub control endpoint:
#   curl -s http://127.0.0.1:8123/__stub                       # state + RPC frames
#   curl -s -X POST -d '{"set":{"status":{"running":false,"enabled":true}}}' \
#     http://127.0.0.1:8123/__stub                              # override a reply
#   curl -s -X POST -d '{"reset":true}' http://127.0.0.1:8123/__stub
#
# Overridable reply keys (a null value restores the golden): status,
# diagnose, ping, probe, log, service, checkDomain, importResult, versions,
# delays.
#
# Edit a view under packages/.../view/trusttunnel/ and reload the page —
# the stub sends no-cache headers, so a plain reload picks the change up.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PORT="${STUB_PORT:-8123}"
CACHE="$HERE/.cache"
LUCI_HTDOCS="$CACHE/modules/luci-base/htdocs"

. "$HERE/lib-luci.sh"

OPEN=0
DO_FETCH=1
while [ "$#" -gt 0 ]; do
	case "$1" in
	--open) OPEN=1 ;;
	--no-fetch) DO_FETCH=0 ;;
	--port) PORT=$2; shift ;;
	--port=*) PORT=${1#--port=} ;;
	*)
		echo "usage: sh tests/gui/dev.sh [--open] [--port N] [--no-fetch]" >&2
		exit 1
		;;
	esac
	shift
done

command -v node >/dev/null 2>&1 || { echo "FAIL: node not available (the stub needs it)"; exit 1; }

if [ "$DO_FETCH" -eq 1 ]; then
	command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not available (needed to fetch luci-base; use --no-fetch with an existing tests/gui/.cache)"; exit 1; }
	if ! tt_gui_ensure_luci "$CACHE"; then
		echo "FAIL: could not fetch the pinned luci-base tarball; retry later, or use --no-fetch with an existing tests/gui/.cache" >&2
		exit 1
	fi
fi
[ -f "$LUCI_HTDOCS/luci-static/resources/luci.js" ] ||
	{ echo "FAIL: luci-base resources missing at $LUCI_HTDOCS; run once without --no-fetch, or populate tests/gui/.cache with the pinned tarball" >&2; exit 1; }

node "$HERE/stub/server.js" \
	--port "$PORT" \
	--app "$ROOT/packages/luci-app-trusttunnel/htdocs" \
	--luci "$LUCI_HTDOCS" \
	--goldens "$ROOT/tests/backend/goldens" &
SRV=$!

trap 'exit 0' INT TERM
trap 'kill "$SRV" 2>/dev/null' EXIT

echo
echo "  TrustTunnel UI dev server on http://127.0.0.1:$PORT"
echo "    status:      http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/trusttunnel/status"
echo "    settings:    http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/trusttunnel/settings"
echo "    diagnostics: http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/trusttunnel/diagnostics"
echo "    stub state:  curl -s http://127.0.0.1:$PORT/__stub"
echo "  Fake a router state, e.g. a stopped service:"
echo "    curl -s -X POST -d '{\"set\":{\"status\":{\"running\":false,\"enabled\":true}}}' http://127.0.0.1:$PORT/__stub"
echo "  Reset everything:  curl -s -X POST -d '{\"reset\":true}' http://127.0.0.1:$PORT/__stub"
echo "  Ctrl-C to stop."
echo

sleep 1
if [ "$OPEN" -eq 1 ]; then
	url="http://127.0.0.1:$PORT/cgi-bin/luci/admin/services/trusttunnel/status"
	if command -v open >/dev/null 2>&1; then
		open "$url"
	elif command -v xdg-open >/dev/null 2>&1; then
		xdg-open "$url" >/dev/null 2>&1 &
	fi
fi

wait "$SRV"
