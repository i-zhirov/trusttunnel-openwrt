#!/bin/sh
# Guards the EXPLICIT dependency declarations: every system package the
# installed files invoke (nft, ip, curl, the tun kernel module, ...) must be
# named in the Makefile's DEPENDS — not just mentioned in a README or an
# installer. A dependency left implicit (nftables stays unlisted because
# fw4 pulls it on stock images) breaks silently on a device without it; a
# regression in the other direction (a dependency dropped while the scripts
# still call the binary) is just as silent.
. "$(dirname "$0")/lib.sh"

APP=packages/luci-app-trusttunnel/Makefile
CLIENT=packages/trusttunnel-client/Makefile
DIAG=packages/luci-app-trusttunnel-diagnostics/Makefile

# The dependency declarations, extracted without the Makefile's comment
# noise. LUCI_DEPENDS is a single line; the client's DEPENDS line is
# indented with a tab.
app_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$APP")"
client_deps="$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$CLIENT")"
diag_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$DIAG")"
[ -n "$app_deps" ] || { echo "  FAIL: cannot extract LUCI_DEPENDS from $APP"; exit 1; }
[ -n "$client_deps" ] || { echo "  FAIL: cannot extract DEPENDS from $CLIENT"; exit 1; }
[ -n "$diag_deps" ] || { echo "  FAIL: cannot extract LUCI_DEPENDS from $DIAG"; exit 1; }

# Everything luci-app-trusttunnel's own files invoke or configure.
for dep in trusttunnel-client luci-base ip-full nftables curl \
		ucode-mod-math; do
	assert_contains "$app_deps" "+$dep" "luci-app-trusttunnel declares $dep"
done

# The client binaries' own runtime requirements: they create their own tun
# device (/dev/net/tun → kmod-tun) and do TLS against a CA bundle
# (ca-bundle; BoringSSL takes its trust store from SSL_CERT_FILE, so the
# FILE must exist on the router — the app's init script only locates and
# exports it). Both must NOT be repeated by the LuCI app — it gets them
# transitively via +trusttunnel-client, and duplicating them would blur
# which package's files actually need them.
for dep in kmod-tun ca-bundle; do
	assert_contains "$client_deps" "+$dep" "trusttunnel-client declares $dep"
	case "$app_deps" in
		*"+$dep"*) _tt_fail "luci-app-trusttunnel does not repeat $dep (it comes transitively via trusttunnel-client)" ;;
		*) _tt_pass "luci-app-trusttunnel does not repeat $dep" ;;
	esac
done

# The declarations must correspond to real usage: a declared dependency
# without a caller would be rot in the other direction, and the scripts
# below are where the system packages above are actually invoked.
R=packages/luci-app-trusttunnel/root/usr/libexec/trusttunnel
U=packages/luci-app-trusttunnel/root/usr/share/rpcd/ucode/luci.trusttunnel

assert_contains "$(cat "$R/routing")" 'TT_NFT="${TT_NFT:-nft}"' "routing invokes the nft binary"
assert_contains "$(cat "$R/routing")" 'TT_IP="${TT_IP:-ip}"' "routing invokes the ip binary"
assert_contains "$(cat "$U")" 'curl -fsS' "the ucode backend invokes curl"
assert_contains "$(cat "$U")" 'nft list ruleset' "the ucode backend invokes nft"
assert_contains "$(cat "$U")" 'ip route show table' "the ucode backend invokes ip"
assert_contains "$(cat "$U")" "from 'math'" "the ucode backend uses the math module"

# The diagnostics package is an optional add-on: it depends on the core
# (its views and menu entries need the app's parent menu and ACL), while
# the core must NOT depend back on it — a user who installs only the app
# gets exactly the core pages. Its own dependencies are luci-base only;
# the system packages (ip-full, nftables, curl) are the core's files'
# requirements and must not be repeated here.
assert_contains "$diag_deps" "+luci-app-trusttunnel" "luci-app-trusttunnel-diagnostics depends on the core package"
assert_contains "$diag_deps" "+luci-base" "luci-app-trusttunnel-diagnostics declares luci-base"
case "$app_deps" in
	*"+luci-app-trusttunnel-diagnostics"*) _tt_fail "luci-app-trusttunnel does not depend on the optional diagnostics package" ;;
	*) _tt_pass "luci-app-trusttunnel does not depend on the optional diagnostics package" ;;
esac
for dep in ip-full nftables curl; do
	case "$diag_deps" in
		*"+$dep"*) _tt_fail "luci-app-trusttunnel-diagnostics does not repeat $dep (it is the core's, not the views')" ;;
		*) _tt_pass "luci-app-trusttunnel-diagnostics does not repeat $dep" ;;
	esac
done

# install.sh pre-installs the same system packages before the LuCI app: the
# list there must not drift from the declared dependencies either.
apk_deps="$(sed -n 's/^	apk add //p' install.sh)"
opkg_deps="$(sed -n 's/^	opkg install //p' install.sh)"
for dep in kmod-tun ip-full nftables curl ca-bundle; do
	assert_contains "$apk_deps" "$dep" "install.sh apk branch installs $dep"
	assert_contains "$opkg_deps" "$dep" "install.sh opkg branch installs $dep"
done

tt_test_summary
