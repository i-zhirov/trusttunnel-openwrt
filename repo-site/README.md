# trusttunnel-openwrt — package repositories

This site hosts the package repositories that
[install.sh](https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/install.sh)
configures on the router:

- [apk/](apk/) — the apk repositories for OpenWrt 25.12+ (apk): one signed
  directory per device architecture, each holding the noarch LuCI packages
  and the architecture's TrustTunnel client build, plus `key-build.pub`.
  Repository URL for the router (the arch is the device's own
  `apk --print-arch`):
  `https://i-zhirov.github.io/trusttunnel-openwrt/apk/<arch>/packages.adb`
- [opkg/](opkg/) — the opkg repository for OpenWrt 22.03–24.10 (opkg):
  one merged feed with every architecture's `.ipk` packages, the signed
  index `Packages` / `Packages.gz` / `Packages.sig` and `opkg-key.pub`.
  Feed URL for the router:
  `https://i-zhirov.github.io/trusttunnel-openwrt/opkg`

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
