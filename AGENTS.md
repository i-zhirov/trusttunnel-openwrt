# AGENTS.md — trusttunnel-openwrt

Guidance for AI agents and human contributors working in this repository.

## What this project is

`trusttunnel-openwrt` is an independent implementation of an OpenWrt package
set for the [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) client:

- `luci-app-trusttunnel` — a noarch LuCI application: a procd service, a
  UCI-backed config, an rpcd ucode backend, four LuCI views, plus
  firewall/routing integration.
- `trusttunnel-client` — a per-architecture packaging of the vendor's
  prebuilt, statically-linked client binaries into `/opt/trusttunnel_client`.
- `install.sh` / `uninstall.sh` — router-side scripts that configure the
  package repositories and install/remove the packages.
- Signed package repositories (apk + opkg) and a GitHub Pages site, both
  produced by the release workflow.

Targets **OpenWrt 22.03+**: `opkg` on 22.03–24.10, `apk` on 25.12+. Supported
CPU families: `x86_64`, `aarch64`, `armv7l/armv8l`, `mips`, `mipsel`.

The package routes LAN traffic through the tunnel using **fwmark → routing
table 880 → the client's tun device**, backed by a blackhole killswitch, and
is configured through **named routing profiles** (VPN mode / Bypass mode).
See `README.md` for the user-facing description.

## Repository layout

```
install.sh, uninstall.sh      Router-side installer/uninstaller (POSIX sh)
packages/
  luci-app-trusttunnel/       The LuCI app package (feed-style root/ tree)
    Makefile                  OpenWrt package metadata
    htdocs/luci-static/resources/view/trusttunnel/
      settings.js status.js log.js diagnostics.js   LuCI client-side views
    root/etc/config/trusttunnel              Default UCI config
    root/etc/init.d/trusttunnel              procd service script
    root/etc/uci-defaults/40-luci-trusttunnel  First-boot setup
    root/etc/hotplug.d/net/40-trusttunnel    Tun-device reattach hook
    root/usr/libexec/trusttunnel/            Runtime helpers (see below)
    root/usr/share/luci/menu.d/…json         Menu entry
    root/usr/share/rpcd/acl.d/…json          RPC/UCI ACL
    root/usr/share/rpcd/ucode/luci.trusttunnel  rpcd backend
  trusttunnel-client/         Per-arch packaging of vendor binaries
repo-site/                    Jekyll templates for the GitHub Pages package
                              repository site (index pages, layout)
tests/                        Shell test suite (see "Testing")
tests/backend/                Docker-based backend contract test + goldens
tests/integration/            Dockerized end-to-end suite: real install.sh
                              against a router and a TrustTunnel endpoint
                              container (see "Testing"; own workflow)
.github/workflows/ci.yml      CI gates (test + lint + contract checks)
.github/workflows/integration.yml  End-to-end suite on PRs/main/dispatch
.github/workflows/release.yml Release pipeline (build, sign, verify, publish)
key-build.pub, opkg-key.pub   PUBLIC halves of the repo signing keys (committed)
LICENSE                       Apache-2.0
```

There is no `docs/` directory; user documentation lives in `README.md` and
is tracked in the root on purpose (see `.gitignore` comment). The private
halves of the signing keys are GitHub secrets, never committed.

## Router-side scripts (`install.sh` / `uninstall.sh`)

The installer: probes the environment (OpenWrt release, CPU family via
`uname -m`, package manager) and refuses unsupported hardware before
anything is changed; points the package manager at the signed
repositories — apk: `/etc/apk/repositories.d/trusttunnel.list` (the
`packages.adb` index URL) plus `/etc/apk/keys/trusttunnel.pub`; opkg: a
`src/gz trusttunnel` line in `/etc/opkg/customfeeds.conf` plus the feed
key under both the stable name and the usign fingerprint in
`/etc/opkg/keys/`; installs `kmod-tun ip-full nftables curl ca-bundle`
and then `luci-app-trusttunnel` (pulling `trusttunnel-client` as a
dependency); restarts `rpcd`; runs `/etc/uci-defaults/40-luci-trusttunnel`
immediately (idempotent, so the boot-time run changes nothing); and
restores the previous service state — a first install leaves the service
disabled. Re-running it updates the packages, the client binary and the
signing keys; `/etc/config/trusttunnel` is left alone (conffile).

