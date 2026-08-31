---
layout: repo-index
title: "apk repository — trusttunnel-openwrt"
---

# apk repository — trusttunnel-openwrt

OpenWrt 25.12+ (apk). One signed repository per device architecture — apk
matches the package arch against the device's own arch exactly, so the router
must use its own subdirectory (`apk --print-arch`):

```text
https://i-zhirov.github.io/trusttunnel-openwrt/apk/<arch>/packages.adb
```

Public signing key: [key-build.pub](key-build.pub)

Architectures (each directory holds the noarch LuCI packages and the
architecture's TrustTunnel client build):

__ARCH_LIST__
