#!/bin/sh
# LuCI GUI interface tests — the browser layer of the view contract.
#
# The views run in a real headless chromium (the pinned Playwright image)
# against the pinned luci-base resources and a stubbed ubus backend
# (tests/gui/stub/server.js) that serves the backend contract goldens, so
# the browser sees byte-identical RPC responses to the ones
# tests/backend/test_backend_contract.sh pins. The specs assert on the
# rendered DOM and on the RPC frames the stub records.
#
# Usage:
#   sh tests/gui/run.sh
#   TT_GUI_REF=<luci commit> sh tests/gui/run.sh    # test against another luci-base
#   TT_GUI_IMAGE=<image>  sh tests/gui/run.sh       # override the Playwright image
#
# Docker-gated like the other harnesses: without docker or the pinned
# image the script reports SKIP (exit 77, the suite's skip status).
#
# The luci-base tarball and the npm dependencies are fetched on the host
# into tests/gui/.cache and tests/gui/node_modules (both gitignored); the
# container mounts the repo and runs stub + tests against localhost. The
# luci-base pin and fetch live in lib-luci.sh, shared with dev.sh — for a
# manual browser-based development loop (no docker, no build) run
# sh tests/gui/dev.sh.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PORT="${STUB_PORT:-8123}"
CACHE="$HERE/.cache"
LUCI_HTDOCS="$CACHE/modules/luci-base/htdocs"

. "$HERE/lib-luci.sh"

# openwrt/luci openwrt-25.12 branch — the LuCI generation the app targets.
# The views' require/module API and the loader (luci.js, view.ut, header.ut)
# move between generations; pinning the resources makes the harness
# deterministic. Bump deliberately and re-run the suite.
PLAYWRIGHT_IMAGE="${TT_GUI_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}"

command -v docker >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 77; }
docker info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "  SKIP: node not available (needed for npm ci and the stub)"; exit 77; }
command -v npm >/dev/null 2>&1 || { echo "  SKIP: npm not available"; exit 77; }
command -v curl >/dev/null 2>&1 || { echo "  SKIP: curl not available"; exit 77; }

# npm_ci — one npm ci attempt inside the gui directory.
npm_ci() {
	( cd "$HERE" && npm ci --no-audit --no-fund )
}

# The pinned Playwright image carries the browsers and their system
# dependencies; pull it when missing so the suite runs on a fresh runner
# (and locally on first use). Only an unreachable registry skips.
if ! docker image inspect "$PLAYWRIGHT_IMAGE" >/dev/null 2>&1; then
	echo "  pulling $PLAYWRIGHT_IMAGE ..."
	if ! tt_gui_retry 3 5 docker pull "$PLAYWRIGHT_IMAGE" >/dev/null 2>&1; then
		echo "  SKIP: could not pull $PLAYWRIGHT_IMAGE"
		exit 77
	fi
fi

# --- pinned luci-base resources ----------------------------------------------

if ! tt_gui_ensure_luci "$CACHE"; then
	echo "  SKIP: could not fetch the pinned luci-base tarball"
	exit 77
fi
[ -f "$LUCI_HTDOCS/luci-static/resources/luci.js" ] ||
	{ echo "  FAIL: luci-base resources missing at $LUCI_HTDOCS"; exit 1; }
[ -f "$CACHE/themes/luci-theme-bootstrap/htdocs/luci-static/bootstrap/cascade.css" ] ||
	{ echo "  FAIL: bootstrap theme css missing (stale cache; remove tests/gui/.cache and re-run)"; exit 1; }

# --- npm dependencies (host-side, mounted into the container) ----------------

if [ ! -d "$HERE/node_modules" ]; then
	echo "  installing playwright npm dependencies ..."
	if ! tt_gui_retry 3 5 npm_ci; then
		echo "  FAIL: npm ci failed"
		exit 1
	fi
fi

# --- run ----------------------------------------------------------------------

# Paths as the container sees them: the repo is mounted at /src.
LUCI_HTDOCS_IN="/src/tests/gui/.cache/modules/luci-base/htdocs"
THEME_HTDOCS_IN="/src/tests/gui/.cache/themes/luci-theme-bootstrap/htdocs"

echo "  running GUI specs in $PLAYWRIGHT_IMAGE ..."

docker run --rm \
	-v "$ROOT:/src" \
	-w /src \
	-e STUB_PORT="$PORT" \
	"$PLAYWRIGHT_IMAGE" \
	sh -c "
		node tests/gui/stub/server.js \
			--port '$PORT' \
			--app /src/packages/luci-app-trusttunnel/htdocs \
			--luci '$LUCI_HTDOCS_IN' \
			--theme '$THEME_HTDOCS_IN' \
			--goldens /src/tests/backend/goldens &
		SRV=\$!
		sleep 1
		cd /src/tests/gui
		node node_modules/@playwright/test/cli.js test -c playwright.config.js
		RC=\$?
		kill \$SRV 2>/dev/null
		exit \$RC
	"

exit $?
