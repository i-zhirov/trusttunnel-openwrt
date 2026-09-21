#!/bin/sh
# Contract test for the rpcd backend: loads luci.trusttunnel the same way
# rpcd does (module value = the top-level return) and byte-compares its
# responses against the golden set — the behavioral contract.
#
# Five phases, five golden sets:
#   goldens/*.json           — the baked stub rootfs state (no tun device:
#                              /dev/net/tun shadowed, tun device check fails)
#   goldens/router-off/*.json — the baked state with include_router_traffic
#                              flipped to 0: the plain probe must be direct,
#                              so identical addresses pin the failure branch
#                              and its stale-output-chain hint
#   goldens/healthy/*.json   — after creating a real tun device in a
#                              privileged container and restoring the
#                              healthy stubs (device present paths)
#   goldens/stopped/*.json   — the service stopped: the kernel checks must
#                              report skip, not fail
#   goldens/proxy/*.json     — proxy mode, records swapped to the SOCKS
#                              listener, no kernel routing, nothing bound
#   goldens/proxy-healthy/*.json — proxy mode with a live listener on the
#                              configured address and a tunnel-answering
#                              curl stub
#   goldens/bypass/*.json     — a bypass profile with an empty VPN-rules
#                              list: nothing is tunneled by config, so the
#                              tunnel check becomes a remark instead of a
#                              misleading failure
#   goldens/bypass-rule/*.json — the bypass profile with one tunneled
#                              domain rule: the check probes that rule
#                              through the tunnel (the "tunnel reaches"
#                              ok branch)
#   goldens/bypass-rule-off/*.json — the same rule but the via leg fails:
#                              the "no response through the tunnel"
#                              failure branch
#   goldens/bypass-wildcard/*.json — a bypass profile whose only rule is a
#                              *.domain wildcard: the apex is not tunneled
#                              by the client, so nothing is probeable and
#                              the check remarks instead of probing
#   goldens/vpn-wildcard-bypass/*.json — a VPN profile with a wildcard
#                              bypass rule covering the echo service: the
#                              echo selection must skip it and pick the
#                              next host (the stub answers only there)
#
# Docker-gated like test_uci_defaults.sh: without docker the test reports
# SKIP (exit 77, tt_skip), which the suite runner counts as skipped — the
# plain suite stays runnable on machines without docker.
. "$(dirname "$0")/../lib.sh"

command -v docker >/dev/null 2>&1 || tt_skip "docker not available"
docker info >/dev/null 2>&1 || tt_skip "docker daemon not running"

BASE="$(dirname "$0")"
MOD="$BASE/mod/luci/trusttunnel.uc"
BACKEND=packages/luci-app-trusttunnel/root/usr/share/rpcd/ucode/luci.trusttunnel

# retry <tries> <sleep> <cmd...> — run the command up to <tries> times,
# sleeping <sleep> seconds between attempts; succeed on the first exit 0.
# The healthy-phase apt fetch hits deb.debian.org; a transient failure
# must not fail the contract test (the same policy as the integration
# harness).
retry() {
	_r_tries=$1
	_r_sleep=$2
	shift 2
	_r_i=0
	while [ "$_r_i" -lt "$_r_tries" ]; do
		_r_i=$((_r_i + 1))
		if "$@"; then
			return 0
		fi
		[ "$_r_i" -lt "$_r_tries" ] && sleep "$_r_sleep"
	done
	return 1
}

docker image inspect tt-ucode-gate >/dev/null 2>&1 || tt_skip "tt-ucode-gate image missing (build tests/backend/Dockerfile first)"
docker build -q -t tt-backend-rootfs -f "$BASE/lab.Dockerfile" "$BASE" >/dev/null || tt_skip "lab image build failed"

cp "$BACKEND" "$MOD"

