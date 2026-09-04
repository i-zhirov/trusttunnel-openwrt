# AGENTS.md — trusttunnel-openwrt

Guidance for AI agents and human contributors working in this repository.

## What this project is

`trusttunnel-openwrt` is an independent implementation of an OpenWrt package
set for the [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) client:

- `luci-app-trusttunnel` — a noarch LuCI application: a procd service, a
  UCI-backed config, an rpcd ucode backend, three LuCI views, a Russian
  translation, plus firewall/routing integration.
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
      settings.js status.js diagnostics.js   LuCI client-side views
    po/ru/trusttunnel.po      Russian translation (msgid/msgstr)
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
.github/workflows/ci.yml      CI gates (test + lint + contract checks)
.github/workflows/release.yml Release pipeline (build, sign, verify, publish)
key-build.pub, opkg-key.pub   PUBLIC halves of the repo signing keys (committed)
LICENSE                       Apache-2.0
```

There is no `docs/` directory; user documentation lives in `README.md` and
is tracked in the root on purpose (see `.gitignore` comment). The private
halves of the signing keys are GitHub secrets, never committed.

## Core architecture: the data flow

Everything on the router is driven by one UCI config, one derived TSV file,
one generated client config, and one routing helper. The chain is:

```
/etc/config/trusttunnel            (UCI: main, endpoint, network,
        |                               routing_profile*, domains)
        | uci-export                (dumps 26 fixed keys to TSV)
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
key set — **26 keys, fixed order** — is a hard contract shared by
`records.sh`, `gen-config`, the `routing` helper, the init script's change
classifier and the ucode backend's `records()` parser. Nothing outside the
schema ever appears in the file (foreign UCI sections must not leak), and
`endpoint.certificate` is deliberately NOT exported (multi-line PEM; it is
written separately to `endpoint.pem` by the init script).

`uci-export` must never gain `set -u`: `/lib/functions.sh` reads
uninitialized variables and dies under it.

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
- `attach`: point table 880's default route at the client tun device
  (metric 1) and record the device name in `$OUT_DIR/device`.
- `down`: remove everything; the client's device is never deleted.
- Overrides for tests: `TT_IP`, `TT_NFT`, `TT_LIBDIR`.

### Service lifecycle (`/etc/init.d/trusttunnel`)

procd service, `USE_PROCD=1`, `START=95`, `STOP=10`. Notable behaviors:

- `start_service` checks `main.enabled`, the client binary, the trust
  store, regenerates records + config, waits for a default route and for
  the clock to catch up, runs `routing up`, then starts the client with
  `procd` and attaches an already-existing tun device.
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
bypass rules), registers the rc.d link, drops the stale release cache and
clears LuCI caches. Idempotent; also run immediately by `install.sh`.

### rpcd backend (`/usr/share/rpcd/ucode/luci.trusttunnel`)

Exposes `luci.trusttunnel` RPC methods (the ACL grants read on
`status ping probe check_domain log versions diagnose` and write on
`service import_config`):

- `status` — service state, device, rule/table/nft flags, endpoint,
  routing profile and effective `vpn_mode`.
- `service` — start/stop/restart/reload with a post-start liveness probe.
- `ping` — ping each configured endpoint host (or a given target).
- `probe` — external IP through the tunnel vs. direct (curl + api.ipify.org).
- `check_domain` — verdict for one domain against the effective rules.
- `log` — last N logread lines filtered by `trusttunnel`.
- `diagnose` — the chain walk: config → prerequisites → service → kernel
  → network, each check `{group, label, status, detail, hint}`, plus
  counts and an overall verdict.
- `versions` — client/package versions vs. the GitHub latest-release API,
  cached in `/var/cache/trusttunnel/release.json` for `RELEASE_TTL` (21600s),
  with stale-cache fallback and `vercmp` (numeric, not string).
- `import_config` — feeds server config text or a `tt://` link to the
  vendor's `setup_wizard`, parses the produced settings and returns the
  endpoint fields; secrets go through `write_secret_tmp` (mode 0600).

Imports note: the backend imports `fs` and `math` module functions only.
`ci.yml` gates that every used module function is imported and that the
file compiles under the pinned ucode.

### LuCI views

- `status.js` — verdict banner, facts (state/mode/server), versions table
  with "Check now", Start/Stop/Restart buttons, client log; polls every 10s.
- `settings.js` — a single tabbed `form.Map` whose sections become tabs
  (General, Server, Routing profiles, Network), plus the Import… modal
  that calls `import_config` and applies results to pending UCI (nothing
  is written until Save & Apply).
- `diagnostics.js` — renders the diagnose checks grouped and ordered
  (config → prereq → service → kernel → network), problems first with a
  toggle for the rest, plus domain-check, ping and address-compare tools.
  Backend strings are translated through the `DIAG_TEXT` map; new
  backend strings must be added there (and to the .po) to be translatable.

## Packages and versioning

### `luci-app-trusttunnel/Makefile`

