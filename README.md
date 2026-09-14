# TrustTunnel distribution for OpenWrt

TrustTunnel client daemon for OpenWrt routers: it runs the tunnel, exposes
a LuCI control page and delivers the tunnel to the LAN. It targets OpenWrt
**22.03 and newer**.

The package delivers the tunnel in one of two **operation modes**
(`main.mode`):

- **TUN mode** (the default) routes the whole LAN through the tunnel: LAN
  traffic is marked with fwmark `0x9527`, a policy rule sends marked
  packets to table `880`, and the client's tun device carries them.
- **Proxy mode** runs a SOCKS5 listener on the router instead. Nothing is
  routed automatically — apps and devices that support a proxy point at
  the listener address (the Proxy tab) and their traffic goes through the
  tunnel from there. There is no tun device and no kernel routing
  involved.

Both modes share the same server settings and the same
**named routing profiles**:

- Each profile carries a **mode** and two rule lists.
- **VPN mode** sends everything through the tunnel except the entries in the
  bypass list; **Bypass mode** sends only the entries in the VPN list through
  the tunnel.
- Rule entries accept a plain domain, a `*.domain` wildcard, an IP address,
  an `IP:port` pair, or a CIDR range.
- One profile is assigned to the server via `endpoint.routing_profile`, and
  the client itself enforces the mode and the rule lists once the traffic has
  been marked into the tunnel (or, in proxy mode, for every connection made
  through the listener).
- With no profile assigned (or a name that no longer matches any profile),
  the previous behavior takes over: everything goes into the tunnel, and the
  flat `domains.direct` list is applied as the exclusions.

**Everything on the router that this package touches:**

- `luci-app-trusttunnel`;
- `trusttunnel-client` and its binaries under `/opt/trusttunnel_client`;
- the `/etc/config/trusttunnel` configuration file;
- in TUN mode: a firewall zone named `trusttunnel` (bound to the `tun+`
  device wildcard) together with the forwarding rule `lan → trusttunnel`,
  and the routing chain fwmark → table `880` → the client's tun device,
  backed by a blackhole killswitch;
- in proxy mode: none of the above — the client binds the SOCKS listener
  itself.

## Requirements

- **OpenWrt 22.03 or newer**: `apk`-based systems need 25.12+, `opkg`-based
  systems 22.03–24.10. The script figures out which package manager is in
  use.
- **CPU**: one of the five families the vendor builds for. The installer
  probes `uname -m` first and aborts before anything changes on unsupported
  hardware:

  | `uname -m` | Covers |
  |---|---|
  | `x86_64` | mini-PCs, virtual machines, x86 gateways |
  | `aarch64` / `arm64` | modern 64-bit ARM routers |
  | `armv7l` / `armv8l` | 32-bit ARM routers of the previous generation |
  | `mips` / `mipsel` | MIPS-based routers, e.g. ath79/ramips boards |

  Anything else — for example ARMv5/ARMv6 boards, `mips64`, `riscv64` or
  `powerpc` — is refused before a single file is changed.
- **Internet access from the router**: needed once at install time.

## Testing and feedback

The package is actively tested on **x86_64** virtual machines and **mipsel** routers. The remaining
vendor-supported families (`aarch64`, `armv7l`/`armv8l`, `mips`) are
covered by the release pipeline's per-architecture builds, but have seen
less hands-on verification on real devices — reports from those platforms
are especially valuable.

