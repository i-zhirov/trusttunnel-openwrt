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
# openwrt/sdk:<arch>-<ver> image ships it, byte-identical to the
# release tarball's — verified against both). When release.yml bumps the
# SDK version, these pins must be updated to match the new feeds.conf
# .default — they are the OTHER half of the SDK pin, exactly like
# VERSION_PATH.
#
# Usage:
#   sh tests/integration/restricted-feeds.sh 25.12.5        # luci set
#   sh tests/integration/restricted-feeds.sh 25.12.5 client # base only
#   sh tests/integration/restricted-feeds.sh --verify 25.12.5
#
# --verify compares the hardcoded pins against the SDK image's
# feeds.conf.default and fails on drift with the corrected triples, so
# the release and integration workflows can gate a build on the pins
# being current. A stale pin would silently build against different
# feed commits than the SDK pins (the release's install verifications
# would not catch it).
set -u

_mode=print
_ver=${1:-}
_set=${2:-luci}
if [ "$_ver" = "--verify" ]; then
	_mode=verify
	_ver=${2:-}
	_set=
fi
[ -n "$_ver" ] || { echo "restricted-feeds: missing SDK version" >&2; exit 1; }

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

# split_feed_line <line> — sets _m (method), _n (feed name), _r
# (revision: the part after the last ^ or ; of the url) for a
# space-separated feeds.conf line (the pipe-separated triples are
# converted with tr before calling).
split_feed_line() {
	_line=$1
	set -- $_line
	_m=$1
	_n=
	for _t in "$@"; do
		case $_t in
			base|packages|luci) _n=$_t; break ;;
		esac
	done
	[ -n "$_n" ] || return 1
	for _t in "$@"; do :; done
	_url=$_t
	_r=${_url##*[;^]}
	[ -n "$_r" ] || return 1
	return 0
}

verify_pins() {
	_ver=$1
	_img="openwrt/sdk:x86-64-$_ver"
	if ! docker image inspect "$_img" >/dev/null 2>&1; then
		docker pull -q "$_img" >/dev/null || {
			echo "restricted-feeds: cannot pull $_img" >&2
			return 1
		}
	fi
	# The image ships the release SDK, whose feeds.conf.default is
	# byte-identical to the release tarball's. The same grep filter as
	# build-sdk.sh keeps the feeds the packages need.
	_feeds=$(docker run --rm "$_img" \
		sh -c 'grep -E "(^| )(base|packages|luci)( |$)" /builder/feeds.conf.default' 2>/dev/null) || {
		echo "restricted-feeds: cannot read feeds.conf.default from $_img" >&2
		return 1
	}

	_fail=0
	for _triple in "$_base" "$_pkgs" "$_luci"; do
		if ! split_feed_line "$(printf '%s\n' "$_triple" | tr '|' ' ')"; then
			echo "restricted-feeds: cannot parse triple '$_triple'" >&2
			_fail=1
			continue
		fi
		_tm=$_m; _tn=$_n; _tr=$_r

		_imgline=$(printf '%s\n' "$_feeds" | grep -E "(^| )$_tn( |$)")
		if [ -z "$_imgline" ]; then
			echo "restricted-feeds: $_tn missing from $_img feeds.conf.default" >&2
			_fail=1
			continue
		fi
		if ! split_feed_line "$_imgline"; then
			echo "restricted-feeds: cannot parse the SDK line '$_imgline'" >&2
			_fail=1
			continue
		fi

		if [ "$_tm" != "$_m" ] || [ "$_tr" != "$_r" ]; then
			# Derive the corrected triple from the SDK line so the bump
			# is a copy-paste: github mirror, same method and revision
			# separator as the SDK.
			_repo=${_url##*/}
			_repo=${_repo%%[;^]*}
			_sep=^
			case $_url in *\;*) _sep=\; ;; esac
			echo "restricted-feeds: pin drift for $_tn ($_ver):" >&2
			echo "  restricted-feeds.sh:        $_tm $_tr" >&2
			echo "  SDK feeds.conf.default:     $_m $_r" >&2
			echo "  corrected triple:           $_m|$_tn|https://github.com/openwrt/$_repo$_sep$_r" >&2
			_fail=1
		fi
	done

	if [ "$_fail" -eq 0 ]; then
		echo "restricted-feeds: $_ver pins match the SDK (base packages luci)"
	fi
	return "$_fail"
}

if [ "$_mode" = verify ]; then
	verify_pins "$_ver"
	exit $?
fi

case "$_set" in
	luci) printf '%s %s %s\n' "$_base" "$_pkgs" "$_luci" ;;
	client) printf '%s\n' "$_base" ;;
	*) echo "restricted-feeds: unknown feed set $_set" >&2; exit 1 ;;
esac