- `PKG_VERSION` comes from `git describe --tags --abbrev=0` (tag `vX.Y.Z`
  → version `X.Y.Z`), falling back to the last released version (currently
  `1.0.13`). The fallback must track the latest release — the release
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
  `PKG_VERSION:=1.1.5`). On a vendor release, bump `PKG_VERSION` and the
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
- `tests/test_hotplug.sh` — pure-shell scenario harness (no docker):
  sed-rewrites the script's hardcoded paths into a scratch tree, stubs
  init/routing/logger, and covers filters | guards | attach | invariants.
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

## CI gates (`.github/workflows/ci.yml`)

Every step is a contract gate; the tree must pass all of them. Locally
reproducible equivalents:

- Executable bits of shipped scripts must be `100755` in the index.
- Tag pushes must not regress the release: new tag's commit must be newer
  than the previous tag's.
- `sh tests/run.sh`.
- `docker build -q -t tt-ucode-gate -f tests/backend/Dockerfile
  tests/backend` (the contract-test lab image), then
  `sh tests/backend/test_backend_contract.sh` and
  `sh tests/install-harness.sh` — a skip (exit 77) passes the step.
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

## Release pipeline (`.github/workflows/release.yml`)

Triggered by `v*` tag pushes (also builds a GitHub release) and
`workflow_dispatch` (repos + site only; plain branch CI never publishes).

- `build` — `luci-app-trusttunnel` via `openwrt/gh-action-sdk@v7` on
  25.12.5 (apk) and 22.03.7 (ipk). The SDK is pinned with `VERSION_PATH`
  to the release tarballs — **never the snapshot SDK** (snapshot feeds hit
  a curl Kconfig recursive dependency). `FEED_DIR` must be an absolute
  path and must contain `.git` (luci.mk findrev derives the version from
  it). `fail-fast: false`; artifact file names must match the tag.
- `build-client` — the client package per subtarget arch (the full matrix
  is in the workflow; the ipk list is the apk list minus
  `aarch64_cortex-a76`). apk files get an `-<arch>` suffix and an
  `ARCH-<arch>` marker for repository assembly; ipk names already carry
  the arch.
- `publish-repo` — downloads the artifacts plus every prior release's
  packages via `gh release download` (only the current package set is
  merged: the early `-lite` releases and the dropped i18n packages are
  filtered out, and an ipk-less first release is skipped, not failed),
  assembles:
  - per-arch signed apk repositories (`apk mkndx --allow-untrusted` +
    `apk adbsign` with `secrets.TT_APK_SIGN_KEY`), cumulative: prior
    client apks are placed by their `-<arch>` asset suffix and prior
    noarch LuCI apks land in every arch dir, so every released version
    stays installable — but a prior client is merged only when its
    version equals the current build's (the package managers install
    the highest version, and an old client must not shadow the pinned
    one),
  - one merged opkg feed (`ipkg-make-index.sh` fetched from openwrt-22.03,
    manifest fields stripped, gzip, `usign -S` with
    `secrets.TT_OPKG_SIGN_KEY`; the signature covers the UNCOMPRESSED
    `Packages`). The two-empty-line padding works around usign's SHA-512
    size bug — keep it. The feed indexes the prior ipks too (same client
    version filter).
  - verification: installs the built repos into fresh rootfs containers
    exactly as `install.sh` sets them up (25.12.0 apk; 23.05.6 and 24.10.8
    opkg) and runs the client `--version`.
  - GitHub release upload (tag pushes only, single writer).
  - GitHub Pages site assembly: `repo-site/` templates + generated index
    pages (`sed r` substitutions must keep file-read and delete on
    separate lines), rendered with Jekyll, deployed via Pages
    (`permissions: contents, pages, id-token`).

Repositories are served from the Pages site, not from release assets: the
i18n package version contains `~`, which GitHub mangles in asset names,
while Pages serves files byte-identically. No branch ever holds packages.

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
  `tests:`, `makefile:`, `gen-config:`, …), one concern per commit,
  merged to `main` via PRs. Feature work happens on branches.
- **i18n**: new user-visible strings in views use `_()`; backend strings
  shown in the Diagnostics view go through the `DIAG_TEXT` map in
  `diagnostics.js`; add Russian translations to
  `po/ru/trusttunnel.po` (the `luci-i18n-trusttunnel-ru` package).
- **Hardcoded paths** (keep consistent): `/etc/config/trusttunnel`,
  `/etc/init.d/trusttunnel`, `/opt/trusttunnel_client`,
  `/usr/libexec/trusttunnel/{uci-export,gen-config,routing,records.sh}`,
  `/var/etc/trusttunnel/{settings.tsv,client.toml,endpoint.pem,device}`,
  `/var/cache/trusttunnel/release.json`, `/etc/uci-defaults/40-luci-trusttunnel`,
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
  variant, and the `driver.uc` normalizations must stay in sync.

## Typical tasks

- **Change a setting end-to-end**: UCI option in
  `root/etc/config/trusttunnel` → `uci-export` schema (26-key contract,
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
