#!/bin/sh
# Integration harness — install and tunnel stages: the real install.sh
# against a locally assembled and served package repository, inside a
# dockerized OpenWrt router, connected to a real TrustTunnel endpoint
# container, with traffic verified through the tunnel.
#
# What it does, end to end:
#   1. preflight  — docker and /dev/net/tun availability;
#   2. packages   — the luci-app, i18n and client packages for the chosen
#      package manager, from TT_REPO_DIR (CI artifact layout) or, by
#      default, from the project's GitHub release;
#   3. repo       — assembles and signs a hermetic repository with a FRESH
#      keypair per run (apk: EC P-256 + mkndx/adbsign in the pinned alpine
#      image; opkg: usign + ipkg-make-index.sh, exactly the release.yml
#      recipe), then serves it from a python http.server container on the
#      lab network;
#   4. router     — boots an openwrt/rootfs container with /sbin/init and
#      configures its network with the router's own tools (uci import +
#      /etc/init.d/network restart);
#   5. endpoint   — runs the pinned TrustTunnel endpoint release (static
#      binary, self-signed certificate for tt.test) in a sibling container
#      on the lab network;
#   6. targets    — two REMOTE_ADDR oracle servers: one on the lab network
#      (reached through the tunnel), one on the docker default bridge
#      (private range, always direct);
#   7. install    — runs the repository's install.sh with TT_REPO_URL
#      pointing at the served repo;
#   8. asserts    — the install-side contract: exit 0, packages installed,
#      client binary runs, config seeded, firewall zone created, service
#      registered but not started, repository entry configured;
#   9. connect    — configures the endpoint via uci (hostname, address,
#      credentials, the PINNED certificate), enables and starts the
#      service, waits for the tunnel;
#  10. traffic    — the tunnel contract: service running, tun device and
#      routing state up, client log connected, client.toml carries the
#      pin, traffic to the lab target arrives with the ENDPOINT's source
#      address, traffic to the private target stays direct;
#  11. lifecycle  — killswitch and lifecycle contract: the blackhole
#      swallows marked traffic when the attached route is gone, a clean
#      stop tears the routing down and a start restores it, install.sh /
#      uci-defaults / reload are idempotent, and the endpoint log shows
#      the tunneled CONNECTs.
#
# Usage:
#   TT_PM=apk sh tests/integration/run.sh                 # default
#   TT_PM=opkg sh tests/integration/run.sh
#   TT_REPO_DIR=/path/to/dist sh tests/integration/run.sh # local packages
#   TT_RELEASE_TAG=v1.0.16 sh tests/integration/run.sh    # pinned release
#   TT_FILTER=traffic sh tests/integration/run.sh         # one stage
#   TT_KEEP=1 sh tests/integration/run.sh                 # keep containers
#
# Docker-gated like the other docker tests: without docker the harness
# reports SKIP (exit 77). It is deliberately NOT picked up by tests/run.sh
# (the runner globs tests/test_*.sh); CI runs it as its own workflow.
#
# The scratch dir lives under $HOME: Docker Desktop on macOS only shares
# paths under /Users (a /tmp or /var/folders mount silently appears empty
# in the container) — the same constraint install-harness.sh documents.
# The lab subnet must be a /24 with a globally-shaped range: the router's
# own marking rules refuse private ranges, and the endpoint refuses
# documentation ranges.
set -u

# --- knobs ---------------------------------------------------------------------

TT_PM="${TT_PM:-apk}"                       # apk | opkg
TT_LAB_SUBNET="${TT_LAB_SUBNET:-44.55.66.0/24}"
TT_REPO_DIR="${TT_REPO_DIR:-}"              # prebuilt package dir (flat)
TT_RELEASE_TAG="${TT_RELEASE_TAG:-latest}"
TT_SERVER_VERSION="${TT_SERVER_VERSION:-v1.1.0}"  # the endpoint release
TT_DIRECT_SUBNET="${TT_DIRECT_SUBNET:-192.168.77.0/24}"  # the private direct network
TT_LOGS_DIR="${TT_LOGS_DIR:-}"                  # fixed logs location (CI artifact)
TT_KEEP="${TT_KEEP:-0}"
TT_FILTER="${TT_FILTER:-}"

# The pinned alpine image release.yml uses for apk mkndx/adbsign (apk-tools
# 3.0.7); bash is added inside for the opkg index generator; the same image
# hosts the static endpoint binary. The python image serves the repository
# and the targets. The router images are the same ones the release
# verification installs into.
IMG_ALPINE="alpine:edge@sha256:266f29255458134745f2bf588cb23ed1ed1768b96ff2580a05d70a8aba59e145"
IMG_PYTHON="python@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc"
IMG_ROUTER_APK="openwrt/rootfs:x86-64-25.12.0"
IMG_ROUTER_OPKG="openwrt/rootfs:x86-64-22.03.7"

# SHA-256 of the endpoint release tarball (TrustTunnel v1.1.0, linux x86_64).
TT_SERVER_SHA256="91c2ea3db7416a01b5258a4c047ec22890490bc55e1b194206031aa75144f0e7"

case "$TT_PM" in
	apk)
		IMG_ROUTER=$IMG_ROUTER_APK
		# The local (SDK-built) client apk carries no -x86_64 suffix — the
		# release pipeline adds it only to keep the per-arch uploads apart.
		PM_GLOBS="luci-app-trusttunnel-*.apk luci-i18n-trusttunnel-*.apk trusttunnel-client-*.apk"
		PM_RELEASE_GLOBS="luci-app-trusttunnel-*.apk luci-i18n-trusttunnel-*.apk trusttunnel-client-*-x86_64.apk"
		;;
	opkg)
		IMG_ROUTER=$IMG_ROUTER_OPKG
		# ipk file names always carry the architecture.
		PM_GLOBS="luci-app-trusttunnel_*_all.ipk luci-i18n-trusttunnel-*_all.ipk trusttunnel-client_*_x86_64.ipk"
		PM_RELEASE_GLOBS="$PM_GLOBS"
		;;
	*)
		echo "error: unknown TT_PM=$TT_PM (apk or opkg)" >&2
		exit 2
		;;
esac

command -v docker >/dev/null 2>&1 || {
	echo "  SKIP: docker not available"
	exit 77
}
docker info >/dev/null 2>&1 || {
	echo "  SKIP: docker daemon not running"
	exit 77
}

# --- scratch and helpers --------------------------------------------------------

