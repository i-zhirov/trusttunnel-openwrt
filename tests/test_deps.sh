#!/bin/sh
# Guards the EXPLICIT dependency declarations: every system package the
# installed files invoke (nft, ip, curl, the tun kernel module, ...) must
# be named in a package's DEPENDS — not just mentioned in a README or an
# installer. A dependency left implicit (nftables stays unlisted because
# fw4 pulls it on stock images) breaks silently on a device without it; a
# regression in the other direction (a dependency dropped while the
# scripts still call the binary) is just as silent.
#
# Three packages, three dependency layers:
#   trusttunnel (runtime)      — +trusttunnel-client +ip-full +nftables
#   luci-app-trusttunnel (UI)  — +trusttunnel +luci-base +curl +ucode-mod-math
#   luci-app-trusttunnel-diagnostics — +luci-app-trusttunnel +luci-base
# The runtime's system packages (ip-full, nftables) and the client's
# (kmod-tun, ca-bundle) reach the UI transitively — the UI must NOT repeat
# them, exactly as the app used to inherit kmod-tun/ca-bundle from the
# client before the runtime existed.
. "$(dirname "$0")/lib.sh"

APP=packages/luci-app-trusttunnel/Makefile
CORE=packages/trusttunnel/Makefile
CLIENT=packages/trusttunnel-client/Makefile
DIAG=packages/luci-app-trusttunnel-diagnostics/Makefile

# The dependency declarations, extracted without the Makefile's comment
# noise. LUCI_DEPENDS is a single line; the plain packages' DEPENDS lines
# are indented with a tab.
app_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$APP")"
core_deps="$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$CORE")"
client_deps="$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$CLIENT")"
diag_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$DIAG")"
[ -n "$app_deps" ] || { echo "  FAIL: cannot extract LUCI_DEPENDS from $APP"; exit 1; }
[ -n "$core_deps" ] || { echo "  FAIL: cannot extract DEPENDS from $CORE"; exit 1; }
[ -n "$client_deps" ] || { echo "  FAIL: cannot extract DEPENDS from $CLIENT"; exit 1; }
[ -n "$diag_deps" ] || { echo "  FAIL: cannot extract LUCI_DEPENDS from $DIAG"; exit 1; }

# The runtime package's own files: the routing helper (ip rule/ip route,
# nft) and the service (ip route show default) — and the client binaries,
# which it configures and runs.
for dep in trusttunnel-client ip-full nftables; do
	assert_contains "$core_deps" "+$dep" "trusttunnel declares $dep"
done

# The client binaries' own runtime requirements: they create their own tun
# device (/dev/net/tun → kmod-tun) and do TLS against a CA bundle
# (ca-bundle; BoringSSL takes its trust store from SSL_CERT_FILE, so the
# FILE must exist on the router — the runtime's init script only locates
# and exports it). Both must NOT be repeated by the runtime — it gets them
# transitively via +trusttunnel-client, and duplicating them would blur
# which package's files actually need them.
for dep in kmod-tun ca-bundle; do
	assert_contains "$client_deps" "+$dep" "trusttunnel-client declares $dep"
	case "$core_deps" in
		*"+$dep"*) _tt_fail "trusttunnel does not repeat $dep (it comes transitively via trusttunnel-client)" ;;
		*) _tt_pass "trusttunnel does not repeat $dep" ;;
	esac
done

# The UI package's own files: the backend (curl for the address probes,
# ucode-mod-math for rand()/srand()) and luci-base for the views. The
# runtime is a hard dependency (the backend reads the records, calls the
# routing helper and the service); ip-full, nftables, kmod-tun and
# ca-bundle arrive through it and the client — the UI must NOT repeat
# them.
for dep in trusttunnel luci-base curl ucode-mod-math; do
	assert_contains "$app_deps" "+$dep" "luci-app-trusttunnel declares $dep"
done
for dep in trusttunnel-client ip-full nftables kmod-tun ca-bundle; do
	case "$app_deps" in
		*"+$dep"*) _tt_fail "luci-app-trusttunnel does not repeat $dep (it comes transitively via the runtime and the client)" ;;
		*) _tt_pass "luci-app-trusttunnel does not repeat $dep" ;;
	esac
done

# The diagnostics package is an optional add-on: it depends on the core
# (its views and menu entries need the app's parent menu and ACL), while
# the app must NOT depend back on it — a user who installs only the app
# gets exactly the core pages. Its own dependencies are luci-base only;
# the system packages (ip-full, nftables, curl) are the runtime's and the
# backend's requirements and must not be repeated here.
assert_contains "$diag_deps" "+luci-app-trusttunnel" "luci-app-trusttunnel-diagnostics depends on the core package"
assert_contains "$diag_deps" "+luci-base" "luci-app-trusttunnel-diagnostics declares luci-base"
case "$app_deps" in
	*"+luci-app-trusttunnel-diagnostics"*) _tt_fail "luci-app-trusttunnel does not depend on the optional diagnostics package" ;;
	*) _tt_pass "luci-app-trusttunnel does not depend on the optional diagnostics package" ;;
esac
for dep in ip-full nftables curl; do
	case "$diag_deps" in
		*"+$dep"*) _tt_fail "luci-app-trusttunnel-diagnostics does not repeat $dep (it is the runtime's or the backend's)" ;;
		*) _tt_pass "luci-app-trusttunnel-diagnostics does not repeat $dep" ;;
	esac
done

# The declarations must correspond to real usage: a declared dependency
# without a caller would be rot in the other direction, and the files
# below are where the system packages above are actually invoked.
R=packages/trusttunnel/root/usr/libexec/trusttunnel
U=packages/luci-app-trusttunnel/root/usr/share/rpcd/ucode/luci.trusttunnel

assert_contains "$(cat "$R/routing")" 'TT_NFT="${TT_NFT:-nft}"' "routing invokes the nft binary"
assert_contains "$(cat "$R/routing")" 'TT_IP="${TT_IP:-ip}"' "routing invokes the ip binary"
assert_contains "$(cat "$U")" 'curl -fsS' "the ucode backend invokes curl"
assert_contains "$(cat "$U")" 'nft list ruleset' "the ucode backend invokes nft"
assert_contains "$(cat "$U")" 'ip route show table' "the ucode backend invokes ip"
assert_contains "$(cat "$U")" "from 'math'" "the ucode backend uses the math module"

# install.sh pre-installs the same system packages before the LuCI app: the
# list there must not drift from the declared dependencies either.
apk_deps="$(sed -n 's/^	apk add //p' install.sh)"
opkg_deps="$(sed -n 's/^	opkg install //p' install.sh)"
for dep in kmod-tun ip-full nftables curl ca-bundle; do
	assert_contains "$apk_deps" "$dep" "install.sh apk branch installs $dep"
	assert_contains "$opkg_deps" "$dep" "install.sh opkg branch installs $dep"
done

tt_test_summary
