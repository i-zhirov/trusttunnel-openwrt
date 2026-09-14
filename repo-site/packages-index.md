---
layout: repo-index
title: "packages — __TREE__ — trusttunnel-openwrt"
---

# packages — `__TREE__`

Signed package feeds per device architecture for the OpenWrt `__TREE__`
release, laid out like the official OpenWrt repositories
(`releases/<version>/packages/<arch>/<feed>/`). Each `trusttunnel` feed
directory holds the signed index of the tree's package manager, the
public signing key and every released version of the packages.

Repository URLs for the router (the arch is the device's own package
architecture — `DISTRIB_ARCH` in `/etc/openwrt_release`, or
`/etc/apk/arch` on 25.12+):

```text
https://i-zhirov.github.io/trusttunnel-openwrt/releases/__TREE__/packages/<arch>/trusttunnel
```

Architectures:

__ARCH_LIST__

[« back to the release __TREE__](../)
