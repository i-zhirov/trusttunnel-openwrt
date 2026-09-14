#!/bin/sh
# Contract test for the rpcd backend: loads luci.trusttunnel the same way
# rpcd does (module value = the top-level return) and byte-compares its
# responses against the golden set — the behavioral contract.
#
# Two phases, two golden sets:
#   goldens/*.json           — the baked stub rootfs state (no tun device:
#                              /dev/net/tun shadowed, tun device check fails)
#   goldens/healthy/*.json   — after creating a real tun device in a
#                              privileged container and restoring the
#                              healthy stubs (device present paths)
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

docker image inspect tt-ucode-gate >/dev/null 2>&1 || tt_skip "tt-ucode-gate image missing (build tests/backend/Dockerfile first)"
docker build -q -t tt-backend-rootfs -f "$BASE/lab.Dockerfile" "$BASE" >/dev/null || tt_skip "lab image build failed"

cp "$BACKEND" "$MOD"

# Method and args for a golden file name (the arg-derived suffix after the
# method name is not part of the contract). Prints "method<TAB>args" so the
# JSON survives word splitting.
golden_call() {
	case "$1" in
		status) printf 'status\t{}' ;;
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
		assert_eq "$(cat "$g")" "$(run_call "$lab" "$method" "$args")" "golden $name"
	done
}

LAB_BAKED="tt-contract-baked"
LAB_HEALTHY="tt-contract-healthy"
docker rm -f "$LAB_BAKED" "$LAB_HEALTHY" >/dev/null 2>&1
trap 'docker rm -f "$LAB_BAKED" "$LAB_HEALTHY" >/dev/null 2>&1' EXIT

# --- Phase A: the baked rootfs state (no tun device) ---------------------
docker run --rm -d --name "$LAB_BAKED" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the lab container"
check_goldens "$LAB_BAKED" "$BASE/goldens"

# --- Phase B: a real tun device + healthy stubs --------------------------
docker run --rm --privileged -d --name "$LAB_HEALTHY" -v "$(pwd)":/ws tt-backend-rootfs sleep 300 >/dev/null || tt_skip "cannot start the healthy lab container"
docker exec "$LAB_HEALTHY" sh -c 'apt-get install -y -qq python3 iproute2 >/dev/null 2>&1' >/dev/null 2>&1
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

tt_test_summary
