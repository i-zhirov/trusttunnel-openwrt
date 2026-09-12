# SPDX-License-Identifier: Apache-2.0
include $(TOPDIR)/rules.mk

# Prebuilt TrustTunnel client binaries, packaged per architecture.
#
# The vendor (TrustTunnel/TrustTunnelClient) ships ONE tarball per CPU
# family — x86_64, aarch64, armv7, mips, mipsel — not per OpenWrt target,
# so the same tarball serves every subtarget whose CPU belongs to the
# family. The binaries are statically linked (verified with `file`: no
# glibc dependency), which is what makes them run on OpenWrt's musl at all.
#
# The package is built once per OpenWrt SUBTARGET arch (e.g.
# aarch64_cortex-a53), not once per family: apk and opkg match the package
# arch against the device's own arch byte-for-byte. apk refuses a package
# whose arch differs from the device's ("error: uninstallable, arch: ...",
# verified on openwrt/rootfs:x86_64-25.12.0), and opkg ignores such
# packages ("has no valid architecture, ignoring", verified on
# openwrt/rootfs:x86_64-22.03.7). The binary content is identical within a
# family — only the arch label in the package metadata differs.
PKG_NAME:=trusttunnel-client
# The version is the VENDOR release, tracked here explicitly. On a vendor
# release, bump it together with the per-family PKG_HASH values below (the
# release API publishes the digests of every asset).
#
# Pinned to 1.0.49 on purpose: 1.1.5 (2026-09-02) regressed the IPv6 DNS
# failure handling on IPv4-only routers — the client segfaults (SIGSEGV,
# invalid read at 0x24e000) ~90 ms after vpn_listen when its built-in
# IPv6 AdGuard upstreams (2a10:50c0::1:ff) are used for the endpoint
# resolution on a host without an IPv6 route. Reproduced on OpenWrt
# 25.12.5 (ramips/mt7621, mipsel_24kc): 5 of 6 supervised starts crashed
# with 1.1.5; 1.0.49 connects with the identical configuration
# (VPN_SS_CONNECTED, verified 2026-09-12). 1.0.49 was also the vendor's
# own install.sh default until the 1.1.5 release commit. Re-bump only
# after the upstream fix is verified on a real IPv4-only router.
PKG_VERSION:=1.0.49
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=TrustTunnelOpenWrt contributors

# VENDOR_ARCH: the vendor's tarball name for this subtarget's CPU family.
# The mapping matches $(ARCH_PACKAGES) — the package architecture
# (arm_cortex-a7_neon-vfpv4, mips_24kc, aarch64_cortex-a53, ...) — NOT
# $(ARCH), which carries only the CPU family (arm, mips, ...) and cannot
# tell ARMv7 subtargets from ARMv5/ARMv6 or mips32 from mips64. The
# patterns deliberately reject the subtargets the vendor does not ship:
# ARMv5/ARMv6 (arm_arm926ej-s, arm_xscale, arm_fa526, ...), mips64
# (mips64_octeonplus), riscv64, powerpc, i386, loongarch64. The mips*
# patterns deliberately require the underscore: mips64_* must not match.
# The outer $(strip) is not decoration: make turns each backslash-newline
# continuation into a space and keeps the next line's indentation, so
# every branch but the first would otherwise carry leading whitespace into
# PKG_SOURCE — verified: the download target broke for every non-x86_64
# arch ("target file ... has both : and :: entries").
VENDOR_ARCH := $(strip $(if $(filter x86_64,$(ARCH_PACKAGES)),x86_64, \
	$(if $(filter aarch64%,$(ARCH_PACKAGES)),aarch64, \
	$(if $(filter arm_cortex-%,$(ARCH_PACKAGES)),armv7, \
	$(if $(filter mips_%,$(ARCH_PACKAGES)),mips, \
	$(if $(filter mipsel_%,$(ARCH_PACKAGES)),mipsel,))))))
# The guard must not fire during the metadata dump: package-metadata.pl
# evaluates the Makefile WITHOUT the target configuration (ARCH_PACKAGES
# is empty there) and reports a Makefile that errors as broken, dropping
# the package from the index — the build would then produce nothing.
ifneq ($(ARCH_PACKAGES),)
ifeq ($(VENDOR_ARCH),)
$(error trusttunnel-client: no vendor build for OpenWrt arch '$(ARCH_PACKAGES)' (vendor ships only x86_64, aarch64, armv7, mips, mipsel))
endif
endif

