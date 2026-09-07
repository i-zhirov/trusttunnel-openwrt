#!/bin/sh
# Print the EXTRA_FEEDS value for the openwrt/gh-action-sdk action: the
# pipe-separated feeds.conf lines that REPLACE the SDK's default feeds
# (the action's entrypoint turns every | into a space, so each token is
# one whitespace-free `src-git[(-full)]|name|url` triple).
#
# Why restrict at all: the default feeds.conf.default lists six feeds,
# but the packages only need a subset. base carries the SDK's own
# package tree, packages carries curl, luci carries luci.mk; the
# routing/telephony/video clones are used by nothing in this project,
# and skipping them saves minutes on every SDK build. The luci set is
# what luci-app-trusttunnel needs; the client-only set is what
# trusttunnel-client needs (its kmod-tun/ca-bundle deps live in base).
#
# The pins come from the release SDK's feeds.conf.default verbatim (the
# openwrt/sdk:<arch>-<ver> image ships them). When release.yml bumps the
# SDK version, these pins must be updated to match the new tarball's
# feeds.conf.default — they are the OTHER half of the SDK pin, exactly
# like VERSION_PATH.
#
# Usage:
#   sh tests/integration/restricted-feeds.sh 25.12.5       # luci set
#   sh tests/integration/restricted-feeds.sh 25.12.5 client # base only
set -u

_ver=$1
_set=${2:-luci}

case "$_ver" in
	25.12.5)
		_base="src-git|base|https://github.com/openwrt/openwrt.git^f0a60eee2fe051741c643ea6118718aae1ef17fb"
		_pkgs="src-git|packages|https://github.com/openwrt/packages.git^5caa62e0bc9f7fb9b0c12a23267bceb7724214dd"
		_luci="src-git|luci|https://github.com/openwrt/luci.git^128a7812f4be233c5dd7f7466f534fd888785caf"
		;;
	22.03.7)
		# The 22.03 feeds use the era's own conventions: base tracks the
		# (frozen) openwrt-22.03 branch and packages/luci keep the
		# src-git-full method the release's feeds.conf.default uses.
		_base="src-git|base|https://github.com/openwrt/openwrt.git;openwrt-22.03"
		_pkgs="src-git-full|packages|https://github.com/openwrt/packages.git^3b79b05673a15e7f41f157d1320597244a344a95"
		_luci="src-git-full|luci|https://github.com/openwrt/luci.git^374888b1476df064281022c4d605b7ecf9e684e4"
		;;
	*) echo "restricted-feeds: unsupported SDK version $_ver" >&2; exit 1 ;;
esac

case "$_set" in
	luci) printf '%s %s %s\n' "$_base" "$_pkgs" "$_luci" ;;
	client) printf '%s\n' "$_base" ;;
	*) echo "restricted-feeds: unknown feed set $_set" >&2; exit 1 ;;
esac