# Method and args for a golden file name (the arg-derived suffix after the
# method name is not part of the contract). Prints "method<TAB>args" so the
# JSON survives word splitting.
golden_call() {
	case "$1" in
		status) printf 'status\t{}' ;;
		versions) printf 'versions\t{}' ;;
		serviceactionrestart) printf 'service\t{"action":"restart"}' ;;
		serviceactionstart) printf 'service\t{"action":"start"}' ;;
		serviceactionbogus) printf 'service\t{"action":"bogus"}' ;;
		ping) printf 'ping\t{}' ;;
		pingtarget8888) printf 'ping\t{"target":"8.8.8.8"}' ;;
		probe) printf 'probe\t{}' ;;
		check_domaindomain) printf 'check_domain\t{"domain":""}' ;;
		check_domaindomainbankexam*) printf 'check_domain\t{"domain":"bank.example"}' ;;
		check_domaindomaintelegram*) printf 'check_domain\t{"domain":"telegram.org"}' ;;
		check_domaindomainlegacyex*) printf 'check_domain\t{"domain":"legacy.example"}' ;;
		log) printf 'log\t{}' ;;
		loglines5) printf 'log\t{"lines":5}' ;;
		diagnose) printf 'diagnose\t{}' ;;
		import_configtextsampleconf*) printf 'import_config\t{"text":"sample config text"}' ;;
		import_configtextttdeeplink*) printf 'import_config\t{"text":"tt://deeplink-value"}' ;;
		*) printf '' ;;
	esac
}

# Run one call against the backend module in the lab container. The JSON
# args survive in single quotes; the scenario strings contain only double
# quotes, never single ones.
run_call() {
	docker exec "$1" sh -c "/opt/ucode/build/ucode -L '/ws/tests/backend/mod/*.uc' -L '/opt/ucode/build/*.so' /ws/tests/backend/driver.uc '$2' '$3' 2>/dev/null"
}