PKG_SOURCE := trusttunnel_client-v$(PKG_VERSION)-linux-$(VENDOR_ARCH).tar.gz
PKG_SOURCE_URL := https://github.com/TrustTunnel/TrustTunnelClient/releases/download/v$(PKG_VERSION)
# SHA-256 of each family tarball, taken from the release's asset digests
# and verified locally against the downloaded files. Nested ifs (not
# if-chains with trailing continuations): a trailing space in PKG_HASH
# makes download.pl reject the checksum as unrecognized.
PKG_HASH := $(if $(filter x86_64,$(VENDOR_ARCH)),01f9f8c46cd673215c3a4052ef790166e874c59295e35daf6b13103e6366f4e5, \
	$(if $(filter aarch64,$(VENDOR_ARCH)),a0189fd182c478679fae89e3747e79c5edab56c8fcc34e1f80783a96f56b95d6, \
	$(if $(filter armv7,$(VENDOR_ARCH)),223b90beca6b1425b5e1e3b293a4434240cee18ed504bf3fff91e7b8ac8e0249, \
	$(if $(filter mips,$(VENDOR_ARCH)),367f2bd2532c1df7e0ec2804d77e20b58885619347bfbf0cfd789ba75fc8b7bc, \
	$(if $(filter mipsel,$(VENDOR_ARCH)),e02735f8db8bf2506094149894f1ca386fcc2cd6a5c0074fb94930f0ec8ce40a,)))))

# The archive's single top-level directory is named after the SOURCE
# (trusttunnel_client-v$(PKG_VERSION)-linux-$(VENDOR_ARCH)), not after the
# package, and the unpack goes to that directory. PKG_BUILD_DIR therefore
# points at the extraction directory — the standard idiom for tarballs with
# a foreign top-level name. The override must come BEFORE package.mk is
# included: its `PKG_BUILD_DIR ?=` default and STAMP_BUILT (an immediate
# assignment) both capture the value at include time.
PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_SOURCE:%.tar.gz=%)

# A plain (non-LuCI) package must include package.mk explicitly: LuCI
# packages get it transitively from luci.mk, this one does not.
include $(INCLUDE_DIR)/package.mk

define Build/Compile
	# Prebuilt binaries; nothing to compile.
endef

define Package/trusttunnel-client
	SECTION:=net
	CATEGORY:=Network
	TITLE:=TrustTunnel client binaries
	URL:=https://github.com/TrustTunnel/TrustTunnelClient
	# Statically linked: no library dependencies. The binaries still need
	# two things from the SYSTEM at runtime:
	#   - the tun KERNEL MODULE (kmod-tun) — they create their own tun
	#     device, which requires /dev/net/tun;
	#   - a CA bundle (ca-bundle) — the client does TLS against the
	#     endpoint, and BoringSSL takes its trust store from SSL_CERT_FILE
	#     only; the bundle FILE must exist on the router (the LuCI app's
	#     init script is what locates it and exports the variable).
	# Declared here, on the package whose binaries use them;
	# luci-app-trusttunnel gets both transitively and deliberately does
	# not repeat them.
	DEPENDS:=+kmod-tun +ca-bundle
endef

# The binaries install to /opt/trusttunnel_client, the path the LuCI backend
# and the init script already hardcode. Installing to the same path also
# takes over cleanly from a previous script-based install (install.sh used
# to fetch the same files with the vendor's own installer).
define Package/trusttunnel-client/install
	$(INSTALL_DIR) $(1)/opt/trusttunnel_client
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/trusttunnel_client $(1)/opt/trusttunnel_client/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/setup_wizard $(1)/opt/trusttunnel_client/
	# The .sig files and the LICENSE travel with the binaries: the vendor
	# signs every release (see the vendor's VERIFY_RELEASES.md) and the
	# public key is published on keys.openpgp.org, so a user can verify
	# what they run. PKG_HASH already pins the tarball; the signatures are
	# carried for transparency, not relied upon.
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/trusttunnel_client.sig $(1)/opt/trusttunnel_client/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/setup_wizard.sig $(1)/opt/trusttunnel_client/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(1)/opt/trusttunnel_client/
endef

$(eval $(call BuildPackage,trusttunnel-client))