The uninstaller: halts and disables the service; removes both packages in
one call (for opkg the dependents must come first in the list); tears down
the repository configuration and the signing keys; deletes
`/opt/trusttunnel_client`, `/usr/share/trusttunnel`,
`/var/cache/trusttunnel` and `/var/etc/trusttunnel`; cleans the leftovers
of earlier package versions (the stored lists, the `update_lists` cron
line, any leftover dnsmasq include); prompts for the firewall zone
(default: remove) and the settings file (default: keep — a reinstall
keeps it); restarts `rpcd` and wipes the LuCI caches; and checks the
kernel for leftover routing state (the nft table, the rule for table 880,
routes in table 880) — anything still present means the service did not
stop cleanly, and a reboot will clear it. Flags: `-y` answers every
prompt with yes, `-c` keeps `/etc/config/trusttunnel` unprompted. Shared
dependencies stay installed on purpose.

## Core architecture: the data flow

Everything on the router is driven by one UCI config, one derived TSV file,
one generated client config, and one routing helper. The chain is:

```
/etc/config/trusttunnel            (UCI: main, endpoint, network,
        |                               routing_profile*, domains)
        | uci-export                (dumps 30 fixed keys to TSV)
        v
/var/etc/trusttunnel/settings.tsv  (the "records"; consumed everywhere)
        | records.sh                (sourced accessor library: tt_get,
        |                               tt_list, tt_bool, tt_count)
        v
/var/etc/trusttunnel/client.toml    (gen-config; the client binary's config)
/var/etc/trusttunnel/endpoint.pem   (pinned cert, written by init script)
/var/etc/trusttunnel/device         (attached tun device name, routing helper)
```

### The records schema

`uci-export` is the canonical emitter of the records TSV
(`section.option<TAB>value`, list options repeat their key). The emitted
key set — **30 keys, fixed order** — is a hard contract shared by
`records.sh`, `gen-config`, the `routing` helper, the init script's change
classifier and the ucode backend's `records()` parser. Nothing outside the
schema ever appears in the file (foreign UCI sections must not leak), and
`endpoint.certificate` is deliberately NOT exported (multi-line PEM; it is
written separately to `endpoint.pem` by the init script).

`uci-export` must never gain `set -u`: `/lib/functions.sh` reads
uninitialized variables and dies under it.

### Operation modes (tun / proxy)

`main.mode` (default `tun`, absent on upgraded installs means `tun`)
selects how the tunnel is delivered:

- **tun mode** — the classic wiring: `[listener.tun]` in `client.toml`,
  kernel routing via fwmark → table 880 → the client's tun device,
  hotplug reattach, the `tun+` firewall zone, MTU.
- **proxy mode** — `[listener.socks]` in `client.toml` (address +
  optional user/pass auth) instead; no kernel routing, no tun device, no
  hotplug, no zone. The client accepts EXACTLY ONE listener, so
  `gen-config` must never emit both blocks.