# Compare every golden in a directory against the live backend in a lab.
# TT_REGEN=1 rewrites the goldens from the live output instead of
# comparing (the counterpart to "do not rebuild goldens casually": the
# rewritten set must be diffed and only the intended files may change —
# anything else means the backend moved behavior elsewhere).
check_goldens() {
	lab="$1"
	dir="$2"
	[ -d "$dir" ] || return 0
	for g in "$dir"/*.json; do
		[ -f "$g" ] || continue
		name=$(basename "$g" .json)
		call=$(golden_call "$name")
		[ -n "$call" ] || continue
		method=${call%%	*}
		args=${call#*	}
		if [ "${TT_REGEN:-0}" = 1 ]; then
			run_call "$lab" "$method" "$args" > "$g"
			continue
		fi
		assert_eq "$(cat "$g")" "$(run_call "$lab" "$method" "$args")" "golden $name"
	done
}

LAB_BAKED="tt-contract-baked"
LAB_HEALTHY="tt-contract-healthy"
LAB_STOPPED="tt-contract-stopped"
LAB_PROXY="tt-contract-proxy"
LAB_PROXY_HEALTHY="tt-contract-proxy-healthy"
LAB_BYPASS="tt-contract-bypass"
LAB_WILDCARD="tt-contract-wildcard"
LAB_WILDCARD_ECHO="tt-contract-wildcard-echo"
docker rm -f "$LAB_BAKED" "$LAB_HEALTHY" "$LAB_STOPPED" "$LAB_PROXY" "$LAB_PROXY_HEALTHY" "$LAB_BYPASS" "$LAB_WILDCARD" "$LAB_WILDCARD_ECHO" >/dev/null 2>&1
trap 'docker rm -f "$LAB_BAKED" "$LAB_HEALTHY" "$LAB_STOPPED" "$LAB_PROXY" "$LAB_PROXY_HEALTHY" "$LAB_BYPASS" "$LAB_WILDCARD" "$LAB_WILDCARD_ECHO" >/dev/null 2>&1' EXIT

# --- Phase A: the baked rootfs state (no tun device) ---------------------
docker run --rm -d --name "$LAB_BAKED" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the lab container"
check_goldens "$LAB_BAKED" "$BASE/goldens"

# --- Phase A2: the baked state with router traffic NOT tunneled -----------
# The baked records enable include_router_traffic, so the identical-address
# stub state pins the OK branch (both probes are tunneled by config). With
# the option flipped off the plain probe must be direct — the same
# identical-address stub then pins the failure branch and its hint (the
# stale-output-chain wording). The records file is swapped in place: the
# backend re-reads it on every call.
docker exec "$LAB_BAKED" sh -c "sed -i 's/^network.include_router_traffic\t1$/network.include_router_traffic\t0/' /var/etc/trusttunnel/settings.tsv" >/dev/null 2>&1
check_goldens "$LAB_BAKED" "$BASE/goldens/router-off"

# --- Phase B: a real tun device + healthy stubs --------------------------
docker run --rm --privileged -d --name "$LAB_HEALTHY" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the healthy lab container"
# The tun-device creation needs iproute2, which the lab image does not
# carry; the apt fetch hits deb.debian.org, so it is retried.
retry 3 5 docker exec "$LAB_HEALTHY" sh -c 'apt-get install -y -qq python3 iproute2 >/dev/null 2>&1' >/dev/null 2>&1
docker exec "$LAB_HEALTHY" sh -c 'cat > /tmp/mktun.py <<"PYEOF"
import fcntl, struct, os, time
TUNSETIFF = 0x400454ca
IFF_TUN = 0x0001
IFF_NO_PI = 0x1000
fd = os.open("/dev/net/tun", os.O_RDWR)
ifr = struct.pack("16sH", b"ttlab0", IFF_TUN | IFF_NO_PI)
fcntl.ioctl(fd, TUNSETIFF, ifr)
os.system("ip link set ttlab0 up; ip link set ttlab0 mtu 1500")
time.sleep(400)
PYEOF
nohup python3 /tmp/mktun.py >/dev/null 2>&1 &' >/dev/null 2>&1
sleep 2
docker exec "$LAB_HEALTHY" sh -c '
cat > /usr/libexec/trusttunnel/routing <<"EOF"
#!/bin/sh
case "$1" in
	status)
		echo "device up"
		echo "client device ttlab0"
		echo "rule present"
		echo "table present"
		echo "nft present"
		;;
	up|attach|reattach|detach|down) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x /usr/libexec/trusttunnel/routing
cat > /usr/bin/curl <<"EOF"
#!/bin/sh
case "$*" in
	*--interface*) echo "198.51.100.7" ;;
	*) echo "203.0.113.77" ;;
esac
exit 0
EOF
cat > /usr/bin/ip <<"EOF"
#!/bin/sh
if [ "$1" = "route" ] && [ "$2" = "show" ] && [ "$3" = "table" ]; then
	echo "default dev ttlab0 table 880 metric 1"
	exit 0
fi
exit 0
EOF
cat > /usr/bin/logread <<"EOF"
#!/bin/sh
echo "Fri Jan  1 00:00:00 2026 daemon.info trusttunnel[1]: client started"
exit 0
EOF
chmod +x /usr/bin/curl /usr/bin/ip /usr/bin/logread' >/dev/null 2>&1
check_goldens "$LAB_HEALTHY" "$BASE/goldens/healthy"

# --- Phase C: the service stopped (routing state absent, expected) -------
# The kernel checks gate their fail/skip verdict on `running`: with the
# service stopped the absent routing state is expected and must report
# skip, not fail. Pin that output so a regression (e.g. back to
# always-fail) fails the contract test.
docker run --rm -d --name "$LAB_STOPPED" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the stopped lab container"
docker exec "$LAB_STOPPED" sh -c '
cat > /etc/init.d/trusttunnel <<"EOF"
#!/bin/sh
case "$1" in
	running) exit 1 ;;
	*) exit 1 ;;
esac
EOF
chmod +x /etc/init.d/trusttunnel
cat > /usr/libexec/trusttunnel/routing <<"EOF"
#!/bin/sh
case "$1" in
	status)
		echo "device down"
		echo "rule absent"
		echo "table absent"
		echo "nft absent"
		;;
	*) exit 0 ;;
esac
EOF
chmod +x /usr/libexec/trusttunnel/routing' >/dev/null 2>&1
check_goldens "$LAB_STOPPED" "$BASE/goldens/stopped"

# --- Phase D: the proxy state (SOCKS listener, no kernel routing) ----------
# The same rootfs, but the records declare proxy mode and the routing stub
# reports an empty kernel state. The original curl stub answers identically
# on both legs, pinning the "identical addresses via both routes" failure
# branch of the proxy tunnel check; nothing is bound on the listener port,
# so the SOCKS listener check fails.
PROXY_RECORDS='main.enabled	1
main.mode	proxy
proxy.address	0.0.0.0:1080
proxy.username	lan
proxy.password	lan-pass
endpoint.name	Default
endpoint.hostname	vpn.example.com
endpoint.username	alice
endpoint.password	s3cret
endpoint.protocol	http2
endpoint.anti_dpi	1
endpoint.post_quantum	0
endpoint.skip_verification	1
endpoint.has_ipv6	0
endpoint.custom_sni	vpn.example.com
endpoint.client_random	0a0b0c/0f0f0f
endpoint.routing_profile	Default
endpoint.address	1.2.3.4:443
endpoint.address	[2001:db8::1]:443
endpoint.dns_upstream	tls://1.1.1.1
routing_profile.name	Default
routing_profile.mode	vpn
routing_profile.vpn_rules	telegram.org
routing_profile.bypass_rules	bank.example
domains.direct	legacy.example'

docker run --rm -d --name "$LAB_PROXY" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the proxy lab container"
printf '%s\n' "$PROXY_RECORDS" | docker exec -i "$LAB_PROXY" sh -c 'cat > /var/etc/trusttunnel/settings.tsv' >/dev/null 2>&1
docker exec "$LAB_PROXY" sh -c '
cat > /usr/libexec/trusttunnel/routing <<"EOF"
#!/bin/sh
case "$1" in
	status)
		echo "device down"
		echo "rule absent"
		echo "table absent"
		echo "nft absent"
		# The usage meter (installed by the init script at start,
		# independently of the listener being bound) reports fixed
		# counters; the nonzero values pin the rx/tx mapping — a zero
		# could hide a parse bug.
		echo "meter up"
		echo "meter rx 4096"
		echo "meter tx 2048"
		;;
	up|attach|reattach|detach|down) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x /usr/libexec/trusttunnel/routing' >/dev/null 2>&1
check_goldens "$LAB_PROXY" "$BASE/goldens/proxy"

# --- Phase E: the healthy proxy state --------------------------------------
# Like Phase D, but with a live listener on the configured address and a
# curl stub that answers differently through the SOCKS leg — the "listener
# bound" and "tunnel address differs from the direct one" branches.
docker run --rm -d --name "$LAB_PROXY_HEALTHY" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the healthy proxy lab container"
docker exec "$LAB_PROXY_HEALTHY" sh -c 'apt-get install -y -qq python3 >/dev/null 2>&1' >/dev/null 2>&1
printf '%s\n' "$PROXY_RECORDS" | docker exec -i "$LAB_PROXY_HEALTHY" sh -c 'cat > /var/etc/trusttunnel/settings.tsv' >/dev/null 2>&1
docker exec "$LAB_PROXY_HEALTHY" sh -c '
cat > /usr/libexec/trusttunnel/routing <<"EOF"
#!/bin/sh
case "$1" in
	status)
		echo "device down"
		echo "rule absent"
		echo "table absent"
		echo "nft absent"
		# The usage meter of a running proxy-mode service: fixed nonzero
		# counters pin the rx/tx mapping (see phase D).
		echo "meter up"
		echo "meter rx 4096"
		echo "meter tx 2048"
		;;
	up|attach|reattach|detach|down) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x /usr/libexec/trusttunnel/routing
cat > /usr/bin/curl <<"EOF"
#!/bin/sh
case "$*" in
	*--socks5-hostname*) echo "198.51.100.7" ;;
	*) echo "203.0.113.77" ;;
esac
exit 0
EOF
chmod +x /usr/bin/curl
cat > /tmp/sockslistener.py <<"PYEOF"
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 1080))
s.listen(5)
time.sleep(400)
PYEOF
nohup python3 /tmp/sockslistener.py >/dev/null 2>&1 &' >/dev/null 2>&1
# The listener is the state under test: wait until the port actually
# appears in the listen tables (python3 startup after a fresh apt-get can
# take longer than a fixed sleep, and the golden comparison must not race
# it), with a generous cap so a genuinely missing listener still fails.
_i=0
while [ "$_i" -lt 20 ]; do
	_i=$((_i + 1))
	if docker exec "$LAB_PROXY_HEALTHY" \
			sh -c "grep -Eq '^ *[0-9]+: [0-9A-F:]*:0438 ' /proc/net/tcp /proc/net/tcp6" \
			>/dev/null 2>&1; then
		break
	fi
	sleep 1
done
check_goldens "$LAB_PROXY_HEALTHY" "$BASE/goldens/proxy-healthy"

# --- Phase F: bypass profile with an empty VPN-rules list -------------------
# Bypass mode tunnels only the VPN rules; an empty list means the client
# sends every connection out directly. The tunnel probe cannot compare
# egress addresses for a destination that is not tunneled, so the check
# must report the config as a remark instead of a misleading failure.
# Pins the "nothing is tunneled by config" warn branch.
BYPASS_RECORDS='main.enabled	1
main.log_level	debug
endpoint.hostname	vpn.example.com
endpoint.username	alice
endpoint.password	s3cret
endpoint.protocol	http2
endpoint.anti_dpi	1
endpoint.post_quantum	0
endpoint.skip_verification	1
endpoint.has_ipv6	0
endpoint.custom_sni	vpn.example.com
endpoint.client_random	0a0b0c/0f0f0f
endpoint.routing_profile	Default
endpoint.address	1.2.3.4:443
endpoint.address	[2001:db8::1]:443
endpoint.dns_upstream	tls://1.1.1.1
routing_profile.name	Default
routing_profile.mode	bypass
network.mtu	1400
network.table	880
network.fwmark	0x9527
network.blackhole_on_down	1
network.include_router_traffic	0
network.lan_devices	br-lan
domains.direct	legacy.example'

docker run --rm -d --name "$LAB_BYPASS" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the bypass lab container"
printf '%s\n' "$BYPASS_RECORDS" | docker exec -i "$LAB_BYPASS" sh -c 'cat > /var/etc/trusttunnel/settings.tsv' >/dev/null 2>&1
check_goldens "$LAB_BYPASS" "$BASE/goldens/bypass"

# --- Phase G: the bypass profile with one tunneled domain rule --------------
# The same state plus one VPN rule: the check probes that rule through the
# tunnel (the baked curl stub answers ok), pinning the "tunnel reaches"
# ok branch.
docker exec "$LAB_BYPASS" sh -c "printf 'routing_profile.vpn_rules\ttelegram.org\n' >> /var/etc/trusttunnel/settings.tsv" >/dev/null 2>&1
check_goldens "$LAB_BYPASS" "$BASE/goldens/bypass-rule"

# --- Phase H: the tunneled rule is unreachable through the tunnel -----------
# The via leg fails: the check reports the rule as unreachable through the
# tunnel — the "no response from ... through the tunnel" failure branch.
docker exec "$LAB_BYPASS" sh -c '
cat > /usr/bin/curl <<"EOF"
#!/bin/sh
case "$*" in
	*--interface*) exit 1 ;;
	*) echo "203.0.113.77" ;;
esac
EOF
chmod +x /usr/bin/curl' >/dev/null 2>&1
check_goldens "$LAB_BYPASS" "$BASE/goldens/bypass-rule-off"

# --- Phase I: a wildcard-only bypass profile ----------------------------------
# The vendor client tunnels only the SUBDOMAINS of a *.domain rule (the
# apex goes direct), so a wildcard rule has no canonical host to probe:
# the check must report the remark, not probe the apex and describe the
# wrong path. Pins the "the tunneled rules cannot be probed" warn branch
# for wildcards.
WILDCARD_RECORDS='main.enabled	1
main.log_level	debug
endpoint.hostname	vpn.example.com
endpoint.username	alice
endpoint.password	s3cret
endpoint.protocol	http2
endpoint.anti_dpi	1
endpoint.post_quantum	0
endpoint.skip_verification	1
endpoint.has_ipv6	0
endpoint.custom_sni	vpn.example.com
endpoint.client_random	0a0b0c/0f0f0f
endpoint.routing_profile	Default
endpoint.address	1.2.3.4:443
endpoint.address	[2001:db8::1]:443
endpoint.dns_upstream	tls://1.1.1.1
routing_profile.name	Default
routing_profile.mode	bypass
routing_profile.vpn_rules	*.telegram.org
network.mtu	1400
network.table	880
network.fwmark	0x9527
network.blackhole_on_down	1
network.include_router_traffic	0
network.lan_devices	br-lan
domains.direct	legacy.example'

docker run --rm -d --name "$LAB_WILDCARD" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the wildcard lab container"
printf '%s\n' "$WILDCARD_RECORDS" | docker exec -i "$LAB_WILDCARD" sh -c 'cat > /var/etc/trusttunnel/settings.tsv' >/dev/null 2>&1
check_goldens "$LAB_WILDCARD" "$BASE/goldens/bypass-wildcard"

# --- Phase J: a wildcard bypass rule in VPN mode ------------------------------
# bypass_rules = ['*.ipify.org'] must make the echo selection skip
# api.ipify.org (it is a subdomain of ipify.org, so the client sends it
# out directly) and pick the next echo host. The curl stub answers only
# for ifconfig.me — with a regression in the wildcard matching the check
# would probe api.ipify.org, get the fallback on both legs, and the
# golden would flip to the identical-addresses failure.
VPN_WILDCARD_RECORDS='main.enabled	1
main.log_level	debug
endpoint.hostname	vpn.example.com
endpoint.username	alice
endpoint.password	s3cret
endpoint.protocol	http2
endpoint.anti_dpi	1
endpoint.post_quantum	0
endpoint.skip_verification	1
endpoint.has_ipv6	0
endpoint.custom_sni	vpn.example.com
endpoint.client_random	0a0b0c/0f0f0f
endpoint.routing_profile	Default
endpoint.address	1.2.3.4:443
endpoint.address	[2001:db8::1]:443
endpoint.dns_upstream	tls://1.1.1.1
routing_profile.name	Default
routing_profile.mode	vpn
routing_profile.vpn_rules	telegram.org
routing_profile.bypass_rules	*.ipify.org
network.mtu	1400
network.table	880
network.fwmark	0x9527
network.blackhole_on_down	1
network.include_router_traffic	0
network.lan_devices	br-lan
domains.direct	legacy.example'

docker run --rm -d --name "$LAB_WILDCARD_ECHO" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the wildcard-echo lab container"
printf '%s\n' "$VPN_WILDCARD_RECORDS" | docker exec -i "$LAB_WILDCARD_ECHO" sh -c 'cat > /var/etc/trusttunnel/settings.tsv' >/dev/null 2>&1
docker exec "$LAB_WILDCARD_ECHO" sh -c '
cat > /usr/bin/curl <<"EOF"
#!/bin/sh
case "$*" in
	*--interface*ifconfig.me*) echo "198.51.100.7" ;;
	*ifconfig.me*) echo "203.0.113.77" ;;
	*) echo "203.0.113.77" ;;
esac
EOF
chmod +x /usr/bin/curl' >/dev/null 2>&1
check_goldens "$LAB_WILDCARD_ECHO" "$BASE/goldens/vpn-wildcard-bypass"

tt_test_summary