Usage reports, bug reports and pull requests are welcome: open an
[issue](https://github.com/i-zhirov/trusttunnel-openwrt/issues) for
anything that does not behave, and
[pull requests](https://github.com/i-zhirov/trusttunnel-openwrt/pulls)
for fixes and improvements. When reporting a problem on a platform other
than x86_64/mips, mention the router model and the OpenWrt release —
device-specific quirks usually reproduce only with that context.

## Installation

Run the installer:

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/install.sh)"
```

The script then:

1. Checks the environment — OpenWrt 22.03+, the CPU family, the package
   manager. The architecture gate runs before anything is changed.
2. Points the package manager at the signed repositories served from the
   GitHub Pages site of this project, in the official OpenWrt layout
   `releases/<version>/packages/<arch>/<feed>/` — one release tree per
   package-manager era (the apk packages live under `releases/25.12.5/`,
   the opkg packages under `releases/22.03.7/`, named after the OpenWrt
   release they were built against), each with a `trusttunnel` feed
   directory per device architecture (the arch is the device's own
   package architecture, `DISTRIB_ARCH` in `/etc/openwrt_release` or
   `/etc/apk/arch` on 25.12+): the apk branch writes
   `/etc/apk/repositories.d/trusttunnel.list` (the
   `releases/25.12.5/packages/<arch>/trusttunnel/packages.adb` index
   URL) and `/etc/apk/keys/trusttunnel.pub`; the opkg branch appends a
   `src/gz trusttunnel <url>/releases/22.03.7/packages/<arch>/trusttunnel`
   line to `/etc/opkg/customfeeds.conf` and copies the feed key into
   `/etc/opkg/keys/` (under the stable name and the usign fingerprint).
3. Installs the required packages `kmod-tun ip-full nftables curl
   ca-bundle`.
4. Installs `luci-app-trusttunnel`; `trusttunnel-client` comes along as a
   dependency, with its binaries in `/opt/trusttunnel_client`.
5. Restarts `rpcd` so the new backend code is loaded.
6. Runs `/etc/uci-defaults/40-luci-trusttunnel` immediately: the script
   creates the firewall zone, the `lan → trusttunnel` forwarding, and seeds
   the Default routing profile and the init script registration. It is
   idempotent, so the same run at the next boot changes nothing.
7. Returns the service to its previous state — a first install leaves it
   disabled. Configure the endpoint first, then turn the switch on and
   start the service.

Run the installer again to pull a newer package and client binary and to
refresh the signing keys; `/etc/config/trusttunnel` is left alone.

## Configuration

Open **Services → TrustTunnel → Settings** in LuCI. The page has five
tabs:

- **General**: a read-only service line, the **operation mode** switch
  (TUN routes the whole LAN; Proxy runs a SOCKS5 listener instead), the
  service switch ("start on boot") — the service runs only while it is
  on — the log level, and the routing-profile selector that assigns the
  profile to the server. After Save & Apply, start the service with the
  Start button on the Status page.
- **Server**: the endpoint the client dials, split into **Connection**
  and **Security** inner tabs. The **Import…** button takes what your
  server produces — the text of a config file, or a `tt://` link — and
  populates each endpoint field the server is able to fill: addresses,
  the TLS host name, credentials, the transport, `custom_sni`,
  `client_random`, plus anti-DPI, IPv6 and certificate-verification
  switches. Everything can also be typed by hand, and a **Test
  connection** button pings every configured address.
- **Proxy**: the SOCKS5 listener used in proxy mode — the listen
  address (`IP:port`, default `127.0.0.1:1080`) and optional user/pass
  authentication (set both or neither). Bind `0.0.0.0:1080` (or the
  router's LAN address) to serve the whole LAN — the client then
  **requires** the user/pass pair and refuses to start without it;
  `127.0.0.1:1080` serves the router itself and needs no credentials.
- **Routing profiles**: the Default profile (VPN mode) is already seeded
  here. Every profile gets a mode — **VPN** (everything is tunneled
  except the bypass-list entries) or **Bypass** (only the VPN-list
  entries are tunneled) — and two rule lists whose entries accept a
  domain, a `*.domain` wildcard, an IP address, an `IP:port` pair or a
  CIDR range. A **Rule preview** button shows how each entry of the
  profile is treated; the profile is assigned to the server with the
  selector on the General tab. The Status page offers the same preview
  for whichever profile is assigned right now.
- **Advanced**: rarely needed — the MTU, the LAN interfaces, the
  blackhole switch, router-traffic routing, the client's own DNS
  upstreams, and the internal routing parameters (firewall mark,
  routing table). The routing options apply in TUN mode only.
- **Versions**: what is installed — the app package and the client
  package versions exactly as the package manager reports them, plus
  the client binary's own version. Read-only: updates are delivered
  through the package repository (`apk update && apk upgrade` on
  OpenWrt 25.12, `opkg update && opkg upgrade` before it, or
  System → Software in LuCI).

The same configuration headless, over UCI:

```sh
uci set trusttunnel.endpoint.hostname='tt.example.net'
uci add_list trusttunnel.endpoint.address='198.51.100.7:443'
uci set trusttunnel.endpoint.username='router'
uci set trusttunnel.endpoint.password='change-me'
uci add_list trusttunnel.endpoint.dns_upstream='1.1.1.1'
uci set trusttunnel.endpoint.custom_sni='tt.example.net'
uci set trusttunnel.endpoint.client_random='0a1b2c'
uci add trusttunnel routing_profile
uci set trusttunnel.@routing_profile[-1].name='Direct'
uci set trusttunnel.@routing_profile[-1].mode='bypass'
uci add_list trusttunnel.@routing_profile[-1].vpn_rules='*.example.com'
uci add_list trusttunnel.@routing_profile[-1].vpn_rules='192.0.2.0/24'
uci set trusttunnel.endpoint.routing_profile='Direct'
uci set trusttunnel.main.enabled='1'
uci commit trusttunnel
/etc/init.d/trusttunnel enable
/etc/init.d/trusttunnel start
```

The routing-profile block is optional: without it (or with a name that
matches no profile), the client falls back to the legacy `domains.direct`
list.

The same configuration in **proxy mode** — a LAN-accessible SOCKS5
listener with authentication:

```sh
uci set trusttunnel.main.mode='proxy'
uci set trusttunnel.proxy.address='0.0.0.0:1080'
uci set trusttunnel.proxy.username='lan'
uci set trusttunnel.proxy.password='lan-pass'
uci set trusttunnel.main.enabled='1'
uci commit trusttunnel
/etc/init.d/trusttunnel enable
/etc/init.d/trusttunnel start
```

Point the SOCKS5-capable app or device at `0.0.0.0:1080` (the router's
address as seen from the LAN) with the credentials above.

## Settings reference

Everything lives in `/etc/config/trusttunnel`. The files under
`/var/etc/trusttunnel/` are generated from it and overwritten whenever
the service starts or settings are applied — they must not be edited.

### Section `main`

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `0` | The service switch: the service starts at boot when it is on, and a start is refused while it is off |
| `mode` | `tun` | The operation mode: `tun` routes the whole LAN through the client automatically; `proxy` runs a SOCKS5 listener instead (see the `proxy` section) |
| `log_level` | `info` | `info`, `debug` or `trace`; the last two are noisy, leave them on only while investigating something |

### Section `proxy`

Used in proxy mode only.

| Option | Default | Meaning |
|---|---|---|
| `address` | `127.0.0.1:1080` | The `IP:port` the SOCKS5 listener binds. `127.0.0.1:1080` serves the router itself; `0.0.0.0:1080` or the router's LAN address serves the whole LAN — the client then requires `username`/`password`. |
| `username` | — | Optional SOCKS5 authentication; set it together with `password`, or leave both empty for an open proxy. Mandatory for any listener outside the loopback. |
| `password` | — | The SOCKS5 password; emitted only when `username` is set |

### Section `endpoint`

| Option | Default | Meaning |
|---|---|---|
| `hostname` | — | TLS host name, used for the TLS session rather than for routing; many servers refuse the connection without it. Required. |
| `address` | — | `host:port` or `[ipv6]:port`, repeatable. With several addresses the client measures them and picks the fastest. At least one required. |
| `username` | — | Required. |
| `password` | — | Required. |
| `protocol` | `http2` | The transport: `http2` or `http3` (QUIC). QUIC is often faster, but some networks throttle or block UDP. |
| `anti_dpi` | `0` | Countermeasures against traffic inspection; worth enabling when the connection establishes but keeps dropping. |
| `post_quantum` | `1` | Post-quantum key exchange. |
| `custom_sni` | — | Overrides the TLS Server Name — needed when the server answers on an address that does not match its host name (a CDN or an IP-only setup). |
| `client_random` | — | TLS Client Random prefix and mask in hex, e.g. `0a0b0c` or `0a0b0c/0f0f0f`; anti-scan servers accept only clients with the matching prefix. |
| `has_ipv6` | `1` | The server carries IPv6. |
| `skip_verification` | `0` | Accept any certificate, which removes the protection against a substituted server. Pin the certificate instead whenever you can. |
| `certificate` | — | Pinned server certificate (PEM). Empty means the system trust store, which requires the `ca-bundle` package. |
| `dns_upstream` | — | DNS used by the client itself — for example the exclusion domains it pre-resolves. Empty means the client default (AdGuard DNS unfiltered). |
| `routing_profile` | `Default` | The name of the assigned routing profile. Empty, or a name that no longer matches any profile, falls back to the legacy `domains.direct` list. |

### Section `network`

| Option | Default | Meaning |
|---|---|---|
| `mtu` | `1350` | Tunnel MTU. Too high a value makes small pages load while TLS handshakes and large downloads stall. |
| `lan_devices` | — | LAN interfaces whose forwarded traffic is considered; empty means the device of the `lan` network, with `br-lan` as the last-resort fallback |
| `blackhole_on_down` | `1` | Add the blackhole route so marked traffic is dropped instead of leaking to the provider when the tunnel is down. |
| `include_router_traffic` | `0` | Also route traffic originated by the router itself. |
| `fwmark` | `0x9527` | The firewall mark, decimal or `0x`-prefixed hex. Change only on a conflict with mwan3, SQM or another package that marks packets. |
| `table` | `880` | The routing table id; anything except `0` and the reserved `253–255`. |

### Section `routing_profile` (anonymous, repeatable)

| Option | Default | Meaning |
|---|---|---|
| `name` | — | Unique name; the endpoint assigns a profile by it. |
| `mode` | `vpn` | `vpn` — tunnel everything except the bypass rules; `bypass` — tunnel only the VPN rules. |
| `vpn_rules` | — | Sent through the tunnel. In bypass mode these are the only tunneled destinations; in VPN mode the list has no effect. |
| `bypass_rules` | — | Always sent out directly. In VPN mode these are the only direct destinations; in bypass mode the list has no effect. |

### Section `domains` (legacy)

| Option | Default | Meaning |
|---|---|---|
| `direct` | — | The flat "do not bypass" list, applied only when no routing profile is assigned (or the assigned name no longer matches any). |

Rule entries in every list accept a plain domain, a `*.domain` wildcard,
an IP address, an `IP:port` pair, or a CIDR range.

## Behaviour

- **Marking and routing.** LAN traffic forwarded into the `trusttunnel`
  zone is marked with fwmark `0x9527`; a policy rule sends marked packets
  to table `880`, whose default route leads to the client's tun device.
  Traffic originating on the router itself is not marked by default
  (`include_router_traffic` is off); it leaves through the ordinary default
  route.
- **Routing profiles.** Inside the tunnel the client itself decides where
  each connection goes. VPN mode keeps everything in the tunnel except the
  entries in the bypass list; Bypass mode puts only the VPN-list entries
  into the tunnel. Domain entries are matched by SNI, while IP addresses
  and CIDR ranges match on the destination — the same matching the legacy
  flat list performed, but now both halves of the selection are explicit
  rules.
- **Killswitch.** Whenever the tun interface is down, the blackhole route
  (metric `1000`) in table `880` swallows marked traffic. The generated
  config turns the client's own killswitch off (`killswitch_enabled =
  false`); the routing table does the protecting.
- **Exclusions.** The `exclusions` list in the generated `client.toml` is
  profile-based: with a VPN-mode profile it comes from
  `routing_profile.bypass_rules`, with a Bypass-mode profile from
  `routing_profile.vpn_rules` (the tunneled set), and from `domains.direct`
  whenever nothing is assigned.
- **DNS.** Nothing intercepts or rewrites DNS: the generated config sets
  `change_system_dns = false`, and the router's resolver keeps serving the
  LAN.
- **Applying changes.** Save & Apply compares the new settings against the
  applied state and regenerates only what the changed keys require:

  | What changed | What happens | Tunnel |
  |---|---|---|
  | `network.lan_devices`, `network.blackhole_on_down`, `network.include_router_traffic` | the rules are regenerated and reloaded, the route reattached; the client keeps running | stays up |
  | `network.table`, `network.fwmark`, `main.enabled`, `main.mode` | full restart: the routing is torn down and rebuilt (a mode switch tears the tun routing down before the client starts as a listener, or brings it up when switching back) | drops |
  | `domains.direct`, `main.log_level`, `network.mtu`, anything under `endpoint.*`, `routing_profile.*` or `proxy.*` | the client restarts while the routing survives the cycle | drops |
  | the pinned certificate | treated like a client restart (it is compared separately, as a file) | drops |
  | nothing relevant | only the applied-state records are updated | stays up |

  Anything outside the schema gets the fullest action too: an unknown key
  can never be applied cheaply, so the safe default is a full restart.
- **Proxy mode.** With `main.mode=proxy` the generated config carries
  `[listener.socks]` instead of `[listener.tun]` — the client accepts
  exactly one listener, so the two blocks are mutually exclusive. The
  routing helper, the hotplug reattach and the `tun+` firewall zone are
  not involved; the SOCKS5 traffic is fail-closed by construction (every
  connection goes through the tunnel, so a dead tunnel just fails the
  connection). The killswitch, MTU, LAN-interface and routing options are
  TUN-mode concepts and have no effect in proxy mode.
- **LuCI pages.** The Status page presents the service state, the client
  log, and a Mode row that names the assigned routing profile and which
  half of its rules goes through the tunnel. In proxy mode it shows the
  listener address instead of the device state, and the "working" verdict
  keys on the listener being bound. Diagnostics walks the chain from
  configuration over the client and the tunnel device to routing,
  firewall and network, with a verdict per check — in proxy mode the
  kernel group is replaced by a single SOCKS-listener check, and the
  through-tunnel comparison uses the listener — and offers `ping`,
  `probe` and `check_domain` tools.

## Diagnostics

Two of the three pages under **Services → TrustTunnel** are described
here: Status and Diagnostics (Settings is covered under Configuration).

### Status page

- A verdict banner: the client is not installed; the service is off;
  the service is enabled but not running; the service runs but the
  tunnel (or, in proxy mode, the SOCKS listener) is not up yet
  ("connecting"); or the tunnel works — with the assigned profile named.
- **Now**: a State row ("working" only when everything is), a Mode row —
  the assigned profile and which half of its rules goes through the
  tunnel, or "Everything through VPN" without a profile — the server
  host name, and in proxy mode the listener address. Start / Stop /
  Restart buttons. A **Preview rules** button shows how each rule of the
  assigned profile is treated right now — or the legacy "do not bypass"
  list when no profile is assigned. The state facts and the client-log
  tail refresh every ten seconds.

### Diagnostics page

Runs the whole chain at once, in the order the package works, and reports
a verdict per check — problems and remarks first, the passing checks
behind a toggle. Read the list top to bottom and look for the first
problem.

| Group | Checks |
|---|---|
| Configuration | endpoint address, credentials, TLS host name, assigned routing profile |
| Prerequisites | client binary, `/dev/net/tun` (TUN mode only) |
| Service | enabled at boot, running now |
| Kernel state | TUN mode: tunnel device and its MTU, route attached to the device, tunnel carrier, fwmark rule, routing table, nftables table, firewall zone. Proxy mode: the SOCKS listener (bound on the configured address or not). |
| Network | endpoint reachable, traffic actually going through the tunnel (via the device in TUN mode, via the listener in proxy mode) |

Four verdicts, and the distinction matters:

- **ok** — checked and working;
- **check** — works with a remark; e.g. the device exists but has no
  carrier yet, because the client has not established the tunnel;
- **problem** — not working, with what to do about it;
- **skipped** — nothing to check, because an earlier link is not ready; a
  stopped service must not make the kernel checks red.

The page also carries three tools:

- **Ping the server** — loss and min/avg/max for every configured address.
- **Compare the external address** — the address seen through the tunnel
  next to the one seen directly. The same address both ways means the
  traffic is not using the tunnel. In TUN mode a request bound to the
  device can fail even on a healthy tunnel, because the default route
  lives in the marked table — judge by a LAN client instead. In proxy
  mode the request goes through the SOCKS listener.
- **Check a domain** — the normalized name, whether the domain is listed
  (an entry like `example.com` matches the domain itself and its
  subdomains), and the verdict — through the tunnel or direct — with the
  reason. The tool only consults the rule lists; it does not resolve the
  domain or touch the rules.

## Where things live

| Path | Contents |
|---|---|
| `/etc/config/trusttunnel` | Your settings; survives package updates (declared as a conffile) |
| `/var/etc/trusttunnel/settings.tsv` | The applied settings in flat form (mode 600); Save & Apply compares the new state against it |
| `/var/etc/trusttunnel/client.toml` | The generated client configuration (mode 600) |
| `/var/etc/trusttunnel/endpoint.pem` | The pinned certificate, when one is set (mode 600) |
| `/var/etc/trusttunnel/device` | The tun device the tunnel route is currently attached to |
| `/opt/trusttunnel_client/` | The client binaries: `trusttunnel_client` and `setup_wizard` |

## Troubleshooting

- **The service will not start.** Read the client log
  (`logread -e trusttunnel`). A missing `ca-bundle` refuses the start
  unless a certificate is pinned or verification is skipped; a missing
  `/opt/trusttunnel_client/trusttunnel_client` means the client package is
  not installed — run install.sh. The service also refuses to start while
  `main.enabled` is off: the "start on boot" switch is the service switch,
  not only a boot preference.
- **Handshakes fail on a freshly flashed router.** The client validates
  the server certificate against the wall clock; the service waits up to
  30 seconds for the clock to catch up and logs a warning when it stays
  behind. Synchronize the clock (NTP) and restart the service.
- **The device exists but the tunnel never comes up.** The device is
  created by the client, not by the package: if it exists but the carrier
  is down, the client has not established the connection — the client log
  says why.
- **Marked traffic is dropped.** When the route is not attached to the
  device, marked traffic falls into the blackhole; the "Route attached to
  the device" check reports it. Restart the service.
- **Nothing goes through the tunnel.** Check the marking chain: the
  traffic must be forwarded from a listed LAN interface into the
  `trusttunnel` zone (the `lan → trusttunnel` forwarding rule).
  "Compare the external address" shows the same IP both ways when the
  tunnel is not used.
- **The firewall zone is missing from the live ruleset.** The kernel
  checks report it; run `/etc/init.d/firewall reload` — the uci-defaults
  script recreates the zone on the next boot.
- **The interface shows a new value, the client behaves as before.**
  Save & Apply updates the applied state only after regenerating the
  client configuration; when the interface and the applied state diverge,
  the service log shows where the apply failed.

## Limitations

- One server per router: the endpoint holds a single host name and one set
  of credentials. Several addresses are just several entries of that one
  server — the client measures them and picks the fastest.
- Only forwarded LAN traffic is routed by default; traffic originating on
  the router itself leaves through the ordinary default route unless
  `include_router_traffic` is on.
- Domain rules are matched by the connection's TLS SNI once the traffic is
  inside the tunnel. Connections without a TLS SNI (plain IP, non-TLS)
  can be matched only by IP or CIDR rules. DNS is not involved in the
  selection: the router's resolver keeps serving the LAN untouched.
- The client's tun device is created and named by the client itself; the
  package attaches the tunnel route to whatever device appears (via
  hotplug) and records it in `/var/etc/trusttunnel/device`.
- The firewall zone binds the `tun+` wildcard, so tun devices created by
  other software fall under it too (see Notes).
- The tunnel MTU comes from `network.mtu`; too high a value stalls TLS
  handshakes and large downloads.
- **Proxy mode** does not route anything automatically: only apps and
  devices explicitly configured to use the SOCKS5 listener get the
  tunnel. DNS for proxied connections is resolved by the client through
  the tunnel (`endpoint.dns_upstream`); apps that resolve locally and
  send bare IPs do not get that DNS. An open listener (no credentials)
  bound to `0.0.0.0` is reachable by the whole LAN — the client itself
  refuses to bind anything outside the loopback without the user/pass
  pair, so protect LAN-exposed listeners with credentials.

## Updating

The repository entry installed by the setup script remains, so keeping the
package current is a plain package-manager call:

```sh
apk update && apk upgrade   # OpenWrt 25.12+
opkg update && opkg upgrade # OpenWrt 22.03–24.10
```

`trusttunnel-client` is a hard dependency of the LuCI app, so the binary
updates together with the package, and `/etc/config/trusttunnel` survives
untouched.

## Uninstalling

Run the uninstaller:

```sh
sh -c "$(wget -O - https://raw.githubusercontent.com/i-zhirov/trusttunnel-openwrt/main/uninstall.sh)"
```

The script then:

1. Halts the service and disables its auto-start.
2. Removes the packages in one call — `luci-app-trusttunnel`,
   `trusttunnel-client` (for opkg the dependents must come first in the
   list).
3. Tears down the repository configuration and the signing keys the
   installer put in place.
4. Removes the client binaries and the caches (`/opt/trusttunnel_client`,
   `/usr/share/trusttunnel`, `/var/cache/trusttunnel`,
   `/var/etc/trusttunnel`) and cleans the leftovers of earlier versions
   of the package: the stored lists, the `update_lists` cron line, and any
   leftover dnsmasq include.
5. Prompts whether to remove the firewall zone (default: yes) and for the
   settings file (default: no — a reinstall keeps it).
6. Restarts `rpcd`; the LuCI caches are wiped.
7. Checks the kernel for leftovers — the nft table, the rule for table
   `880`, routes in table `880`; anything still present means the service
   did not stop cleanly and a reboot will clear it.

Flags: `-y` answers every question with yes, removing the zone and the
settings unprompted; `-c` keeps `/etc/config/trusttunnel` without asking.
Shared dependencies (`kmod-tun`, `ip-full`, `nftables`, `curl`,
`ca-bundle`) stay installed on purpose.

Removing by hand works as well:

```sh
/etc/init.d/trusttunnel stop
/etc/init.d/trusttunnel disable
apk del luci-app-trusttunnel
# on 22.03–24.10: opkg remove luci-app-trusttunnel
rm -rf /opt/trusttunnel_client
# remove the feed entry and the installed keys (paths above)
uci show firewall | grep trusttunnel
uci delete firewall.@zone[1]   # the section numbers from the listing
uci delete firewall.@forwarding[1]
uci commit firewall
/etc/init.d/firewall restart
```

## Notes and caveats

- **Firewall zone.** Because the zone binds the `tun+` wildcard, tun
  devices created by other software fall under it too.
- **Repositories and signing.** The repositories are served from the
  GitHub Pages site of this project
  (`https://i-zhirov.github.io/trusttunnel-openwrt`), in the official
  OpenWrt layout `releases/<version>/packages/<arch>/trusttunnel/`: the
  `releases/25.12.5/` tree holds the apk feeds (index `packages.adb`,
  25.12+), the `releases/22.03.7/` tree the opkg feeds (`Packages.gz` /
  `Packages.sig`, 22.03–24.10) — one signed feed directory per device
  architecture next to the packages. The release workflow publishes the
  site straight from CI, and no branch ever holds the packages.
  Signing: `adbsign` (EC key) for the apk index, `usign` for the opkg
  feeds.
- **Manual downloads.** A `.apk` or `.ipk` fetched from the release assets
  must be checked against the SHA-256 sums in the release notes.
- **Key rotation.** The signing keys rotate; run the installer once more to
  refresh the copies on the router.

## Acknowledgements

- [`TrustTunnel/TrustTunnel`](https://github.com/TrustTunnel/TrustTunnel)
  — the server component (Apache-2.0)
- [`TrustTunnel/TrustTunnelClient`](https://github.com/TrustTunnel/TrustTunnelClient)
  — the client binary (Apache-2.0)
- [`NooBiToo/TrustTunnelOpenWrt`](https://github.com/NooBiToo/TrustTunnelOpenWrt)
  — the upstream LuCI package that inspired this implementation
- [`iamvladdy/trusttunnel-openwrt`](https://github.com/iamvladdy/trusttunnel-openwrt)
  — an independent netifd-based implementation that pairs the client with
  [podkop](https://podkop.net) for selective routing

## License

Apache-2.0 (see `LICENSE`).