SCRATCH=$(mktemp -d "$HOME/.tt-integration.XXXXXX") || exit 1
SUFFIX=${SCRATCH##*.}
export TT_TEST_TMP="$SCRATCH/assert"
mkdir -p "$TT_TEST_TMP" "$SCRATCH/pkgs" "$SCRATCH/sign" "$SCRATCH/repo"

# shellcheck disable=SC1091
. "$(dirname "$0")/../lib.sh"

NET="ttit-$TT_PM-$SUFFIX"
REPO_CID="ttit-repo-$SUFFIX"
ROUTER_CID="ttit-router-$SUFFIX"
ENDPOINT_CID="ttit-endpoint-$SUFFIX"
TARGET_CID="ttit-target-$SUFFIX"
DIRECT_CID="ttit-direct-$SUFFIX"

# The lab subnet is a /24; the host octets are derived from it.
IP_BASE=${TT_LAB_SUBNET%/*}
IP_BASE=${IP_BASE%.*}
IP_REPO=$IP_BASE.10
IP_ENDPOINT=$IP_BASE.20
IP_ROUTER=$IP_BASE.30
IP_TARGET=$IP_BASE.40
DIRECT_IP=""    # the direct target's address on the private direct network
DIRECT_NET="ttit-direct-$SUFFIX"

# stage <name> — returns 0 when the stage is selected by TT_FILTER: a
# space-separated list of stage names (a partial run needs the stages it
# depends on — e.g. TT_FILTER="serve router targets" — the dependencies
# are documented in the header); an empty filter selects everything.
stage() {
	case " $TT_FILTER " in
		*" $1 "*) return 0 ;;
		"  ") return 0 ;;
		*) return 1 ;;
	esac
}

teardown() {
	[ -n "${ROUTER_CID:-}" ] && docker rm -f "$ROUTER_CID" >/dev/null 2>&1
	[ -n "${REPO_CID:-}" ] && docker rm -f "$REPO_CID" >/dev/null 2>&1
	[ -n "${ENDPOINT_CID:-}" ] && docker rm -f "$ENDPOINT_CID" >/dev/null 2>&1
	[ -n "${TARGET_CID:-}" ] && docker rm -f "$TARGET_CID" >/dev/null 2>&1
	[ -n "${DIRECT_CID:-}" ] && docker rm -f "$DIRECT_CID" >/dev/null 2>&1
	[ -n "${DIRECT_NET:-}" ] && docker network rm "$DIRECT_NET" >/dev/null 2>&1
	[ -n "${NET:-}" ] && docker network rm "$NET" >/dev/null 2>&1
}

# dump_logs — on failure, collect the router state and the container logs
# into the logs directory BEFORE the teardown removes the containers.
# TT_LOGS_DIR gives CI a fixed place for the artifact upload; otherwise
# the logs live in the scratch.
dump_logs() {
	_logs="${TT_LOGS_DIR:-$SCRATCH/logs}"
	mkdir -p "$_logs"
	[ -f "$SCRATCH/install.out" ] && cp "$SCRATCH/install.out" "$_logs/"
	[ -f "$SCRATCH/reinstall.out" ] && cp "$SCRATCH/reinstall.out" "$_logs/"
	if [ -n "${ROUTER_CID:-}" ] && docker ps -q -f name="$ROUTER_CID" >/dev/null 2>&1; then
		docker exec "$ROUTER_CID" sh -c 'logread 2>/dev/null' \
			> "$_logs/router-logread.txt" 2>/dev/null
		docker exec "$ROUTER_CID" sh -c 'logread 2>/dev/null | grep -i trusttunnel' \
			> "$_logs/router-trusttunnel.log" 2>/dev/null
		docker exec "$ROUTER_CID" sh -c \
			'/usr/libexec/trusttunnel/routing status /var/etc/trusttunnel/settings.tsv 2>/dev/null' \
			> "$_logs/router-routing-status.txt" 2>/dev/null
		docker exec "$ROUTER_CID" sh -c \
			'ip route show 2>/dev/null; echo ---; ip rule show 2>/dev/null; echo ---; nft list table inet trusttunnel 2>/dev/null' \
			> "$_logs/router-kernel-state.txt" 2>/dev/null
		docker exec "$ROUTER_CID" sh -c \
			'cat /var/etc/trusttunnel/client.toml /etc/config/trusttunnel 2>/dev/null' \
			> "$_logs/router-config.txt" 2>/dev/null
		docker exec "$ROUTER_CID" sh -c \
			'cat /etc/apk/repositories.d/trusttunnel.list /etc/opkg/customfeeds.conf /etc/apk/keys/trusttunnel.pub 2>/dev/null; ls /etc/opkg/keys 2>/dev/null' \
			> "$_logs/router-repo-config.txt" 2>/dev/null
	fi
	for _c in "$ENDPOINT_CID" "$TARGET_CID" "$DIRECT_CID" "$REPO_CID"; do
		[ -n "$_c" ] || continue
		docker logs "$_c" > "$_logs/$(basename "$_c").log" 2>&1
	done
	printf '  collected logs in: %s\n' "$_logs"
}

finish() {
	_f=$(cat "$TT_TEST_TMP/failed" 2>/dev/null) || _f=1
	if [ "$_f" != "0" ]; then
		dump_logs
		printf '  integration state and logs left in: %s\n' "$SCRATCH"
	fi
	# TT_KEEP=1 keeps the containers and the network for debugging.
	if [ "$TT_KEEP" != "1" ]; then
		teardown
		if [ "$_f" = "0" ]; then
			rm -rf "$SCRATCH"
		fi
	fi
}
trap finish EXIT INT TERM

# --- stage: preflight ------------------------------------------------------------

st_preflight() {
	stage preflight || return
	echo "== preflight"
	if docker run --rm --device /dev/net/tun "$IMG_ROUTER" true >/dev/null 2>&1; then
		_tt_pass "the docker VM exposes /dev/net/tun"
		return
	fi
	# Best-effort fallback for hosts where the node is missing but the
	# module is loaded (CI VMs): create the node, then re-check.
	docker run --rm --privileged --cap-add SYS_MODULE "$IMG_ROUTER" \
		sh -c 'mkdir -p /dev/net && mknod -m 666 /dev/net/tun c 10 200 2>/dev/null; true' >/dev/null 2>&1
	if docker run --rm --device /dev/net/tun "$IMG_ROUTER" true >/dev/null 2>&1; then
		_tt_pass "the docker VM exposes /dev/net/tun (after mknod fallback)"
	else
		_tt_fail "/dev/net/tun is not available in the docker VM (load the tun module on the host)"
	fi
}

# --- stage: packages ------------------------------------------------------------

# collect_pkgs <dir> — copies the packages matching the PM globs into the
# scratch; fails when any of the three expected packages is missing.
collect_pkgs() {
	_src=$1
	for _pat in $PM_GLOBS; do
		_found=0
		for _f in "$_src"/$_pat; do
			[ -f "$_f" ] || continue
			cp "$_f" "$SCRATCH/pkgs/" || return 1
			_found=1
		done
		[ "$_found" = "1" ] || return 1
	done
	return 0
}

# verify_pkgs — every PM glob must match at least one collected file.
verify_pkgs() {
	for _pat in $PM_GLOBS; do
		_found=0
		for _f in "$SCRATCH/pkgs"/$_pat; do
			[ -f "$_f" ] && _found=1
		done
		[ "$_found" = "1" ] || return 1
	done
	return 0
}

# local_dist_dir — the dist/ built by build-sdk.sh (or the CI artifact
# layout), when it already holds this PM's packages; prints the dir path
# or nothing. Tree-built packages are preferred over the published
# release: the release can lag the tree (a released package predating a
# fix would otherwise fail the tunnel assertions for no reason).
local_dist_dir() {
	[ -d "$PWD/dist" ] || return 1
	for _pat in $PM_GLOBS; do
		for _f in "$PWD/dist"/$_pat; do
			[ -f "$_f" ] && {
				printf '%s' "$PWD/dist"
				return 0
			}
		done
	done
	return 1
}

st_pkgs() {
	stage pkgs || return
	echo "== packages"
	if [ -n "$TT_REPO_DIR" ]; then
		if collect_pkgs "$TT_REPO_DIR"; then
			_tt_pass "packages collected from TT_REPO_DIR=$TT_REPO_DIR"
		else
			_tt_fail "TT_REPO_DIR=$TT_REPO_DIR does not hold all $TT_PM packages (globs: $PM_GLOBS)"
			return
		fi
	elif _local=$(local_dist_dir) && [ -n "$_local" ]; then
		if collect_pkgs "$_local"; then
			_tt_pass "packages collected from the local SDK build ($_local)"
		else
			_tt_fail "dist/ does not hold all $TT_PM packages (globs: $PM_GLOBS)"
			return
		fi
	else
		# Download the matching assets of the latest (or pinned) release.
		_api="https://api.github.com/repos/i-zhirov/trusttunnel-openwrt/releases/latest"
		[ "$TT_RELEASE_TAG" = "latest" ] || \
			_api="https://api.github.com/repos/i-zhirov/trusttunnel-openwrt/releases/tags/$TT_RELEASE_TAG"
		_json=$(curl -fsSL "$_api" 2>/dev/null) || _json=""
		if [ -z "$_json" ]; then
			_tt_fail "could not fetch the release info from $_api"
			return
		fi
		_tag=$(printf '%s' "$_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])') || _tag=""
		_names=$(printf '%s' "$_json" | python3 -c '
import json, fnmatch, sys
r = json.load(sys.stdin)
for a in r.get("assets", []):
    if any(fnmatch.fnmatch(a["name"], p) for p in sys.argv[1].split()):
        print(a["name"])
' "$PM_RELEASE_GLOBS") || _names=""
		_missing=0
		for _name in $_names; do
			curl -fsSL -o "$SCRATCH/pkgs/$_name" \
				"https://github.com/i-zhirov/trusttunnel-openwrt/releases/download/$_tag/$_name" \
				>/dev/null 2>&1 || _missing=$((_missing + 1))
		done
		if [ "$_missing" -eq 0 ] && verify_pkgs; then
			_tt_pass "release $_tag: packages downloaded"
		else
			_tt_fail "release $_tag did not provide all $TT_PM packages"
			return
		fi
	fi
	_n=$(ls "$SCRATCH/pkgs" | grep -c .)
	_tt_pass "collected $_n package files for the $TT_PM repository"
}

# --- stage: repo -----------------------------------------------------------------

assemble_apk_repo() {
	_dir="$SCRATCH/repo/apk/x86_64"
	mkdir -p "$_dir"
	# EC P-256 — the same key type as the project's committed key-build.pub.
	if ! openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
			-out "$SCRATCH/sign/apk.sec" 2>/dev/null; then
		_tt_fail "apk signing key generation failed"
		return 1
	fi
	if ! openssl pkey -in "$SCRATCH/sign/apk.sec" -pubout \
			-out "$SCRATCH/repo/apk/key-build.pub" 2>/dev/null; then
		_tt_fail "apk public key export failed"
		return 1
	fi
	cp "$SCRATCH/pkgs"/*.apk "$_dir/"
	# Every package file is renamed to its metadata-derived name (name-
	# version.apk): apk fetches by that name. The release assets carry a
	# -x86_64 suffix (keeps the per-arch uploads apart) and the i18n
	# version's tilde is mangled into a dot by GitHub — both would 404.
	if ! docker run --rm -v "$SCRATCH:/w" "$IMG_ALPINE" sh -c '
			set -e
			cd /w/repo/apk/x86_64
			for f in *.apk; do
				meta=$(apk adbdump "$f" 2>/dev/null) || exit 1
				name=$(printf "%s\n" "$meta" | awk "/^  name: / { print \$2; exit }")
				version=$(printf "%s\n" "$meta" | awk "/^  version: / { print \$2; exit }")
				[ -n "$name" ] && [ -n "$version" ] || exit 1
				canonical="${name}-${version}.apk"
				[ "$f" = "$canonical" ] || mv "$f" "$canonical"
			done
		'; then
		_tt_fail "apk package renaming to metadata names failed"
		return 1
	fi
	# Index and sign in the pinned alpine image, exactly like release.yml.
	if ! docker run --rm -v "$SCRATCH:/w" "$IMG_ALPINE" sh -c '
			set -e
			cd /w/repo/apk/x86_64
			apk mkndx --allow-untrusted --output packages.adb --arch x86_64 *.apk
			apk adbsign --allow-untrusted --sign-key /w/sign/apk.sec packages.adb
		' >/dev/null 2>&1; then
		_tt_fail "apk index generation or signing failed"
		return 1
	fi
	return 0
}

assemble_opkg_repo() {
	mkdir -p "$SCRATCH/repo/opkg"
	cp "$SCRATCH/pkgs"/*.ipk "$SCRATCH/repo/opkg/"
	# usign keypair: usign lives in the opkg router image.
	if ! docker run --rm -v "$SCRATCH/sign:/s" "$IMG_ROUTER_OPKG" \
			sh -c 'cd /s && usign -G -s opkg.sec -p opkg.pub' >/dev/null 2>&1; then
		_tt_fail "usign key generation failed"
		return 1
	fi
	cp "$SCRATCH/sign/opkg.pub" "$SCRATCH/repo/opkg/opkg-key.pub"
	# The canonical index generator, fetched at run time — the same source
	# release.yml uses.
	if ! curl -fsSL -o "$SCRATCH/ipkg-make-index.sh" \
			https://raw.githubusercontent.com/openwrt/openwrt/openwrt-22.03/scripts/ipkg-make-index.sh; then
		_tt_fail "could not fetch ipkg-make-index.sh"
		return 1
	fi
	cat > "$SCRATCH/mkhash.sh" <<'EOF'
#!/bin/sh
sha256sum "$2" | cut -d" " -f1
EOF
	chmod +x "$SCRATCH/mkhash.sh"
	# The generator needs bash and GNU stat/sha256sum, so it runs inside
	# the pinned alpine image (bash added there) — the macOS host bash and
	# BSD stat cannot run it.
	if ! docker run --rm -v "$SCRATCH:/w" "$IMG_ALPINE" sh -c '
			set -e
			apk add -q bash >/dev/null 2>&1
			cd /w/repo/opkg
			MKHASH=/w/mkhash.sh bash /w/ipkg-make-index.sh . > Packages.manifest 2>/dev/null
			grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
			rm -f Packages.manifest
		'; then
		_tt_fail "opkg index generation failed"
		return 1
	fi
	# usign cannot sign SHA-512 messages of two specific sizes (the same
	# workaround the release pipeline applies); padding the index by two
	# empty lines shifts it past the affected sizes.
	_size=$(wc -c < "$SCRATCH/repo/opkg/Packages")
	if [ $(( (64 + _size) % 128 )) -eq 110 ] || [ $(( (64 + _size) % 128 )) -eq 111 ]; then
		printf '\n\n' >> "$SCRATCH/repo/opkg/Packages"
	fi
	gzip -9nc "$SCRATCH/repo/opkg/Packages" > "$SCRATCH/repo/opkg/Packages.gz"
	if ! docker run --rm -v "$SCRATCH/repo/opkg:/repo" \
			-v "$SCRATCH/sign/opkg.sec:/opkg.sec:ro" "$IMG_ROUTER_OPKG" \
			sh -c 'cd /repo && usign -S -s /opkg.sec -m Packages -x Packages.sig' >/dev/null 2>&1; then
		_tt_fail "opkg index signing failed"
		return 1
	fi
	return 0
}

st_repo() {
	stage repo || return
	echo "== assembling the $TT_PM repository"
	if [ "$TT_PM" = "apk" ]; then
		if assemble_apk_repo; then
			_tt_pass "apk repository assembled and signed (key-build.pub, x86_64/packages.adb)"
		fi
	else
		if assemble_opkg_repo; then
			_tt_pass "opkg repository assembled and signed (opkg-key.pub, Packages, Packages.sig)"
		fi
	fi
}

# --- stage: serve ----------------------------------------------------------------

st_serve() {
	stage serve || return
	echo "== serving the repository"
	if ! docker network create --subnet "$TT_LAB_SUBNET" "$NET" >/dev/null 2>&1; then
		_tt_fail "could not create the lab network $NET"
		return
	fi
	if ! docker run -d --name "$REPO_CID" --network "$NET" --ip "$IP_REPO" \
			-v "$SCRATCH/repo:/repo:ro" "$IMG_PYTHON" \
			python3 -m http.server 8080 --directory /repo >/dev/null 2>&1; then
		_tt_fail "could not start the repository server"
		return
	fi
	_probe=apk/key-build.pub
	[ "$TT_PM" = "opkg" ] && _probe=opkg/opkg-key.pub
	# The python server takes a couple of seconds to bind its socket on a
	# cold start; a connect into that window fails with busybox wget's
	# "Operation not permitted", so the health check polls instead of
	# asserting on the first attempt.
	_i=0
	_got=""
	while [ "$_i" -lt 10 ]; do
		_i=$((_i + 1))
		_got=$(docker run --rm --network "$NET" "$IMG_ROUTER" \
			sh -c "wget -qO- --timeout=5 http://$IP_REPO:8080/$_probe" 2>/dev/null) || _got=""
		[ -n "$_got" ] && break
		sleep 2
	done
	if [ -n "$_got" ]; then
		_tt_pass "the repository server answers on the lab network"
	else
		_tt_fail "the repository server is unreachable from the lab network"
	fi
}

# --- stage: router ---------------------------------------------------------------

# wait_firewall — the network restart reloads fw4 asynchronously; until the
# input chain carries the lan-zone rule for eth0, inbound replies are
# dropped and the install's first wget fails ("Operation not permitted"
# from busybox). The install must not start before the rule lands.
wait_firewall() {
	_i=0
	while [ "$_i" -lt 20 ]; do
		_i=$((_i + 1))
		if docker exec "$ROUTER_CID" \
				sh -c 'nft list chain inet fw4 input 2>/dev/null | grep -q "iifname \"eth0\""' \
				>/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

# wait_eth0_ip — on 22.03 the static address lands on eth0 later than on
# 25.12 (netifd brings the interface up asynchronously); the install needs
# the address before it can reach the repository, so this polls.
wait_eth0_ip() {
	_i=0
	while [ "$_i" -lt 30 ]; do
		_i=$((_i + 1))
		_got=$(docker exec "$ROUTER_CID" \
			sh -c 'ip -4 addr show eth0 | grep -o "inet [0-9.]*" | head -1' 2>/dev/null)
		[ "$_got" = "inet $IP_ROUTER" ] && return 0
		sleep 1
	done
	return 1
}

configure_router_network() {
	# The static lan config: eth0 carries the lab address, the docker
	# embedded DNS resolves names. The bridge device (if the image created
	# one at first boot) is removed so eth0 is NOT enslaved.
	{
		printf 'package network\n\n'
		printf 'config interface "lan"\n'
		printf '\toption device "eth0"\n'
		printf '\toption proto "static"\n'
		printf '\toption ipaddr "%s"\n' "$IP_ROUTER"
		printf '\toption netmask "255.255.255.0"\n'
		printf '\toption gateway "%s.1"\n' "$IP_BASE"
		printf '\toption dns "127.0.0.11"\n'
	} > "$SCRATCH/network.uci"
	if ! docker cp "$SCRATCH/network.uci" "$ROUTER_CID:/tmp/network.uci" >/dev/null 2>&1; then
		_tt_fail "could not copy the network config into the router"
		return 1
	fi
	if ! docker exec "$ROUTER_CID" sh -c '
			uci -q delete network.@device[0] 2>/dev/null || true
			uci -q delete network.lan 2>/dev/null || true
			uci import network < /tmp/network.uci || exit 1
			/etc/init.d/network restart >/dev/null 2>&1 || exit 1
			sleep 2
		'; then
		_tt_fail "the router network configuration failed"
		return 1
	fi
	if wait_eth0_ip; then
		_tt_pass "eth0 carries $IP_ROUTER"
	else
		_tt_fail "eth0 does not carry $IP_ROUTER (got: $_got)"
	fi
	if docker exec "$ROUTER_CID" sh -c 'ip link show eth0 | grep -q master' 2>/dev/null; then
		_tt_fail "eth0 is enslaved to a bridge; the router network is not usable"
	else
		_tt_pass "eth0 is a plain interface"
	fi
	# The gateway ping right after the interface comes up can miss a beat;
	# a few retries keep the check deterministic.
	_i=0
	_ping_ok=0
	while [ "$_i" -lt 10 ]; do
		_i=$((_i + 1))
		if docker exec "$ROUTER_CID" sh -c "ping -c 1 -W 3 $IP_BASE.1 >/dev/null 2>&1"; then
			_ping_ok=1
			break
		fi
		sleep 1
	done
	if [ "$_ping_ok" = "1" ]; then
		_tt_pass "the lab gateway answers ICMP"
	else
		_tt_fail "the lab gateway does not answer ICMP"
	fi
	_dns=$(docker exec "$ROUTER_CID" sh -c 'grep nameserver /etc/resolv.conf | head -1' 2>/dev/null)
	if [ -n "$_dns" ]; then
		_tt_pass "resolv.conf carries a nameserver ($_dns)"
	else
		_tt_fail "resolv.conf has no nameserver"
	fi
	if wait_firewall; then
		_tt_pass "the firewall accepts the lan interface (eth0)"
	else
		_tt_fail "the firewall never loaded the lan-zone rule for eth0"
	fi
}

st_router() {
	stage router || return
	echo "== booting the router container"
	if ! docker run -d --name "$ROUTER_CID" --network "$NET" --ip "$IP_ROUTER" \
			--cap-add NET_ADMIN --device /dev/net/tun \
			-v "$PWD:/src:ro" "$IMG_ROUTER" /sbin/init >/dev/null 2>&1; then
		_tt_fail "could not start the router container"
		return
	fi
	_i=0
	while ! docker exec "$ROUTER_CID" sh -c 'ps | grep -q "[p]rocd"' >/dev/null 2>&1; do
		_i=$((_i + 1))
		[ "$_i" -ge 60 ] && {
			_tt_fail "procd did not come up in the router"
			return
		}
		sleep 1
	done
	_tt_pass "router booted with procd"
	configure_router_network
}

# --- stage: endpoint ---------------------------------------------------------------

st_endpoint() {
	stage endpoint || return
	echo "== endpoint container"
	_srv="$SCRATCH/srv"
	mkdir -p "$_srv"
	_tb="trusttunnel-v${TT_SERVER_VERSION#v}-linux-x86_64.tar.gz"
	if [ ! -f "$_srv/endpoint.bin" ]; then
		if ! curl -fsSL -o "$_srv/$_tb" \
				"https://github.com/TrustTunnel/TrustTunnel/releases/download/$TT_SERVER_VERSION/$_tb"; then
			_tt_fail "could not download the endpoint release $TT_SERVER_VERSION"
			return
		fi
		_got=$(openssl dgst -sha256 "$_srv/$_tb" 2>/dev/null | awk '{print $NF}')
		if [ "$_got" != "$TT_SERVER_SHA256" ]; then
			_tt_fail "endpoint release checksum mismatch (got $_got, expected $TT_SERVER_SHA256)"
			return
		fi
		if ! tar -xzf "$_srv/$_tb" -C "$_srv"; then
			_tt_fail "could not unpack the endpoint release"
			return
		fi
		mv "$_srv"/trusttunnel-*/trusttunnel_endpoint "$_srv/endpoint.bin"
	fi
	cp "$PWD/tests/integration/fixtures/vpn.toml" "$_srv/"
	cp "$PWD/tests/integration/fixtures/hosts.toml" "$_srv/"
	cp "$PWD/tests/integration/fixtures/credentials.toml" "$_srv/"
	# Self-signed certificate for tt.test. The SAN matters: the client
	# checks the hostname against the PINNED certificate, so the pin is
	# exercised for real only when the SAN matches the SNI. The config
	# file form works on both LibreSSL (macOS) and OpenSSL (CI).
	cat > "$_srv/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = tt.test
[v3]
subjectAltName = DNS:tt.test
EOF
	if ! openssl req -x509 -newkey rsa:2048 -keyout "$_srv/key.pem" \
			-out "$_srv/cert.pem" -days 30 -nodes \
			-config "$_srv/openssl.cnf" >/dev/null 2>&1; then
		_tt_fail "endpoint certificate generation failed"
		return
	fi
	if ! openssl x509 -in "$_srv/cert.pem" -noout -text 2>/dev/null | grep -q "DNS:tt.test"; then
		_tt_fail "the endpoint certificate carries no SAN for tt.test"
		return
	fi
	_tt_pass "endpoint release and self-signed certificate prepared"
	if ! docker run -d --name "$ENDPOINT_CID" --network "$NET" --ip "$IP_ENDPOINT" \
			-v "$_srv:/opt/tt:ro" "$IMG_ALPINE" \
			sh -c 'cp /opt/tt/endpoint.bin /bin/trusttunnel_endpoint && chmod +x /bin/trusttunnel_endpoint && cd /opt/tt && trusttunnel_endpoint vpn.toml hosts.toml -l debug' \
			>/dev/null 2>&1; then
		_tt_fail "could not start the endpoint container"
		return
	fi
	_i=0
	while [ "$_i" -lt 30 ]; do
		_i=$((_i + 1))
		docker logs "$ENDPOINT_CID" 2>&1 | grep -q "Listening to TCP 0.0.0.0:8443" && break
		sleep 1
	done
	_listen=$(docker logs "$ENDPOINT_CID" 2>&1 | grep -E "Listening to (TCP|UDP) 0.0.0.0:8443" | tr '\n' ' ')
	if printf '%s' "$_listen" | grep -q "TCP 0.0.0.0:8443" \
			&& printf '%s' "$_listen" | grep -q "UDP 0.0.0.0:8443"; then
		_tt_pass "the endpoint listens on TCP and UDP 8443"
	else
		_tt_fail "the endpoint did not come up"
		docker logs "$ENDPOINT_CID" 2>&1 | tail -5
	fi
}

# --- stage: targets -----------------------------------------------------------------

st_targets() {
	stage targets || return
	echo "== target servers"
	_whoami="$PWD/tests/integration/fixtures/whoami.py"
	if ! docker run -d --name "$TARGET_CID" --network "$NET" --ip "$IP_TARGET" \
			-v "$_whoami:/whoami.py:ro" "$IMG_PYTHON" \
			python3 /whoami.py >/dev/null 2>&1; then
		_tt_fail "could not start the lab target"
		return
	fi
	# The direct target lives on a dedicated PRIVATE network (never marked
	# by the router). A custom docker network adds only the connected
	# route — joining the docker DEFAULT bridge would inject a second
	# default route, and the client's interface selection could then pick
	# the wrong one and dial the endpoint via the wrong gateway.
	if ! docker network create --subnet "$TT_DIRECT_SUBNET" "$DIRECT_NET" >/dev/null 2>&1; then
		_tt_fail "could not create the direct network $DIRECT_NET"
		return
	fi
	if ! docker run -d --name "$DIRECT_CID" --network "$DIRECT_NET" \
			-v "$_whoami:/whoami.py:ro" "$IMG_PYTHON" \
			python3 /whoami.py >/dev/null 2>&1; then
		_tt_fail "could not start the direct target"
		return
	fi
	if ! docker network connect "$DIRECT_NET" "$ROUTER_CID" >/dev/null 2>&1; then
		_tt_fail "could not connect the router to the direct network"
		return
	fi
	_i=0
	while [ "$_i" -lt 20 ]; do
		_i=$((_i + 1))
		# The range form: a hyphenated network name cannot appear as a
		# template field (Go templates reject "-").
		DIRECT_IP=$(docker inspect --format \
			'{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}' \
			"$DIRECT_CID" 2>/dev/null | awk '{print $1}')
		[ -n "$DIRECT_IP" ] && break
		sleep 1
	done
	if [ -z "$DIRECT_IP" ]; then
		_tt_fail "the direct target got no address on $DIRECT_NET"
		return
	fi
	_i=0
	while [ "$_i" -lt 30 ]; do
		_i=$((_i + 1))
		docker exec "$ROUTER_CID" sh -c "ip -4 addr show eth1 | grep -q 'inet '" >/dev/null 2>&1 && break
		sleep 1
	done
	# The direct-net connect can race the lab default route's installation
	# (netifd adds the static default asynchronously; docker's connected
	# gateway can win with metric 0). The client dials the endpoint
	# through the interface of the default route, so the lab default is
	# enforced here and its presence is asserted. Busybox ip (still in
	# effect before install.sh) ignores the default filter, hence the
	# explicit ^default counting.
	docker exec "$ROUTER_CID" sh -c "ip route replace default via $IP_BASE.1 dev eth0" >/dev/null 2>&1
	_def=$(docker exec "$ROUTER_CID" sh -c 'ip route show default' 2>/dev/null)
	_cnt=$(printf '%s\n' "$_def" | grep -c '^default')
	_gw=$(printf '%s\n' "$_def" | grep '^default' | grep -c "via $IP_BASE.1")
	if [ "$_cnt" = "1" ] && [ "$_gw" = "1" ]; then
		_tt_pass "the router carries exactly one default route, via the lab gateway"
	else
		_tt_fail "the router default route is not the lab gateway (got: $(printf '%s\n' "$_def" | tr '\n' ';'))"
	fi
	# The python servers take a moment to bind their sockets on a cold
	# start (the same race as the repository server); poll until both
	# answer before asserting anything about them.
	_i=0
	_targets_ok=0
	while [ "$_i" -lt 20 ]; do
		_i=$((_i + 1))
		_got=$(docker exec "$ROUTER_CID" sh -c "wget -4 -qO- --timeout=5 http://$IP_TARGET:8080/" 2>/dev/null)
		[ "$_got" = "REMOTE_ADDR=$IP_ROUTER" ] && _targets_ok=1 && break
		sleep 2
	done
	# Pre-tunnel sanity: both targets answer with the ROUTER's own address
	# while nothing is marked yet (the service is still disabled).
	_got=$(docker exec "$ROUTER_CID" sh -c "wget -4 -qO- --timeout=10 http://$IP_TARGET:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$IP_ROUTER" "$_got" "the lab target answers directly before the tunnel"
	_src=$(docker exec "$ROUTER_CID" sh -c "ip route get $DIRECT_IP | grep -o 'src [0-9.]*' | awk '{print \$2}' | head -1" 2>/dev/null)
	_i=0
	while [ "$_i" -lt 20 ]; do
		_i=$((_i + 1))
		_got=$(docker exec "$ROUTER_CID" sh -c "wget -4 -qO- --timeout=5 http://$DIRECT_IP:8080/" 2>/dev/null)
		[ "$_got" = "REMOTE_ADDR=$_src" ] && break
		sleep 2
	done
	_got=$(docker exec "$ROUTER_CID" sh -c "wget -4 -qO- --timeout=10 http://$DIRECT_IP:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$_src" "$_got" "the private target answers directly (source: the router itself)"
}

# --- stage: install ----------------------------------------------------------------

st_install() {
	stage install || return
	echo "== running install.sh"
	# run_install — one install.sh attempt against the served repository.
	run_install() {
		docker exec -e TT_REPO_URL="http://$IP_REPO:8080" "$ROUTER_CID" \
			sh /src/install.sh > "$SCRATCH/install.out" 2>&1
		return $?
	}
	run_install
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		# The package-manager update hits the public OpenWrt mirrors, and
		# a transient download failure (busybox wget does not retry) is
		# the common flake. install.sh is safe to rerun — its repository
		# setup is idempotent, which A15 asserts — so one retry is
		# attempted before failing.
		echo "  install.sh failed (rc=$_rc); retrying once"
		sleep 5
		run_install
		_rc=$?
	fi
	if [ "$_rc" -eq 0 ]; then
		_tt_pass "install.sh exits 0"
	else
		_tt_fail "install.sh exits 0 (got $_rc)"
	fi
	if grep -q "== Done" "$SCRATCH/install.out"; then
		_tt_pass "the closing banner is printed"
	else
		_tt_fail "the closing banner is missing from the install output"
	fi
}

# --- stage: install-side assertions ------------------------------------------------

assert_packages_installed() {
	if [ "$TT_PM" = "apk" ]; then
		if docker exec "$ROUTER_CID" \
				apk info -e luci-app-trusttunnel luci-i18n-trusttunnel-ru trusttunnel-client \
				>/dev/null 2>&1; then
			_tt_pass "apk reports luci-app, i18n and client installed"
		else
			_tt_fail "apk does not report all three packages installed"
			# The failure diagnosis: which of the three is missing, and
			# whether the served index even carries the i18n package.
			docker exec "$ROUTER_CID" \
				sh -c 'for p in luci-app-trusttunnel luci-i18n-trusttunnel-ru trusttunnel-client; do apk info -e "$p" >/dev/null 2>&1 && echo "$p: installed" || echo "$p: MISSING"; done' 2>/dev/null
			docker exec "$ROUTER_CID" \
				sh -c 'apk search luci-i18n-trusttunnel-ru 2>/dev/null | head -2' 2>/dev/null
		fi
	else
		_got=$(docker exec "$ROUTER_CID" sh -c \
			'opkg list-installed 2>/dev/null | grep -cE "^(luci-app-trusttunnel|luci-i18n-trusttunnel-ru|trusttunnel-client) "')
		assert_eq "3" "$_got" "opkg reports luci-app, i18n and client installed"
	fi
}

st_asserts() {
	stage asserts || return
	echo "== install-side assertions"

	assert_packages_installed

	_ver=$(docker exec "$ROUTER_CID" /opt/trusttunnel_client/trusttunnel_client --version 2>/dev/null) || _ver=""
	case $_ver in
		trusttunnel_client*)
			_tt_pass "the client binary runs ($_ver)"
			;;
		*)
			_tt_fail "the client binary does not run (got: $_ver)"
			;;
	esac

	_rp=$(docker exec "$ROUTER_CID" uci -q get trusttunnel.endpoint.routing_profile 2>/dev/null)
	assert_eq "Default" "$_rp" "the endpoint is assigned the Default profile"
	_prof=$(docker exec "$ROUTER_CID" uci -q get 'trusttunnel.@routing_profile[0].name' 2>/dev/null)
	assert_eq "Default" "$_prof" "the seeded routing profile is named Default"
	_mode=$(docker exec "$ROUTER_CID" uci -q get 'trusttunnel.@routing_profile[0].mode' 2>/dev/null)
	assert_eq "vpn" "$_mode" "the seeded profile is vpn mode"

	_zone=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep \"name='trusttunnel'\"" 2>/dev/null)
	assert_contains "$_zone" "name='trusttunnel'" "the trusttunnel firewall zone exists"
	_dev=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep \"device='tun+'\"" 2>/dev/null)
	assert_contains "$_dev" "device='tun+'" "the zone is bound to the tun+ wildcard"
	_fwd=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep \"dest='trusttunnel'\"" 2>/dev/null)
	assert_contains "$_fwd" "dest='trusttunnel'" "the lan to trusttunnel forwarding exists"

	if docker exec "$ROUTER_CID" /etc/init.d/trusttunnel enabled >/dev/null 2>&1; then
		_tt_pass "the service is registered for boot"
	else
		_tt_fail "the service is not registered for boot"
	fi
	_proc=$(docker exec "$ROUTER_CID" sh -c 'ps | grep "[t]rusttunnel_client"' 2>/dev/null)
	assert_eq "" "$_proc" "a fresh install does not start the client"
	_tun=$(docker exec "$ROUTER_CID" sh -c 'ls /sys/class/net/ | grep -c tun' 2>/dev/null)
	assert_eq "0" "$_tun" "a fresh install creates no tun device"

	if [ "$TT_PM" = "apk" ]; then
		_list=$(docker exec "$ROUTER_CID" cat /etc/apk/repositories.d/trusttunnel.list 2>/dev/null)
		assert_contains "$_list" "http://$IP_REPO:8080/apk/x86_64/packages.adb" \
			"the apk repository entry points at the served index"
		_key=$(docker exec "$ROUTER_CID" cat /etc/apk/keys/trusttunnel.pub 2>/dev/null)
		assert_contains "$_key" "BEGIN PUBLIC KEY" "the apk signing key is installed"
	else
		_feeds=$(docker exec "$ROUTER_CID" cat /etc/opkg/customfeeds.conf 2>/dev/null)
		assert_contains "$_feeds" "src/gz trusttunnel http://$IP_REPO:8080/opkg" \
			"the opkg feed entry points at the served repository"
		_keys=$(docker exec "$ROUTER_CID" sh -c 'ls /etc/opkg/keys' 2>/dev/null)
		assert_contains "$_keys" "trusttunnel.pub" "the opkg key is installed under the stable name"
		_fp=$(docker exec "$ROUTER_CID" sh -c 'usign -F -p /etc/opkg/keys/trusttunnel.pub' 2>/dev/null)
		if [ -n "$_fp" ] && docker exec "$ROUTER_CID" sh -c "test -f /etc/opkg/keys/$_fp" >/dev/null 2>&1; then
			_tt_pass "the opkg key is installed under its usign fingerprint"
		else
			_tt_fail "the fingerprint-named opkg key copy is missing"
		fi
	fi
}

