#!/bin/sh
# Build the trusttunnel packages from THIS tree with the OpenWrt SDK,
# producing the flat dist/ layout the integration harness consumes
# (tests/integration/run.sh prefers dist/ over the published release).
#
# The recipe mirrors the openwrt/gh-action-sdk entrypoint release.yml
# uses: the repository becomes the "ttowrt" feed (src-link), the default
# feeds are fetched (luci is needed by luci.mk), and the two packages are
# compiled. The SDK image already carries the toolchain, so only the feed
# sources are downloaded per run; the package download cache persists in
# $HOME/.tt-sdk-dl (Docker Desktop on macOS requires mounts under $HOME).
#
# Usage:
#   sh tests/integration/build-sdk.sh              # 25.12.5 (apk) and 22.03.7 (ipk)
#   sh tests/integration/build-sdk.sh 25.12.5      # one SDK version
#   TT_SDK_VERSION=22.03.7 sh tests/integration/build-sdk.sh
#
# Output: dist/ with the built packages of both variants (the harness
# selects the right ones by the package-manager globs, like the release
# assets). dist/ is gitignored.
set -u

TT_SDK_VERSION="${1:-${TT_SDK_VERSION:-25.12.5 22.03.7}}"
TT_SDK_NJOBS="${TT_SDK_NJOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)}"

command -v docker >/dev/null 2>&1 || {
	echo "error: docker is required to build with the SDK" >&2
	exit 1
}

mkdir -p dist "$HOME/.tt-sdk-dl"

for _ver in $TT_SDK_VERSION; do
	echo "== building with the $_ver SDK"
	_img="openwrt/sdk:x86-64-$_ver"
	if ! docker image inspect "$_img" >/dev/null 2>&1; then
		docker pull -q "$_img" || exit 1
	fi
	# The image runs as buildbot from /builder; root is used so the
	# mounted dist dir stays writable without host-side chown tricks.
	docker run --rm --user root \
		-v "$PWD:/feed" \
		-v "$PWD/dist:/artifacts" \
		-v "$HOME/.tt-sdk-dl:/builder/dl" \
		-e FEEDNAME=ttowrt \
		-e PACKAGES="luci-app-trusttunnel luci-i18n-trusttunnel-ru trusttunnel-client" \
		-e TT_SDK_NJOBS="$TT_SDK_NJOBS" \
		"$_img" sh -c '
			set -e
			cd /builder
			sed -e "s,https://git.openwrt.org/feed/,https://github.com/openwrt/," \
				-e "s,https://git.openwrt.org/openwrt/,https://github.com/openwrt/," \
				-e "s,https://git.openwrt.org/project/,https://github.com/openwrt/," \
				feeds.conf.default > feeds.conf
			echo "src-link ttowrt /feed/" >> feeds.conf
			echo "== feeds update"
			./scripts/feeds update -a
			echo "== defconfig"
			make defconfig >/dev/null 2>&1
			for PKG in luci-app-trusttunnel luci-i18n-trusttunnel-ru trusttunnel-client; do
				echo "== install $PKG"
				./scripts/feeds install -p ttowrt -f "$PKG"
				# The translation package has no source of its own, so its
				# download target does not exist; the packages WITH sources
				# fail the compile below anyway, so a missing download is
				# tolerated here.
				make "package/$PKG/download" >/dev/null 2>&1 || true
				echo "== compile $PKG"
				make -j"$TT_SDK_NJOBS" "package/$PKG/compile"
			done
			# Collect only the feed packages (the SDK bin tree also holds
			# base toolchain packages); the feed directory is
			# bin/packages/<arch>/ttowrt/ on both apk and ipk SDKs.
			find bin -path "*ttowrt*" \( -name "*.apk" -o -name "*.ipk" \) \
				| xargs -r -I{} cp {} /artifacts/
			echo "== collected:"
			ls /artifacts/
		' || exit 1
done
echo "== done: dist/"
ls dist/