The mode gates: `gen-config` (listener block), the init script's
`mode_is_proxy()` (skip `routing up`/attach in `start_service`, skip the
routing reload in `apply_settings`), the `routing` helper (refuses `up` in
proxy mode — defense in depth), the hotplug hook (exits early), the
backend (`status.mode`/`proxy_address`/`listener_up`, `probe` via
`curl --socks5-hostname`, `diagnose`'s kernel group and tunnel check) and
the views (mode picker, Proxy tab, verdict/facts). `main.mode` maps to
`restart_full` and `proxy.*` to `restart` in the change classifier; the
listener state is detected through `/proc/net/tcp{,6}` (local port in hex,
anchored grep — the fixed-width sl column makes plain field splits
unreliable).

### Routing profiles (the core feature)

`endpoint.routing_profile` names a `routing_profile` section by its `name`
option. `uci-export` (to emit the profile's records), `gen-config` and the
backend resolve the name; an empty or stale name falls back to the legacy
`domains.direct` list.

- **VPN mode** (`mode='vpn'`) → client `vpn_mode = "general"`, exclusions =
  `routing_profile.bypass_rules`.
- **Bypass mode** (`mode='bypass'`) → client `vpn_mode = "selective"`,
  exclusions = `routing_profile.vpn_rules` (the tunneled set).
- **No/unknown profile** → `vpn_mode = "general"`, exclusions =
  `domains.direct`.

Rule entries accept a plain domain, `*.domain`, an IP, `IP:port`, or CIDR.
Domain matching happens inside the client (by SNI).

### Kernel routing state (`/usr/libexec/trusttunnel/routing`)

Subcommands: `dump | up | attach | reattach | detach | down | status`.
- `up`: blackhole default routes (metric 1000) in table 880 → fwmark rule
  (priority 30820) → the nft ruleset (table `inet trusttunnel`, sets
  `tt_endpoint4/6`, a prerouting chain that marks traffic arriving on a
  LAN device and destined outside the endpoint sets and the private
  ranges with fwmark `0x9527`). Endpoint addresses are resolved BEFORE
  the ruleset lands (marked traffic would otherwise blackhole DNS).
  `up` refuses to run when the records declare proxy mode.
- `attach`: point table 880's default route at the client tun device
  (metric 1) and record the device name in `$OUT_DIR/device`.
- `down`: remove everything; the client's device is never deleted.
- Overrides for tests: `TT_IP`, `TT_NFT`, `TT_LIBDIR`.

### Service lifecycle (`/etc/init.d/trusttunnel`)

procd service, `USE_PROCD=1`, `START=95`, `STOP=10`. Notable behaviors:

- `start_service` checks `main.enabled` — the gate applies to the
  automatic starts only: the rpcd backend's explicit `start`/`restart`
  (the Status page buttons) sets `TT_START_NOW=1`, which bypasses it, so
  the tunnel runs on demand while "start on boot" is off (and stays off
  at the next boot). Then the client binary, the trust store, records +
  config regeneration, a wait for a default route and for the clock to
  catch up, `routing up` (tun mode only), the client with `procd` and an
  attach of an already-existing tun device (tun mode only).
- `reload_service` → `apply_settings`: classifies the diff between the
  current records and the new export (`changed_keys` →
  `classify_change`), producing `noop | reload | restart | restart_full`,
  and applies the cheapest correct action. Unknown keys must map to the
  FULLEST action (a silently unapplied setting is worse than a restart).
- `restart` blocks SIGTERM and uses the `_TT_KEEP_ROUTING` handshake so
  routing survives the stop+start cycle; `abort_restart_cleanup` tears
  routing down when an interrupted restart left it hanging.
- `service_triggers`: reload on UCI change, restart on wan interface up.

### Hotplug (`/etc/hotplug.d/net/40-trusttunnel`)

On `ACTION=add` for a non-persistent tun device (`tun_flags` sysfs marker,
`IFF_PERSIST` bit 0x800 clear) belonging to a running service, reattaches
the routing table's default route to the new device. Foreign devices and
devices that would displace a working tunnel are ignored.

### uci-defaults (`/etc/uci-defaults/40-luci-trusttunnel`)

First-boot / reinstall setup: dedups the `trusttunnel` firewall zone and
forwarding, creates them when missing (zone bound to `tun+`, `lan →
trusttunnel` forwarding), migrates old concrete `tt0` bindings to `tun+`,
seeds the Default routing profile (migrating `domains.direct` into its
bypass rules), creates the UI-only `about` section that keys the Versions
tab on the Settings page, registers the rc.d link and clears LuCI caches.
Idempotent; also run immediately by `install.sh`.

### rpcd backend (`/usr/share/rpcd/ucode/luci.trusttunnel`)

Exposes `luci.trusttunnel` RPC methods (the ACL grants read on
`status ping probe check_domain log diagnose versions` and write on
`service import_config`):

- `status` — service state, device, rule/table/nft flags, endpoint,
  routing profile and effective `vpn_mode`.
- `versions` — what is installed, read-only: the luci app and client
  package versions as apk/opkg report them (apk on 25.12+, opkg
  fallback for 22.03–24.10), plus the client binary's own `--version`;
  no network access.
- `service` — start/stop/restart/reload with a post-start liveness probe.
- `ping` — ping each configured endpoint host (or a given target).
- `probe` — external IP through the tunnel vs. direct (curl + api.ipify.org).
- `check_domain` — verdict for one domain against the effective rules.
- `log` — last N logread lines filtered by `trusttunnel`.
- `diagnose` — the chain walk: config → prerequisites → service → kernel
  → network, each check `{group, label, status, detail, hint}`, plus
  counts and an overall verdict.
- `import_config` — feeds server config text or a `tt://` link to the
  vendor's `setup_wizard`, parses the produced settings and returns the
  endpoint fields; secrets go through `write_secret_tmp` (mode 0600).

Imports note: the backend imports `fs` and `math` module functions only.
`ci.yml` gates that every used module function is imported and that the
file compiles under the pinned ucode.

### LuCI views

- `status.js` — verdict banner, facts (state/mode/server/proxy address),
  Start/Stop/Restart buttons, a rules preview for the assigned profile
  (or the legacy `domains.direct` list without one) that checks each
  effective rule via `check_domain`; polls every 10s. The verdict is
  mode-aware: the "working" gate is `device_up` in tun mode and
  `listener_up` in proxy mode.
- `log.js` — a tail of the system-log lines written by the client and
  the service (the `log` RPC), fetched during `load()` so the first
  paint already shows it, then refreshed in place by a 10 s poll; the
  status verdicts and the backend diagnose hints point users here.
- `settings.js` — a single tabbed `form.Map` whose sections become tabs
  (General, Server, Proxy, Routing profiles, Advanced, Versions), plus
  the Import… modal that calls `import_config` and applies results to
  pending UCI (nothing is written until Save & Apply). The endpoint
  section splits into Connection and Security inner tabs
  (`s.tab`/`s.taboption`) — map-level tabs key panes by the UCI section
  type, so two sections of the same type would collide. The General tab
  carries the operation-mode picker (`main.mode`), the Proxy tab the
  SOCKS5 listener settings (address + optional user/pass pair, validated
  both-or-neither). The Versions tab is a `NamedSection` of the UI-only
  `about` section type: it carries no UCI options, its DummyValue rows
  read the `versions` RPC result, and uci-defaults creates the section
  on installs that predate it. Extra tools: a read-only service line on
  General (via the `status` RPC), a Test connection modal on Server
  (`ping`), and a per-profile rule preview (`check_domain`) whose
  verdicts only apply to the assigned profile. The routing profile
  picker lives on General and `dns_upstream` on Advanced; both write the
  endpoint section via `ucisection`. Config values are read via the
  `uci` module API (`uci.sections()`/`uci.get()`) — current LuCI
  resolves `uci.load()` with the package-name list, so the load()
  result is no data source.
- `diagnostics.js` — renders the diagnose checks grouped and ordered
  (config → prereq → service → kernel → network), problems first with a
  toggle for the rest, plus domain-check, ping and address-compare tools
  and a Copy report button that serializes the last run into a textarea.
  Backend strings are translated through the `DIAG_TEXT` map; new
  backend strings must be added there to be translatable.

## Packages and versioning

### `luci-app-trusttunnel/Makefile`

- `PKG_VERSION` comes from `git describe --tags --abbrev=0` (tag `vX.Y.Z`
  → version `X.Y.Z`), falling back to the last released version (currently
  `1.0.26`). The fallback must track the latest release — the release
  workflow fails a tag build whose artifact does not carry the tag.
- `LUCI_DEPENDS:=+trusttunnel-client +luci-base +ip-full +nftables +curl
  +ucode-mod-math`. **Do not add `kmod-tun` or `ca-bundle` here**: they
  belong on `trusttunnel-client`'s own DEPENDS and arrive transitively.
  `test_deps.sh` enforces this.
- The `Package/luci-app-trusttunnel/conffiles` block must stay BEFORE
  `include $(TOPDIR)/feeds/luci/luci.mk` (luci.mk freezes the list
  immediately; a late declaration loses `/etc/config/trusttunnel` on
  upgrades).
- `Build/Compile` chmods the shipped scripts explicitly — the git index is
  NOT a reliable carrier of exec bits (zip downloads, Windows). `ci.yml`
  separately verifies index modes are `100755`.

### `trusttunnel-client/Makefile`

- Wraps the vendor's per-CPU-family tarballs
  (`trusttunnel_client-v$(PKG_VERSION)-linux-<family>.tar.gz`, currently
  `PKG_VERSION:=1.0.49`). On a vendor release, bump `PKG_VERSION` and the
  per-family `PKG_HASH` values together (digests come from the vendor's
  release API).
- `VENDOR_ARCH` maps `$(ARCH_PACKAGES)` (subtarget arch) → vendor family
  (x86_64 / aarch64 / armv7 / mips / mipsel). The `$(error …)` guard is
  wrapped in `ifneq ($(ARCH_PACKAGES),)` because the metadata dump
  evaluates the Makefile without target config.
- `PKG_BUILD_DIR` is overridden BEFORE `package.mk` is included (the
  tarball's top-level directory is named after the source).
- Installs `trusttunnel_client`, `setup_wizard`, their `.sig` files and
  `LICENSE` into `/opt/trusttunnel_client` (path hardcoded elsewhere).
- The vendor ships one tarball per CPU family but the package is built per
  OpenWrt subtarget arch — apk/opkg match arch byte-exactly.

## Testing

Run the full suite from the repo root:

```sh
sh tests/run.sh
```

This executes every `tests/test_*.sh` in its own `mktemp -d` scratch
directory (exported as `TT_TEST_TMP`) with stdin closed, and fails on any
failure. Skipped tests (`tt_skip`, exit 77) are counted and reported
("all tests passed (N skipped)"). Docker-gated tests skip when docker is
absent, so the plain suite runs anywhere.

### Test conventions

- `tests/lib.sh` provides `assert_eq`, `assert_contains`, `assert_exit`,
  `_tt_pass`/`_tt_fail`, `tt_skip` (reports a skipped test, exit 77) and
  `tt_test_summary` (must be called at the end of each test). Counters
  live in files under `$TT_TEST_TMP` so assertions in subshells still
  count.
- Each test file starts with a header comment stating what contract it
  pins, and explains the WHY of tricky assertions.
- Fixtures: `tests/fixtures/records/{minimal,full,bypass}.tsv`.
- `tests/test_harness.sh` — self-test of the assertion helpers: proves
  they accept a passing and a failing check and that a failure inside a
  subshell is recorded in the counter files.
- `tests/test_hotplug.sh` — pure-shell scenario harness (no docker):
  sed-rewrites the script's hardcoded paths into a scratch tree, stubs
  init/routing/logger, and covers filters | guards | attach | invariants.
- `tests/test_views_runtime.sh` + `tests/views_runtime.js` — executes the
  four views against mocks that replicate the CURRENT LuCI runtime
  contracts (`uci.load()` resolving with the package-name list, no plain
  `form.Section`, `E()` reading only `arguments[2]`) and asserts the
  rendered output. Needs node (skips, exit 77, without it). This is the
  gate the syntax-only view checks cannot provide: the v1.0.16-1.0.20
  view bugs were runtime contract mismatches that parse fine and only
  fail when executed.
- Tests stub external commands (ip, nft, uci, logger, curl, logread) and
  honor `TT_*` overrides; see `test_routing.sh` (`TT_IP`, `TT_NFT`,
  `TT_LIBDIR`), `test_uci_defaults.sh` (`TT_UCD_SCRIPT`, `TT_UCD_FILTER`).

### Docker-based tests

- `tests/backend/test_backend_contract.sh` — requires the pre-built
  pinned-ucode image (`docker build -q -t tt-ucode-gate -f
  tests/backend/Dockerfile tests/backend`; ci.yml builds it, locally build
  it once; the test skips — exit 77 — when it is missing), builds a rootfs
  lab from it (`tests/backend/lab.Dockerfile` + the stub tree under
  `tests/backend/rootfs/`), copies the LIVE backend into
  `tests/backend/mod/luci/trusttunnel.uc`, and byte-compares each method's
  output against `tests/backend/goldens/*.json` (baked rootfs state) and
  `goldens/healthy/*.json` (real tun device in a privileged container).
  **Do not edit `tests/backend/mod/luci/trusttunnel.uc`** — it is a copy
  overwritten by the test. Golden file names encode method + args
  (`golden_call` in the script).
- `tests/test_uci_defaults.sh` — scenario harness running the real
  uci-defaults script in an OpenWrt rootfs container against scratch
  configs (fresh / duplicated / legacy / upgrade / side-effects /
  idempotent scenarios).
- `tests/install-harness.sh` — dry-run scenarios for `install.sh` in
  `openwrt/rootfs` containers with stubbed apk/opkg/wget/usign. NOT
  picked up by `tests/run.sh` (name has no `test_` prefix) but run as its
  own ci.yml step; supports `TT_FILTER`.
- `tests/integration/` — the dockerized end-to-end suite: `build-sdk.sh`
  builds THIS tree's packages with the pinned OpenWrt SDK, then `run.sh`
  boots a real OpenWrt rootfs router (`/sbin/init`), runs the real
  `install.sh` against a hermetic signed repository, connects it to a
  real TrustTunnel endpoint container and asserts the install, service
  and traffic contracts (through-tunnel traffic arrives with the
  endpoint's source address, private traffic stays direct, the blackhole
  killswitch swallows marked traffic, install/uci-defaults/reload are
  idempotent). The later stages exercise the multiple-server model live:
  `switch` saves a second endpoint as the Backup server, selects it via
  `main.endpoint` + reload and asserts the records, client.toml and the
  traffic follow it (and back), and `migrate` deletes the ACTIVE server's
  section, asserts the dangling selector stops the service, then runs
  the uci-defaults script exactly as the boot runs it and asserts the
  selection is re-pointed at the remaining server, which brings the
  tunnel back. An early pure-shell `archparse` stage pins the ipk
  arch/version derivation (`tests/integration/ipk-arch.sh`, shared with
  release.yml's opkg assembly) against every matrix arch-name shape — a
  last-underscore split once clipped `mipsel_24kc` to `24kc`, and the
  harness's opkg repo assembly derives its feed directory from the real
  artifact, so the regression fails the install assertions too. Knobs:
  `TT_PM=apk|opkg`, `TT_REPO_DIR`, `TT_FILTER`,
  `TT_LOGS_DIR`, `TT_RELEASE_TAG` — see `tests/integration/README.md`.
  Docker-gated (skip 77), deliberately NOT picked up by `tests/run.sh`;
  `integration.yml` runs it on PRs/main/dispatch, and the release
  pipeline reuses it against the release's own artifacts. Every network
  request in the docker harnesses is retried (transient registry/mirror/
  lab-net failures must not fail a run): the `retry`/`retry_out` helpers
  in `run.sh`, and the same shape in `build-sdk.sh`, `restricted-feeds.sh`,
  `gui/run.sh` and `test_backend_contract.sh`.
- `tests/integration/restricted-feeds.sh` — the SDK feed pins: prints the
  `EXTRA_FEEDS` value (base/packages/luci only — the routing/telephony/
  video clones are dead weight; the client build uses base only) and
  `--verify` compares the hardcoded pins against the SDK image's
  `feeds.conf.default`, failing on drift. The pins are the OTHER half of
  the SDK pin: when release.yml bumps the SDK version, update them
  together with `VERSION_PATH`.

### View contract and GUI tests

- `tests/view-contract.js` — a node gate (its own ci.yml step) cross-
  checking the views against the backend without a browser:
  1. every `rpc.declare({object, method, params})` in the views must name
     an object/method the backend registers (parsed from
     `luci.trusttunnel.uc`) and one the ACL grants (read or write), and
     the declared params must be a subset of the backend's `args`;
  2. every literal label/detail/hint the diagnose method emits — as
     pinned by the backend contract goldens — must be a key of the
     `DIAG_TEXT` map in `diagnostics.js` (templated values like versions,
     addresses and ping averages are exempt via the allowlist, which
     documents the backend expression producing each pattern). A new
     literal string in a golden without a `DIAG_TEXT` entry fails the
     gate; cover a new state in the backend contract test first, then
     this gate sees it.
- `tests/gui/` — the browser layer of the view contract. The REAL views
  (real `luci.js` loader, real `form.Map`, real RPC batching) run in a
  headless chromium inside the pinned `mcr.microsoft.com/playwright`
  image against a stubbed ubus backend (`tests/gui/stub/server.js`) that
  serves the backend contract goldens byte-identically, so the browser
  sees exactly the responses `tests/backend` pins. The specs
  (`specs/{status,settings,diagnostics}.spec.js`) assert on the rendered
  DOM and on the RPC frames the stub records (`/__stub` control
  endpoint). `tests/gui/run.sh` orchestrates: docker-gated (skip 77),
  fetches the pinned luci-base resources (`openwrt-25.12` commit,
  `TT_GUI_REF` to override) into `tests/gui/.cache`, installs the pinned
  `@playwright/test` into `tests/gui/node_modules`, then runs stub +
  specs inside the image. Both cache dirs are gitignored.
- `tests/gui/dev.sh` — the manual development loop: starts the same stub
  on the host (no docker, no build, no release) against the same pinned
  luci-base cache, prints the three view URLs and the `/__stub` cheat
  sheet, and serves the resources with no-cache headers so an edit +
  plain reload is the whole cycle. Router state is faked live through the
  control endpoint (e.g. `curl -X POST -d '{"set":{"status":{"running":false,"enabled":true}}}' http://127.0.0.1:8123/__stub`;
  `{"reset":true}` restores the goldens). The luci-base pin and fetch
  live in `tests/gui/lib-luci.sh`, shared with `run.sh` so the dev loop
  and the test suite can never drift.
- The luci-base pin matters: the loader, `dom.create()`'s argument
  handling (`E()` reads only `arguments[2]` — children must be arrays,
  and a DOM node as the second argument is treated as the attribute
  object) and the uci module API (`uci.load()` resolves with the
  package-name list; `TypedSection` maps sections by `s['.name']`, which
  rpcd fills in) all move between LuCI generations. When the pin is
  bumped, re-run `tests/gui/run.sh` and the suite against the old pin to
  see what changed.

## CI gates (`.github/workflows/ci.yml`)

Every step is a contract gate; the tree must pass all of them. Locally
reproducible equivalents:

- Executable bits of shipped scripts must be `100755` in the index.
- Tag pushes must not regress the release: new tag's commit must be newer
  than the previous tag's.
- `sh tests/run.sh` (includes the node-gated views runtime test, which
  skips without node).
- `docker build -q -t tt-ucode-gate -f tests/backend/Dockerfile
  tests/backend` (the contract-test lab image), then
  `sh tests/backend/test_backend_contract.sh` and
  `sh tests/install-harness.sh` — a skip (exit 77) passes the step.
- `node tests/view-contract.js` — the RPC-surface and DIAG_TEXT gate.
- `sh tests/gui/run.sh` — the Playwright GUI suite; a skip (exit 77)
  passes the step.
- Shellcheck (pinned `koalaman/shellcheck:v0.11.0`, `-s sh
  --severity=error`) over the explicit file list — every shipped script
  and test harness file, a missing file fails the step:
  `docker run --rm -v "$PWD:/src" -w /src koalaman/shellcheck:v0.11.0 -s sh --severity=error <files>`
- `sh -n` on the init script.
- ucode gates: every used module function is imported; the file compiles
  under ucode v0.0.20250529 (built with fs+math only) — see the CI recipe
  for the exact cmake flags; the compiler must also REJECT a broken file
  (negative control).
- All JSON under `packages/` must parse (menu/acl).
- Views: every used LuCI module (`ui dom rpc uci form view poll fs network
  validation`) must be declared with `'require <mod>'`; each view must
  parse as JS via `node vm.Script` (views end in a top-level `return`, so
  they are wrapped in a function expression).

Separate from ci.yml, `.github/workflows/integration.yml` runs the
dockerized end-to-end suite on PRs, main pushes and manual dispatch: a
matrix job builds this tree's packages with the pinned SDKs (with the
`restricted-feeds.sh --verify` gate against the SDK image's
`feeds.conf.default`), then one job per package manager runs
`tests/integration/run.sh` against the built repositories. It is its own
workflow on purpose — the SDK builds are the slow part, and the fast
contract gates must not wait for them. The release pipeline reuses the
same harness against the release's own artifacts.

## Release pipeline (`.github/workflows/release.yml`)

Triggered by `v*` tag pushes (also builds a GitHub release) and
`workflow_dispatch` (repos + site only; plain branch CI never publishes).

- `build` — `luci-app-trusttunnel` via `openwrt/gh-action-sdk@v7` on
  25.12.5 (apk) and 22.03.7 (ipk). The SDK is pinned with `VERSION_PATH`
  to the release tarballs — **never the snapshot SDK** (snapshot feeds hit
  a curl Kconfig recursive dependency) — and the SDK feeds are restricted
  to the needed set via `tests/integration/restricted-feeds.sh`, whose
  `--verify` gate checks the hardcoded pins against the SDK image's
  `feeds.conf.default` (update them together with the SDK bump).
  `FEED_DIR` must be an absolute path and must contain `.git` (luci.mk
  findrev derives the version from it). `fail-fast: false`; artifact file
  names must match the tag.
- `build-client` — the client package per subtarget arch (the full matrix
  is in the workflow; the ipk list is the apk list minus
  `aarch64_cortex-a76`). apk files get an `-<arch>` suffix and an
  `ARCH-<arch>` marker for repository assembly; ipk names already carry
  the arch. A row first checks whether the same version is already
  published and reuses it when the recipe matches — a copy of the client
  Makefile travels at each release tree's root
  (`releases/<version>/trusttunnel-client.Makefile`, one per tree, never
  inside the feed directories) for exactly that diff, so a recipe change
  without a version bump still forces a rebuild.
- `verify-integration` — the same `tests/integration/run.sh` harness the
  PR workflow runs, executed against the packages THIS pipeline just
  built (no SDK rebuild; the release's own x86-64 artifacts are consumed
  directly). `publish-repo` waits for it, so only a behaviorally tested
  release ships.
- `publish-repo` — downloads the artifacts plus every prior release's
  packages via `gh release download` (only the current package set is
  merged: the early `-lite` releases and the dropped i18n packages are
  filtered out, and an ipk-less first release is skipped, not failed),
  assembles:
  - per-arch signed repositories in the official OpenWrt layout —
    `releases/<version>/packages/<arch>/trusttunnel/` on the site, one
    release tree per package-manager era (the tree segment is the
    OpenWrt release the packages were built against: `25.12.5` for apk,
    `22.03.7` for opkg — bump together with the SDK pins, and with the
    `TT_REPO_APK_RELEASE`/`TT_REPO_OPKG_RELEASE` constants in
    install.sh), each holding per-arch feed directories with the apk
    index (`apk mkndx --allow-untrusted` + `apk adbsign` with
    `secrets.TT_APK_SIGN_KEY`) or the opkg index, the public keys and
    every released version of the packages. Cumulative: prior client
    packages are placed by their `-<arch>` asset suffix (apk) or their
    `_<arch>` name segment (ipk), and prior noarch LuCI packages land in
    every feed dir, so every released version stays installable — but a
    prior client is merged only when its version equals the current
    build's (the package managers install the highest version, and an
    old client must not shadow the pinned one),
  - per-arch opkg feeds (`ipkg-make-index.sh` fetched from openwrt-22.03,
    run once per feed directory, manifest fields stripped, gzip,
    `usign -S` with `secrets.TT_OPKG_SIGN_KEY`; the signature covers the
    UNCOMPRESSED `Packages`). The two-empty-line padding works around
    usign's SHA-512 size bug — keep it. The feeds index the prior ipks
    too (same client version filter). The arch/version derivation from
    the ipk file names is shared with the integration harness
    (`tests/integration/ipk-arch.sh`, sourced by both) and pinned by the
    harness's `archparse` stage — the arch names contain underscores, and
    a last-underscore split once clipped `mipsel_24kc` to `24kc`.
  - verification: installs the built repos into fresh rootfs containers
    exactly as `install.sh` sets them up (25.12.0 apk; 23.05.6 and 24.10.8
    opkg) and runs the client `--version`.
  - GitHub release upload (tag pushes only, single writer).
  - GitHub Pages site assembly: `repo-site/` templates + generated index
    pages — the releases index and the per-tree pages (each tree page
    lists its architectures, linking straight to the feed pages), the
    per-feed pages list what their directories actually hold, and the
    two structural levels in between (`packages/`,
    `packages/<arch>/`) are one-line redirect stubs (`_layouts/
    redirect.html`), so browsing takes three clicks with no URL 404ing
    (`sed r` substitutions must keep file-read and delete on separate
    lines), rendered with Jekyll, deployed via Pages (`permissions:
    contents, pages, id-token`).

Repositories are served from the Pages site, not from release assets:
release assets are per-tag snapshots, while the repositories accumulate
every prior release (the "keep every prior release installable"
contract), and Pages serves the files byte-identically, which the
package managers rely on. No branch ever holds packages.

## Conventions and invariants

- **Shell**: POSIX `/bin/sh` everywhere, shellcheck-clean at error
  severity. Use `set -u` where safe — never in `uci-export` (see above).
  Keep the explanatory header comments; this codebase documents contracts
  in comments and in test headers, and the CI gates treat several of those
  as the specification.
- **Line endings**: LF is enforced for all text via `.gitattributes`
  (CRLF in a script breaks `/bin/sh\r` on the router).
- **Commits**: lowercase `area: description` style
  (`docs:`, `release:`, `fix:`, `cleanup:`, `backend:`, `service:`,
  `tests:`, `makefile:`, `gen-config:`, …). The subject is a single
  line, short (under 72 chars), imperative and without a trailing
  period. One concern per commit — a subject that joins several
  concerns (for example with a semicolon) signals a commit that must
  be split. A body is optional; when present, wrap it at 72 chars,
  explain what changed and why, and do not prefix paragraphs with
  file names. Merged to `main` via PRs; feature work happens on
  branches.
- **i18n**: the interface is English-only — no translation package is
  built or installed. New user-visible strings in views still use `_()`,
  and backend strings shown in the Diagnostics view go through the
  `DIAG_TEXT` map in `diagnostics.js`. The Russian translations are
  parked in the separate translations repository for later
  reintroduction.
- **Hardcoded paths** (keep consistent): `/etc/config/trusttunnel`,
  `/etc/init.d/trusttunnel`, `/opt/trusttunnel_client`,
  `/usr/libexec/trusttunnel/{uci-export,gen-config,routing,records.sh}`,
  `/var/etc/trusttunnel/{settings.tsv,client.toml,endpoint.pem,device}`,
  `/etc/uci-defaults/40-luci-trusttunnel`,
  `/etc/hotplug.d/net/40-trusttunnel`. Kernel constants: fwmark `0x9527`,
  table `880`, rule priority `30820`, blackhole metric `1000`.
- **Scope**: the package must not touch dnsmasq, `https-dns-proxy`, cron,
  or anything beyond the listed files (`uninstall.sh` only cleans their
  leftovers from earlier versions of the package). Do not add such touches.
- **Killswitch**: the generated config keeps the client's own killswitch
  off (`killswitch_enabled = false`); the routing table blackhole is the
  killswitch. `change_system_dns = false` — DNS is never intercepted.
- **Keys**: `key-build.pub` / `opkg-key.pub` are public; never commit
  private keys. Repo signing keys rotate — run `install.sh` again on a
  router to refresh them.
- **Version discipline**: `PKG_VERSION` fallback in the app Makefile must
  equal the last released version; tags drive release contents; the CI
  rejects tags older than the previous tag and packages that do not match
  the tag.
- **Do not rebuild goldens casually**: backend behavior changes require
  updating the golden set in `tests/backend/goldens/` and its `healthy/`
  and proxy-mode variants, and the `driver.uc` normalizations must stay
  in sync.

## Typical tasks

- **Change a setting end-to-end**: UCI option in
  `root/etc/config/trusttunnel` → `uci-export` schema (30-key contract,
  see its header and `schema-keys:` comments) → `gen-config` emission →
  init script `change_class` mapping → settings.js field (+ validation)
  → records fixtures/tests → goldens if the backend surfaces it.
- **Verify a shell change**: `sh tests/run.sh`, targeted test
  (`sh tests/test_gen_config.sh` etc.), then shellcheck as in CI.
- **Verify a backend change**: `sh tests/backend/test_backend_contract.sh`
  (build the `tt-ucode-gate` image first if missing), plus the ucode
  import/compile gates from ci.yml.
- **Release**: bump client vendor version/hashes if needed, ensure the
  Makefile fallback equals the previous release, tag `vX.Y.Z` (tag must
  point to a commit newer than the previous tag), push; the release
  workflow builds, signs, verifies and publishes.