# --- stage: connect ---------------------------------------------------------------

# wait_tunnel <label> — polls for the established tunnel: the client log
# reports the connection AND the tun device carries traffic. Both must
# hold: the log line alone could come from an earlier incarnation, the
# carrier alone appears while the client is still connecting.
wait_tunnel() {
	_i=0
	while [ "$_i" -lt 60 ]; do
		_i=$((_i + 1))
		if docker exec "$ROUTER_CID" \
				sh -c 'logread 2>/dev/null | grep -q "Successfully connected to endpoint"' \
				>/dev/null 2>&1 \
				&& [ "$(docker exec "$ROUTER_CID" sh -c 'cat /sys/class/net/tun0/carrier 2>/dev/null' 2>/dev/null)" = "1" ]; then
			_tt_pass "$1"
			return 0
		fi
		sleep 1
	done
	_tt_fail "$1 (the tunnel did not come up within 60s)"
	docker exec "$ROUTER_CID" sh -c 'logread | grep trusttunnel | tail -8' 2>/dev/null
	return 1
}

st_connect() {
	stage connect || return
	echo "== configuring and starting the service"
	# The direct-net connect (targets stage) can race the lab default's
	# installation; the client picks its endpoint interface from the
	# default route, so the lab default is enforced right before the
	# service starts.
	docker exec "$ROUTER_CID" sh -c "ip route replace default via $IP_BASE.1 dev eth0" >/dev/null 2>&1
	if ! docker cp "$SCRATCH/srv/cert.pem" "$ROUTER_CID:/tmp/cert.pem" >/dev/null 2>&1; then
		_tt_fail "could not copy the pinned certificate into the router"
		return
	fi
	# The endpoint is configured with the router's own tools, exactly like
	# the README's headless example — plus the PINNED certificate, which is
	# what the client verifies against (skip_verification stays off).
	cat > "$SCRATCH/configure.sh" <<EOF
#!/bin/sh
set -e
uci set trusttunnel.endpoint.hostname='tt.test'
uci add_list trusttunnel.endpoint.address='$IP_ENDPOINT:8443'
uci set trusttunnel.endpoint.username='router'
uci set trusttunnel.endpoint.password='test-pass'
uci set trusttunnel.endpoint.certificate="\$(cat /tmp/cert.pem)"
uci set trusttunnel.network.lan_devices='eth0'
uci set trusttunnel.network.include_router_traffic='1'
uci set trusttunnel.main.enabled='1'
uci commit trusttunnel
/etc/init.d/trusttunnel enable
/etc/init.d/trusttunnel start
EOF
	if ! docker cp "$SCRATCH/configure.sh" "$ROUTER_CID:/tmp/configure.sh" >/dev/null 2>&1; then
		_tt_fail "could not copy the configure script into the router"
		return
	fi
	if docker exec "$ROUTER_CID" sh /tmp/configure.sh >/dev/null 2>&1; then
		_tt_pass "the service is configured and started"
	else
		_tt_fail "the service configuration or start failed"
		return
	fi
	wait_tunnel "the tunnel came up"
}

