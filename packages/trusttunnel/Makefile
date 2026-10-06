# SPDX-License-Identifier: Apache-2.0
# trusttunnel: the TrustTunnel full-tunnel runtime.
#
# The service and its kernel wiring, without the LuCI interface: the UCI
# config (conffile), the procd service, the first-boot setup, the hotplug
# hook, the records/generation/routing helpers and the shared ucode
# records module. The LuCI UI (luci-app-trusttunnel) hard-depends on this
# package; a headless router can run the tunnel with it alone.
include $(TOPDIR)/rules.mk

PKG_NAME:=trusttunnel

# Version from the release tag at build time, exactly like the LuCI app:
# a build on tag vX.Y.Z ships X.Y.Z. The fallback below applies only when
# no tag is reachable; keep it equal to the last released version.
PKG_VERSION:=$(strip $(shell v="$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"; [ -n "$$v" ] && printf '%s' "$$v" || printf '%s' 1.0.35))
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Ilia Zhirov <i.zhirov@adguard.com>

# No source to build: the package ships the root/ tree as-is. The build
# directory is the staging area for the tree (mirroring luci.mk's
# approach) so Build/Compile can fix the exec bits before install.
PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/trusttunnel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=TrustTunnel full-tunnel runtime
  URL:=https://github.com/i-zhirov/trusttunnel-openwrt
  # The runtime is pure shell and config: one noarch package serves
  # every device architecture (the ipk name carries _all, like the LuCI
  # apps). PKGARCH is set INSIDE the package define — Package/Default
  # assigns it from ARCH_PACKAGES, and this block expands after it
  # (the same mechanism luci.mk uses for LUCI_PKGARCH).
  PKGARCH:=all
  # Every dependency below is used by THIS package's own files. The
  # client binaries (the tun device, the CA bundle) arrive transitively
  # via +trusttunnel-client — the runtime must NOT repeat kmod-tun or
  # ca-bundle. ip-full (ip rule/ip route in the routing helper and the
  # service) and nftables (the routing helper's ruleset) are called
  # directly. curl and ucode-mod-math are the LuCI backend's, not the
  # runtime's, and luci-base is the UI's.
  DEPENDS:=+trusttunnel-client +ip-full +nftables
endef

define Package/trusttunnel/conffiles
/etc/config/trusttunnel
endef

define Package/trusttunnel/description
  Runs the TrustTunnel client on OpenWrt: the procd service, the
  records generation, the fwmark/nft routing and the firewall zone,
  without the LuCI interface.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./root $(PKG_BUILD_DIR)/root
endef

# Executable bits set explicitly rather than taken from the repository:
# the git index is not a reliable carrier (bits are lost in zip
# downloads, on permission-less file systems, and on Windows). Without
# this block the built package would ship scripts that procd cannot
# start — with no log line at all. records.sh is sourced with `.`, not
# executed, so it stays 0644.
define Build/Compile
	chmod 0755 \
		$(PKG_BUILD_DIR)/root/etc/init.d/trusttunnel \
		$(PKG_BUILD_DIR)/root/etc/uci-defaults/40-luci-trusttunnel \
		$(PKG_BUILD_DIR)/root/etc/hotplug.d/net/40-trusttunnel \
		$(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/gen-config \
		$(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/routing \
		$(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/uci-export
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/libexec/trusttunnel/records.sh
endef

define Package/trusttunnel/install
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
endef

$(eval $(call BuildPackage,trusttunnel))
