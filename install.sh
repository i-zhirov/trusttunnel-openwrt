#!/bin/sh
# Install of luci-app-trusttunnel for OpenWrt 22.03+.
#   sh -c "$(wget -O - https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/install.sh)"
#
# Configures the trusttunnel package repository (apk on 25.12+, opkg on
# 22.03-24.10), installs the LuCI application with its dependencies, then
# refreshes rpcd and seeds the default routing profile. A running service is
# stopped for the install and started
# back afterwards; a fresh or stopped service stays disabled until the user
# enables it. The repository entry is left configured on purpose so future
# updates arrive with the regular package-manager upgrade.
set -e

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Environment checks -------------------------------------------------------
# The installer works only on OpenWrt: the release file also tells us the
# version floor for the package manager.
[ -f /etc/openwrt_release ] || die "this script is for OpenWrt only"
# The release file exists only on OpenWrt — absent on the linter's machine.
# shellcheck disable=SC1091
. /etc/openwrt_release

# The repository base URL; overridable for mirrors and testing. The keys
# and the index URLs are derived from it.
TT_REPO_URL="${TT_REPO_URL:-https://i-zhirov.github.io/trusttunnel-openwrt}"

# --- Package manager ----------------------------------------------------------
# apk (25.12+) takes precedence, opkg (22.03-24.10) is the fallback. The
# version floor is the OpenWrt release major (the first component of
# DISTRIB_RELEASE), not the package manager's own version.
PM=""
if command -v apk >/dev/null 2>&1; then
	PM=apk
elif command -v opkg >/dev/null 2>&1; then
	PM=opkg
fi
[ -n "$PM" ] || die "neither apk nor opkg found; unsupported OpenWrt variant"

_release="${DISTRIB_RELEASE:-}"
_major=${_release%%.*}
case "$_major" in
	''|*[!0-9]*)
		say "warning: could not read the OpenWrt release version (${_release:-unknown}); skipping the version floor check"
		;;
	*)
		if [ "$PM" = "apk" ]; then
			[ "$_major" -ge 25 ] || die "apk-based installs require OpenWrt 25.12 or newer (this device reports $DISTRIB_RELEASE)"
		else
			[ "$_major" -ge 22 ] || die "opkg-based installs require OpenWrt 22.03 or newer (this device reports $DISTRIB_RELEASE)"
		fi
		;;
esac

# --- CPU architecture ---------------------------------------------------------
# The packages are built only for these families; anything else dies here,
# before a single file is changed.
_arch=$(uname -m)
case "$_arch" in
	x86_64|x86-64|x64|amd64|aarch64|arm64|armv7l|armv8l|mips|mipsel)
		;;
	*)
		die "unsupported CPU architecture: $_arch (supported: x86_64, aarch64/arm64, armv7l/armv8l, mips, mipsel)"
		;;
esac

# --- Repository setup ---------------------------------------------------------
if [ "$PM" = "apk" ]; then
	say "== Configuring the apk repository"
	mkdir -p /etc/apk/keys /etc/apk/repositories.d
	# The signing key goes in first: apk refuses an index it cannot verify.
	wget -O /etc/apk/keys/trusttunnel.pub "$TT_REPO_URL/apk/key-build.pub"
	_arch_dir=$(apk --print-arch) || die "could not determine the architecture (apk --print-arch failed)"
	[ -n "$_arch_dir" ] || die "could not determine the architecture (apk --print-arch returned nothing)"
	printf '%s\n' "$TT_REPO_URL/apk/$_arch_dir/packages.adb" > /etc/apk/repositories.d/trusttunnel.list
else
	say "== Configuring the opkg repository"
	mkdir -p /etc/opkg/keys
	# Idempotent feed line: a reinstall must not duplicate it.
	if ! grep -q '^src/gz trusttunnel ' /etc/opkg/customfeeds.conf 2>/dev/null; then
		printf '%s\n' "src/gz trusttunnel $TT_REPO_URL/opkg" >> /etc/opkg/customfeeds.conf
	fi
	wget -O /etc/opkg/keys/trusttunnel.pub "$TT_REPO_URL/opkg/opkg-key.pub"
	# opkg-key matches keys named by their usign fingerprint; the stable
	# name is uninstall.sh's removal handle — both copies are kept.
	_fp=$(usign -F -p /etc/opkg/keys/trusttunnel.pub) || die "could not compute the usign fingerprint of the feed key"
	[ -n "$_fp" ] || die "the usign fingerprint of the feed key is empty"
	cp /etc/opkg/keys/trusttunnel.pub "/etc/opkg/keys/$_fp"
fi

# --- Packages -----------------------------------------------------------------
say "== Updating the package indexes and installing the dependencies"
if [ "$PM" = "apk" ]; then
	apk update
	apk add kmod-tun ip-full nftables curl ca-bundle
else
	opkg update
	opkg install kmod-tun ip-full nftables curl ca-bundle
fi

# --- Service state ------------------------------------------------------------
# Remembered between the dependency install and the main package install: a
# reinstall of a running service restarts it at the end; a stopped or fresh
# service stays disabled.
was_running=0
if [ -x /etc/init.d/trusttunnel ]; then
	if /etc/init.d/trusttunnel running >/dev/null 2>&1; then
		was_running=1
	fi
	say "== Stopping the service during the install"
	/etc/init.d/trusttunnel stop >/dev/null 2>&1 || true
fi

# --- Main packages ------------------------------------------------------------
say "== Installing the package"
if [ "$PM" = "apk" ]; then
	apk add luci-app-trusttunnel
	apk info -e trusttunnel-client >/dev/null 2>&1 || die "trusttunnel-client is not installed; the installation failed"
else
	opkg install luci-app-trusttunnel
	opkg list-installed 2>/dev/null | grep -q '^trusttunnel-client ' || die "trusttunnel-client is not installed; the installation failed"
fi

# --- Service refresh ----------------------------------------------------------
# rpcd keeps the backend's ucode in memory; the restart makes LuCI see the
# new menus and pages. The uci-defaults script seeds the default routing
# profile and migrates domains.direct NOW, so the profile exists before the
# first use — not only after the next boot.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

if [ -x /etc/uci-defaults/40-luci-trusttunnel ]; then
	say "== Seeding the default routing profile"
	/etc/uci-defaults/40-luci-trusttunnel >/dev/null 2>&1 || say "warning: the default routing profile was not created; run /etc/uci-defaults/40-luci-trusttunnel manually"
fi

if [ "$was_running" = "1" ]; then
	say "== Starting the service"
	/etc/init.d/trusttunnel start >/dev/null 2>&1 || true
fi

say ""
say "== Done"
say "The trusttunnel repository stays configured on this device, so the"
if [ "$PM" = "apk" ]; then
	say "packages are updated with: apk update && apk upgrade"
else
	say "packages are updated with: opkg update && opkg upgrade"
fi
