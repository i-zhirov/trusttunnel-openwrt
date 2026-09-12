# TrustTunnel OpenWrt package repositories

This site hosts the package repositories that
[install.sh](https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/install.sh)
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
  `https://i-zhirov.github.io/trusttunnel-openwrt/releases/25.12.5/packages/<arch>/trusttunnel/packages.adb`
  and
  `https://i-zhirov.github.io/trusttunnel-openwrt/releases/22.03.7/packages/<arch>/trusttunnel`

The repositories are cumulative: they serve every released version of
the LuCI app — the `__TAG__` release on top of all earlier releases — so
pinning or downgrading to an older version stays possible. The client is
served at the version the current release pins (the package managers
install the highest version, so older client builds are not offered).

The GitHub
[releases](https://github.com/i-zhirov/trusttunnel-openwrt/releases)
carry the same package files for manual download.

## Installing

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/install.sh)"
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
updated by the package-manager commands above.