# --- stage: traffic assertions -------------------------------------------------------

st_traffic() {
	stage traffic || return
	echo "== tunnel and traffic assertions"

	# A7: the service is running and the procd instance is alive.
	if docker exec "$ROUTER_CID" /etc/init.d/trusttunnel running >/dev/null 2>&1; then
		_tt_pass "the service reports running"
	else
		_tt_fail "the service does not report running"
	fi
	_pid=$(docker exec "$ROUTER_CID" sh -c 'cat /var/run/trusttunnel.pid 2>/dev/null' 2>/dev/null)
	if [ -n "$_pid" ] && docker exec "$ROUTER_CID" sh -c "kill -0 $_pid 2>/dev/null"; then
		_tt_pass "the procd instance is alive (pid $_pid)"
	else
		_tt_fail "the procd instance pidfile is missing or the process is dead"
	fi

	# A8: the tun device and the routing state.
	_carrier=$(docker exec "$ROUTER_CID" sh -c 'cat /sys/class/net/tun0/carrier 2>/dev/null' 2>/dev/null)
	assert_eq "1" "$_carrier" "tun0 exists with the carrier up"
	_rs=$(docker exec "$ROUTER_CID" \
		sh -c '/usr/libexec/trusttunnel/routing status /var/etc/trusttunnel/settings.tsv' 2>/dev/null)
	assert_contains "$_rs" "device up" "routing: the tunnel device is up"
	assert_contains "$_rs" "client device tun0" "routing: the route is attached to tun0"
	assert_contains "$_rs" "rule present" "routing: the fwmark rule is present"
	assert_contains "$_rs" "table present" "routing: table 880 carries the route"
	assert_contains "$_rs" "nft present" "routing: the nft table is present"

	# A9: the client log reports the established connection.
	_log=$(docker exec "$ROUTER_CID" \
		sh -c 'logread | grep "Successfully connected to endpoint" | head -1' 2>/dev/null)
	assert_contains "$_log" "Successfully connected to endpoint" \
		"the client log reports the connection"

	# A10: the generated client.toml carries the pinned certificate and the
	# fixed contract fields.
	_toml=$(docker exec "$ROUTER_CID" cat /var/etc/trusttunnel/client.toml 2>/dev/null)
	assert_contains "$_toml" "certificate = '''" \
		"client.toml opens the pinned certificate literal"
	assert_contains "$_toml" "-----BEGIN CERTIFICATE-----" \
		"client.toml carries the pinned PEM"
	assert_contains "$_toml" "killswitch_enabled = false" \
		"client.toml leaves the killswitch to the routing table"
	assert_contains "$_toml" "change_system_dns = false" \
		"client.toml never changes the system DNS"
	assert_contains "$_toml" 'vpn_mode = "general"' \
		"the Default profile means general mode"

	# A11: traffic to the lab target flows through the tunnel — the target
	# observes the ENDPOINT's address as the source.
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$IP_TARGET:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$IP_ENDPOINT" "$_got" \
		"traffic to the lab target arrives with the endpoint's source address"

	# A12: traffic to the private target stays direct — the target observes
	# the ROUTER's own address (the source the main table picks for it).
	_src=$(docker exec "$ROUTER_CID" \
		sh -c "ip route get $DIRECT_IP 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print \$2}' | head -1" 2>/dev/null)
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$DIRECT_IP:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$_src" "$_got" \
		"traffic to the private target stays direct (source: the router itself)"
}

