# TrustTunnel OpenWrt package repositories

This site hosts the package repositories that
[install.sh](https://raw.githubusercontent.com/TrustTunnel/TrustTunnelOpenWrt/master/install.sh)
configures on the router:

- [releases/](releases/) — the signed package feeds in the official
  OpenWrt layout (`releases/<version>/packages/<arch>/<feed>/`): one
  release tree per package-manager era, named after the OpenWrt release
  the packages were built against — `25.12.5` for the apk feeds of
  OpenWrt 25.12+, `22.03.7` for the opkg feeds of 22.03–24.10. Each tree
  holds per-architecture `trusttunnel` feed directories with the signed
  index, the public signing key and every released version of the
  packages. Repository URLs for the router (the arch is the device's own
  package architecture):
  `https://trusttunnel.github.io/TrustTunnelOpenWrt/releases/25.12.5/packages/<arch>/trusttunnel/packages.adb`
  and
  `https://trusttunnel.github.io/TrustTunnelOpenWrt/releases/22.03.7/packages/<arch>/trusttunnel`

The repositories are cumulative: they serve every released version of
the LuCI app — with the latest release (`__TAG__`) on top of all earlier
ones — so pinning or downgrading to an older version stays possible. The
same holds for the client: every released `trusttunnel-client` build
stays in the feeds, and the package managers install the highest version
unless a router pins an older one. A client update can arrive on its
own, as a `client-v*` release: the repositories are re-published with
the new client while the LuCI app stays at its current version.

The GitHub
[releases](https://github.com/TrustTunnel/TrustTunnelOpenWrt/releases)
carry the same package files for manual download.

## Installing

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/TrustTunnel/TrustTunnelOpenWrt/master/install.sh)"
```

## Updating

Package updates are the standard package-manager commands:

```sh
# apk (25.12+):
apk update && apk upgrade
# opkg (22.03–24.10):
opkg update && opkg upgrade
```

Re-running the installer refreshes the signing keys; the packages — the LuCI
app and the client binary (the `trusttunnel-client` dependency) — are
updated by the package-manager commands above. A client-only release
updates the binary while the app stays at its installed version.

## Pinning the client

Every released client build stays installable, so a router can hold a
specific `trusttunnel-client` version:

```sh
# apk (25.12+), version as listed in the feed's index:
apk add trusttunnel-client=1.1.7-r1
# opkg (22.03–24.10) has no pkg=version syntax: download the versioned
# ipk from the feed, install it (--force-downgrade is needed only when
# a newer build is already installed) and hold it across upgrades:
wget -O /tmp/tt-client.ipk https://trusttunnel.github.io/TrustTunnelOpenWrt/releases/22.03.7/packages/<arch>/trusttunnel/trusttunnel-client_1.1.7-1_<arch>.ipk
opkg install --force-downgrade /tmp/tt-client.ipk
opkg flag hold trusttunnel-client
```

Replace `<arch>` with the device's package architecture (`x86_64`,
`aarch64_cortex-a53`, `mipsel_24kc`, ...) and the version with any
version the feed lists.
