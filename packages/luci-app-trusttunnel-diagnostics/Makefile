# SPDX-License-Identifier: Apache-2.0
# luci-app-trusttunnel-diagnostics: the TrustTunnel diagnostics views.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trusttunnel-diagnostics

# Same version mechanism as luci-app-trusttunnel: the release tag names
# the version, the fallback tracks the last released one. The package is
# released together with the app (the same tag carries both), so it can
# never be ahead of or behind the core.
PKG_VERSION:=$(strip $(shell v="$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"; [ -n "$$v" ] && printf '%s' "$$v" || printf '%s' 1.0.33))
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Ilia Zhirov <i.zhirov@adguard.com>

LUCI_TITLE:=TrustTunnel diagnostics (Diagnose and Tools views)
LUCI_DESCRIPTION:=Adds the Diagnose and Tools pages to the TrustTunnel LuCI interface: the chain walk, the domain verdict check, the endpoint ping and the tunnel-vs-direct address comparison.
# The views and the menu entries only need the core package (which
# brings luci-base and everything the app itself needs); the core must
# NOT depend back on this package — it is an optional add-on.
LUCI_DEPENDS:=+luci-app-trusttunnel +luci-base
LUCI_URL:=https://github.com/i-zhirov/trusttunnel-openwrt
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk's include above is what emits the package build. The marker
# below is load-bearing, not a signature: include/scan.mk discovers the
# feed's packages by grepping Makefiles for `call BuildPackage`, and the
# real call lives inside luci.mk — without the marker the feed scan
# silently drops this package from the index.
# call BuildPackage - OpenWrt buildroot signature
