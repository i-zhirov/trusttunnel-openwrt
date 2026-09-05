# SPDX-License-Identifier: Apache-2.0
#
# luci-app-trusttunnel: LuCI support for the TrustTunnel full-tunnel client.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trusttunnel

# Version from the release tag at build time: a build on tag vX.Y.Z ships
# X.Y.Z, which both package managers see as strictly higher than the
# previous release (apk names read X.Y.Z-r1, the 22.03 luci.mk ignores
# PKG_RELEASE for ipk versions). The status page's update check compares
# the release tag against the installed version, so a build that carries
# its tag's version reports "up to date"; a stale static version made two
# releases ship the same number and no upgrade ever delivered the new
# files. `git describe` reports the nearest reachable tag, so commits
# below a tag build with that tag's version; the fallback below applies
# only when no tag is reachable (local builds, manual re-deploys, a feed
# without .git). Keep the fallback equal to the last released version;
# release.yml fails a tag build whose artifact does not carry the tag.
PKG_VERSION:=$(strip $(shell v="$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"; [ -n "$$v" ] && printf '%s' "$$v" || printf '%s' 1.0.19))
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=TrustTunnelOpenWrt contributors

LUCI_TITLE:=LuCI support for TrustTunnel (full tunnel)
LUCI_DESCRIPTION:=Runs the TrustTunnel client on OpenWrt and routes LAN traffic through the tunnel with a killswitch and a LuCI interface.
# Every dependency below is used by THIS package's own files — nothing is
# carried for the client's sake. +trusttunnel-client is a hard dependency
# (this package configures and runs the client binaries in
# /opt/trusttunnel_client; both package managers pull the client from the
# same repository, which is what lets it update with `apk upgrade` /
# `opkg upgrade`). kmod-tun and ca-bundle live on trusttunnel-client's own
# DEPENDS (the binaries create the tun device and do TLS against a CA
# bundle) and arrive here transitively — the app must NOT repeat them.
# ip-full (`ip rule`/`ip route`), nftables (`nft` is called directly by the
# routing helper and the diagnostics — fw4 pulling it on stock images is
# not enough), curl (update check, diagnostics) and ucode-mod-math are
# invoked by this package's own files.
LUCI_DEPENDS:=+trusttunnel-client +luci-base +ip-full +nftables +curl +ucode-mod-math
# Without this override luci.mk would substitute the LuCI project's own
# address, and package metadata would point support at the wrong place.
LUCI_URL:=https://github.com/i-zhirov/trusttunnel-openwrt
LUCI_PKGARCH:=all

# The conffiles declaration must precede `include luci.mk`: luci.mk's last
# line expands BuildPackage, and the pack stage freezes the conffiles list
# with an immediate assignment at that moment. A declaration after the
# include is parsed too late, the captured list stays empty, and a package
# update would then overwrite /etc/config/trusttunnel with defaults —
# destroying the endpoint settings, the certificate and the service state.
define Package/luci-app-trusttunnel/conffiles
/etc/config/trusttunnel
endef

include $(TOPDIR)/feeds/luci/luci.mk

# Executable bits set explicitly rather than taken from the repository:
# luci.mk copies root/ with `cp -pR`, so modes come from the source files,
# and the git index is not a reliable carrier (bits are lost in zip
# downloads, on permission-less file systems, and on Windows). Without
# this block the built package would ship scripts that procd cannot start
# — with no log line at all. records.sh is sourced with `.`, not executed,
# so it stays 0644.
define Build/Compile
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/trusttunnel
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/40-luci-trusttunnel
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/hotplug.d/net/40-trusttunnel
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/gen-config
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/routing
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/uci-export
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/records.sh
endef

# call BuildPackage - OpenWrt buildroot signature
