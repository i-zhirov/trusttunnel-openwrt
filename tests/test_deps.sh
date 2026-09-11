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

# The dependency declarations, extracted without the Makefile's comment
# noise. LUCI_DEPENDS is a single line; the client's DEPENDS line is
# indented with a tab.
app_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$APP")"
client_deps="$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$CLIENT")"
[ -n "$app_deps" ] || { echo "  FAIL: cannot extract LUCI_DEPENDS from $APP"; exit 1; }
[ -n "$client_deps" ] || { echo "  FAIL: cannot extract DEPENDS from $CLIENT"; exit 1; }

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

# install.sh pre-installs the same system packages before the LuCI app: the
# list there must not drift from the declared dependencies either.
apk_deps="$(sed -n 's/^	apk add //p' install.sh)"
opkg_deps="$(sed -n 's/^	opkg install //p' install.sh)"
for dep in kmod-tun ip-full nftables curl ca-bundle; do
	assert_contains "$apk_deps" "$dep" "install.sh apk branch installs $dep"
	assert_contains "$opkg_deps" "$dep" "install.sh opkg branch installs $dep"
done

tt_test_summary
