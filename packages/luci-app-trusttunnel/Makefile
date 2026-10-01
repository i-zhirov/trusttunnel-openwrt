# SPDX-License-Identifier: Apache-2.0
# luci-app-trusttunnel: LuCI support for the TrustTunnel full-tunnel client.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trusttunnel

# Version from the release tag at build time: a build on tag vX.Y.Z ships
# X.Y.Z, which both package managers see as strictly higher than the
# previous release (apk names read X.Y.Z-r1, the 22.03 luci.mk ignores
# PKG_RELEASE for ipk versions). `git describe` reports the nearest
# reachable tag, so a build on a tag carries exactly that version; the
# fallback below applies only when no tag is reachable (local builds,
# manual re-deploys, a feed without .git). Keep the fallback equal to
# the last released version; release.yml fails a tag build whose artifact
# does not carry the tag.
PKG_VERSION:=$(strip $(shell v="$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"; [ -n "$$v" ] && printf '%s' "$$v" || printf '%s' 1.0.35))
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Ilia Zhirov <i.zhirov@adguard.com>

LUCI_TITLE:=LuCI support for TrustTunnel (full tunnel)
LUCI_DESCRIPTION:=The TrustTunnel LuCI interface: status, settings, client log and versions pages over the trusttunnel runtime.
# Every dependency below is used by THIS package's own files — nothing is
# carried for another package's sake. +trusttunnel is the runtime (the
# service, the routing, the UCI config and the client binaries' owner,
# pulling +trusttunnel-client transitively), so the app must NOT repeat
# +trusttunnel-client, +ip-full, +nftables, kmod-tun or ca-bundle — they
# all arrive through the runtime, exactly as they did through the client
# before the split. curl (the diagnostics probes in the backend) and
# ucode-mod-math (the backend's rand()/srand()) are invoked by this
# package's own backend file.
LUCI_DEPENDS:=+trusttunnel +luci-base +curl +ucode-mod-math
# Without this override luci.mk would substitute the LuCI project's own
# address, and package metadata would point support at the wrong place.
LUCI_URL:=https://github.com/i-zhirov/trusttunnel-openwrt
LUCI_PKGARCH:=all

# The UCI config is the runtime package's conffile (/etc/config/trusttunnel
# is owned by trusttunnel now); the app ships only the views, the menu,
# the ACL and the backend, so there is no conffiles block here.

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk's include above is what emits the package build. The marker
# below is load-bearing, not a signature: include/scan.mk discovers the
# feed's packages by grepping Makefiles for `call BuildPackage`, and the
# real call lives inside luci.mk — without the marker the feed scan
# silently drops this package from the index.
# call BuildPackage - OpenWrt buildroot signature
