# tests/gui/lib-luci.sh — shared pinned-luci-base fetch for the GUI harnesses.
#
# Sourced by run.sh and dev.sh (POSIX sh, safe under `set -u`). The luci-base
# pin and the fetch/retry helpers live here so the test run and the manual
# dev server can never drift:
#
#   tt_gui_luci_ref        the pinned openwrt/luci commit (TT_GUI_REF overrides)
#   tt_gui_luci_url        the codeload tarball URL for that commit
#   tt_gui_retry <tries> <sleep> <cmd...>
#                          run cmd up to <tries> times, sleeping <sleep>
#                          seconds between attempts; succeed on the first
#                          exit 0 (the image pull, the fetch and npm ci all
#                          hit public registries where a transient failure
#                          must not fail the gate)
#   tt_gui_fetch_luci <cache>
#                          one fetch attempt: download the tarball and
#                          extract modules/luci-base/htdocs into <cache>
#   tt_gui_ensure_luci <cache>
#                          fetch when the cache is missing or carries another
#                          ref (a .ref marker); return 0 when the fetch
#                          succeeded or was not needed, 1 when it failed.
#                          The caller then verifies the expected files
#                          itself (run.sh FAILs on a broken cache, dev.sh
#                          errors out).
#
# The ref is the LuCI generation the views target (openwrt-25.12 branch).
# The loader (luci.js) and the module APIs move between generations;
# pinning the resources makes the harness deterministic. Bump deliberately
# and re-run the GUI suite.

TT_GUI_LUCI_REF="${TT_GUI_REF:-7f05feb8df075343b32672d69802e12fd6760d09}"
tt_gui_luci_url="https://codeload.github.com/openwrt/luci/tar.gz/$TT_GUI_LUCI_REF"

tt_gui_retry() {
	_tries=$1
	_sleep=$2
	shift 2
	_i=0
	while [ "$_i" -lt "$_tries" ]; do
		_i=$((_i + 1))
		if "$@"; then
			return 0
		fi
		[ "$_i" -lt "$_tries" ] && sleep "$_sleep"
	done
	return 1
}

# tt_gui_fetch_luci <cache> — one attempt: download to a temp file first,
# then extract. A pipe would hide a mid-stream curl failure inside tar's
# exit status.
tt_gui_fetch_luci() {
	_cache=$1
	curl -fsSL -o "$_cache/luci.tar.gz" "$tt_gui_luci_url" \
		&& tar -xz -C "$_cache" --strip-components=1 \
			-f "$_cache/luci.tar.gz" "luci-$TT_GUI_LUCI_REF/modules/luci-base/htdocs"
}

# tt_gui_ensure_luci <cache> — fetch when the cache is missing or stale
# (.ref marker mismatch). Returns 0 when the resources are in place (fetch
# succeeded or was not needed), 1 when the fetch failed.
tt_gui_ensure_luci() {
	_cache=$1

	mkdir -p "$_cache"
	if [ ! -f "$_cache/.ref" ] || [ "$(cat "$_cache/.ref")" != "$TT_GUI_LUCI_REF" ]; then
		echo "  fetching luci-base @ $TT_GUI_LUCI_REF ..."
		rm -rf "$_cache/modules"
		if ! tt_gui_retry 3 5 tt_gui_fetch_luci "$_cache"; then
			return 1
		fi
		rm -f "$_cache/luci.tar.gz"
		echo "$TT_GUI_LUCI_REF" > "$_cache/.ref"
	fi
}