# --- stage: killswitch and lifecycle assertions -------------------------------------

st_lifecycle() {
	stage lifecycle || return
	echo "== killswitch and lifecycle assertions"

	# --- A13: the blackhole killswitch, at the kernel level ------------------
	# While the tunnel is up, marked traffic resolves via tun0 (table
	# 880's default). Bringing the device down makes the kernel drop the
	# attached route by itself — table 880 then holds only the blackhole,
	# and the same marked lookup fails (ip route get answers EINVAL for a
	# blackhole match). The device is then brought up and the route
	# re-attached exactly like the routing helper's attach does. The
	# lookup is deterministic: no client process is involved, so there is
	# nothing to race.
	_lk=$(docker exec "$ROUTER_CID" sh -c "ip route get $IP_TARGET mark 0x9527 2>&1" 2>/dev/null)
	if printf '%s' "$_lk" | grep -q "dev tun0"; then
		_tt_pass "marked traffic routes via the tunnel device"
	else
		_tt_fail "marked traffic does not route via tun0 (got: $_lk)"
	fi
	docker exec "$ROUTER_CID" sh -c "ip link set tun0 down" >/dev/null 2>&1
	sleep 1
	_lk=$(docker exec "$ROUTER_CID" sh -c "ip route get $IP_TARGET mark 0x9527 2>&1" 2>/dev/null)
	if printf '%s' "$_lk" | grep -q "RTNETLINK answers"; then
		_tt_pass "with the device down, the marked lookup fails into the blackhole"
	else
		_tt_fail "the marked lookup should have failed into the blackhole (got: $_lk)"
	fi
	docker exec "$ROUTER_CID" sh -c "ip link set tun0 up" >/dev/null 2>&1
	docker exec "$ROUTER_CID" sh -c "ip route replace default dev tun0 table 880" >/dev/null 2>&1
	_lk=$(docker exec "$ROUTER_CID" sh -c "ip route get $IP_TARGET mark 0x9527 2>&1" 2>/dev/null)
	if printf '%s' "$_lk" | grep -q "dev tun0"; then
		_tt_pass "the re-attached route restores the tunnel path"
	else
		_tt_fail "the re-attached route does not restore the tunnel path (got: $_lk)"
	fi

	# --- A14: a clean stop tears everything down; a start restores it -------
	docker exec "$ROUTER_CID" /etc/init.d/trusttunnel stop >/dev/null 2>&1
	_i=0
	while [ "$_i" -lt 20 ]; do
		_i=$((_i + 1))
		[ -z "$(docker exec "$ROUTER_CID" sh -c 'ps | grep "[t]rusttunnel_client"' 2>/dev/null)" ] && break
		sleep 1
	done
	_rs=$(docker exec "$ROUTER_CID" \
		sh -c '/usr/libexec/trusttunnel/routing status /var/etc/trusttunnel/settings.tsv' 2>/dev/null)
	assert_contains "$_rs" "device down" "a clean stop leaves no attached device"
	assert_contains "$_rs" "rule absent" "a clean stop removes the fwmark rule"
	assert_contains "$_rs" "table absent" "a clean stop removes the routing table"
	assert_contains "$_rs" "nft absent" "a clean stop removes the nft table"
	_proc=$(docker exec "$ROUTER_CID" sh -c 'ps | grep "[t]rusttunnel_client"' 2>/dev/null)
	assert_eq "" "$_proc" "a clean stop exits the client"
	_tun=$(docker exec "$ROUTER_CID" sh -c 'ls /sys/class/net/ 2>/dev/null | grep -c tun' 2>/dev/null)
	assert_eq "0" "$_tun" "a clean stop removes the tun device"
	# Nothing is marked after a clean stop: both targets observe the
	# router's own address (no tunnel, no blackhole, no leak into the
	# tunnel path).
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$IP_TARGET:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$IP_ROUTER" "$_got" \
		"a stopped service sends the lab target direct"
	_src=$(docker exec "$ROUTER_CID" \
		sh -c "ip route get $DIRECT_IP 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print \$2}' | head -1" 2>/dev/null)
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$DIRECT_IP:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$_src" "$_got" "a stopped service keeps the private path direct"
	if docker exec "$ROUTER_CID" /etc/init.d/trusttunnel start >/dev/null 2>&1; then
		_tt_pass "the service starts again"
	else
		_tt_fail "the service does not start again"
	fi
	wait_tunnel "the restart brings the tunnel back"
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$IP_TARGET:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$IP_ENDPOINT" "$_got" "the restored tunnel carries traffic again"

	# --- A15: idempotence ----------------------------------------------------
	# The uci-defaults rerun (while the script still exists) creates no
	# duplicates. The apk path consumes the script during the install:
	# apk runs /etc/uci-defaults/* right after placing them and removes
	# them (the seeding banner in install.sh is the fallback that only
	# fires on opkg). The rerun therefore runs only when the file is
	# still there; the no-duplicate STATE is asserted on both paths.
	if docker exec "$ROUTER_CID" sh -c 'test -x /etc/uci-defaults/40-luci-trusttunnel' >/dev/null 2>&1; then
		if docker exec "$ROUTER_CID" /etc/uci-defaults/40-luci-trusttunnel >/dev/null 2>&1; then
			_tt_pass "the uci-defaults rerun exits 0"
		else
			_tt_fail "the uci-defaults rerun failed"
		fi
	else
		_tt_pass "the uci-defaults script was consumed by the package manager"
	fi
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep -c \"name='trusttunnel'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the firewall zone is not duplicated"
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep -c \"dest='trusttunnel'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the lan to trusttunnel forwarding is not duplicated"
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show trusttunnel | grep -c \"name='Default'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the Default routing profile is not duplicated"
	# install.sh rerun: exit 0 and no duplicated repository entry (the
	# reinstalled service brings the tunnel back — install.sh restarts a
	# running service on purpose).
	docker exec -e TT_REPO_URL="http://$IP_REPO:8080" "$ROUTER_CID" \
		sh /src/install.sh > "$SCRATCH/reinstall.out" 2>&1
	assert_eq "0" "$?" "install.sh rerun exits 0"
	if [ "$TT_PM" = "apk" ]; then
		_n=$(docker exec "$ROUTER_CID" sh -c 'grep -c . /etc/apk/repositories.d/trusttunnel.list 2>/dev/null' 2>/dev/null)
		assert_eq "1" "$_n" "the apk repository entry is not duplicated"
	else
		_n=$(docker exec "$ROUTER_CID" sh -c 'grep -c "^src/gz trusttunnel " /etc/opkg/customfeeds.conf 2>/dev/null' 2>/dev/null)
		assert_eq "1" "$_n" "the opkg feed line is not duplicated"
	fi
	wait_tunnel "the reinstalled service brings the tunnel back"
	# The reinstall's own uci-defaults run (by apk on 25.12, by install.sh
	# on 22.03) must leave the same single-zone, single-forwarding,
	# single-profile state.
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep -c \"name='trusttunnel'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the reinstall does not duplicate the firewall zone"
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show firewall | grep -c \"dest='trusttunnel'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the reinstall does not duplicate the forwarding"
	_n=$(docker exec "$ROUTER_CID" sh -c "uci show trusttunnel | grep -c \"name='Default'\"" 2>/dev/null)
	assert_eq "1" "$_n" "the reinstall does not duplicate the Default profile"
	# A reload with nothing changed is a noop: the applied-state records
	# match the fresh export, so nothing is regenerated and the tunnel
	# stays up.
	docker exec "$ROUTER_CID" /etc/init.d/trusttunnel reload >/dev/null 2>&1
	_log=$(docker exec "$ROUTER_CID" sh -c 'logread | grep "nothing to do" | tail -1' 2>/dev/null)
	assert_contains "$_log" "nothing to do" "an unchanged reload is a noop"
	_got=$(docker exec "$ROUTER_CID" sh -c "curl -4 -s --max-time 20 http://$IP_TARGET:8080/" 2>/dev/null)
	assert_eq "REMOTE_ADDR=$IP_ENDPOINT" "$_got" "the tunnel survives the noop reload"

	# --- A16: the endpoint saw the tunneled CONNECTs --------------------------
	# The endpoint (started with -l debug) logs every tunneled CONNECT;
	# their presence is the server-side confirmation that the traffic
	# really traveled through the tunnel.
	_n=$(docker logs "$ENDPOINT_CID" 2>/dev/null | grep -c "CONNECT")
	if [ "$_n" -gt 0 ]; then
		_tt_pass "the endpoint logged tunneled CONNECT requests"
	else
		_tt_fail "the endpoint logged no CONNECT requests"
	fi
	_n=$(docker logs "$ENDPOINT_CID" 2>/dev/null | grep -c "$IP_TARGET:8080")
	if [ "$_n" -gt 0 ]; then
		_tt_pass "the endpoint saw the tunneled requests for the lab target"
	else
		_tt_fail "the endpoint never saw a request for the lab target"
	fi
}

# --- main -------------------------------------------------------------------------

st_preflight
st_pkgs
st_repo
st_serve
st_router
st_endpoint
st_targets
st_install
st_asserts
st_connect
st_traffic
st_lifecycle

tt_test_summary
