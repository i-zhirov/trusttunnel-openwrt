# Integration test suite for trusttunnel-openwrt — implementation plan

Status: proposed (exploration complete, key mechanisms verified experimentally)
Branch: `integration-tests`

## 1. Goal

Add a CI-run integration test suite that, end to end and in Docker:

1. **installs the project as intended** — runs the real `install.sh` inside a
   dockerized OpenWrt system (the official `openwrt/rootfs` image), pointed
   at a repository served from a local HTTP container (the `TT_REPO_URL`
   override), with packages actually built from this tree;
2. **configures it using the provided system tools** — `uci` for the network
   and the `trusttunnel` config, `/etc/init.d/network`, `/etc/init.d/trusttunnel
   enable|start|status|stop|restart`, the firewall, `logread`;
3. **checks the connection against a specially prepared TrustTunnel endpoint
   running side by side in Docker** — the vendor's `trusttunnel_endpoint`
   binary (pinned release, static build) with a self-signed certificate, in a
   sibling container on the same docker network, and verifies that marked
   traffic really flows through the tunnel (target server sees the
   endpoint's IP, not the router's), that private-range traffic stays
   direct, and that the blackhole killswitch swallows marked traffic when
   the tunnel is down.

The suite must be locally runnable (`sh tests/integration/run.sh`, docker
optional → skip 77), must follow the repository's test conventions, and must
be wired into CI as its own workflow so the fast contract gates in `ci.yml`
stay fast.

## 2. What this adds on top of the existing tests

| Existing gate | What it proves | What it does NOT prove |
|---|---|---|
| `tests/install-harness.sh` | install.sh control flow with **stubbed** apk/opkg/wget/usign | that the real packages install, that the repo serves them, that the client binary runs |
| `tests/backend/*` contract test | rpcd backend responses byte-match goldens | nothing about real kernel state |
| `tests/test_*.sh` unit tests | scripts' pure-shell logic with stubbed ip/nft/uci | nothing end-to-end |
| `release.yml` verify steps | the **published** repo installs into fresh rootfs containers | the current tree, the full install.sh flow, the service actually connecting |

The integration suite closes the gap: real install → real config → real
tunnel → real traffic, against the tree under test.

## 3. Feasibility — everything below was verified experimentally

All mechanisms were exercised for real on this machine (Docker Desktop,
macOS) before this plan was written. Container images:
`openwrt/rootfs:x86-64-25.12.0` (apk) and `x86-64-22.03.7` (opkg); endpoint
binary: `trusttunnel-v1.1.0-linux-x86_64.tar.gz` (static-pie, runs on
alpine); client binary: `trusttunnel_client-v1.1.5-linux-x86_64.tar.gz`
(the exact version the package ships, static).

| # | Claim | Verified |
|---|---|---|
| 1 | `openwrt/rootfs` containers boot with procd, uci, nft, busybox ip, nslookup, logread, usign, wget; apk (25.12) / opkg (22.03); **no curl** (installed by install.sh) | `command -v` sweep in both images |
| 2 | Docker networking works out of the box (eth0 gets an address + default route + resolv.conf) | booted with `sleep`; `ip addr/route` |
| 3 | With `/sbin/init` (real boot), netifd bridges eth0 into `br-lan` with the default 192.168.1.1 lan config and **breaks** docker connectivity (ARP fails) | observed; fixed by configuring `network.lan` to use eth0 directly with static IP/gateway via uci — a realistic "configure with system tools" step |
| 4 | `--cap-add NET_ADMIN --device /dev/net/tun` is enough: the vendor client creates `tun0` with carrier 1 in the container | ran `trusttunnel_client -c client.toml` (exact gen-config TOML layout) in the router container |
| 5 | The client accepts the exact TOML that `gen-config` emits, including the pinned-certificate literal (`certificate = '''…'''`) | client log: `Device tun0 opened`, carrier 1 |
| 6 | The endpoint binary runs in a plain alpine container with hand-written `vpn.toml` / `hosts.toml` / `credentials.toml`; `vpn.toml` **requires** a `[listen_protocols]` block (http1/http2/quic) | endpoint started, `Listening to TCP/UDP 0.0.0.0:8443` |
| 7 | Client ↔ endpoint TLS works with a self-signed cert for a fake hostname (`tt.test`) using `skip_verification=1`; `VPN_SS_CONNECTED` | client + endpoint logs |
| 8 | The package's routing approach works in-container: nft output-chain marking (`meta mark set 0x9527`, private + endpoint ranges `return`), `ip rule fwmark → table 880`, `ip route default dev tun0 table 880`; marked router-originated traffic to a target on the lab net returns with **the endpoint's IP as source** (proves the full loop: router → tun0 → endpoint → target) | `REMOTE_ADDR=44.55.66.20` from the router's curl |
| 9 | Private-range destinations are **not** marked and stay direct (target sees the router's own IP) | `REMOTE_ADDR=172.17.0.3` for a target on the docker default bridge |
| 10 | Blackhole killswitch: with the client killed and the tun device down, marked traffic is swallowed (curl fails) while direct traffic still works | curl rc≠0 through tunnel path, direct OK |
| 11 | Clean `stop` tears the routing down (rule/table/nft gone) and traffic goes direct — documented behavior | `routing status` after stop |
| 12 | Endpoint-down behavior with the client alive is **state-dependent** (client keeps the device up with carrier 1, `killswitch_enabled=false`; observed both dropped and direct-fallback windows depending on its recovery state) | two experiments, different outcomes; see §9 risk + §7.4 |
| 13 | The procd service path works in the init-booted container: `/etc/init.d/trusttunnel start` → procd instance → client, routing status `device up / rule present / table present / nft present`, hotplug reattach | full manual package-file install + `enable/start` |
| 14 | Hermetic apk repository signing: apk v3 index can be signed with a **fresh EC P-256 key** (`openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256` — the same key type as the committed `key-build.pub`), via `apk mkndx --allow-untrusted` + `apk adbsign --sign-key` in the pinned `alpine:edge@sha256:266f…` container; installs into the rootfs with the pubkey under `/etc/apk/keys/` | `apk update` + `apk add` from `file://` repo — OK |
| 15 | opkg repository: the release.yml recipe (ipkg-make-index.sh + usign) is reusable with a fresh `usign -G` keypair | release.yml verified in production; usign present in both rootfs images |
| 16 | `install.sh` honors `TT_REPO_URL` and fetches the signing keys from the repo server (`/apk/key-build.pub`, `/opkg/opkg-key.pub`) | install.sh source + install-harness scenarios |
| 17 | Docker Desktop (macOS) only mounts paths under `$HOME` — the harness scratch dir must live there (already the `tests/install-harness.sh` convention) | mount appeared empty under `/var/folders` |
| 18 | Busybox `wget` reports odd errors (`Operation not permitted`) for several failure modes; use `curl` (installed by install.sh anyway) or `wget -4` in assertions | observed |

## 4. Discovered during exploration: a real bug the suite will catch

**Pinned certificates never reach the client.** The init script writes the
pinned certificate to `/var/etc/trusttunnel/endpoint.pem` but then calls
`gen-config "$RECORDS" "$_cert"` passing the certificate **content** as the
second argument, while `gen-config` treats argument 2 as a **file path**
(`[ -s "$2" ]`, `awk 1 "$2"`). Result: with a pinned cert configured, the
generated `client.toml` contains `certificate = ""` (verified live), the pin
is silently dropped, and the client falls back to the system trust store.
Calling `gen-config` with the pem **path** emits the `certificate = '''…'''`
block correctly (verified).

**Fix (prerequisite for the suite, Phase 0 — DONE):**
```sh
# /etc/init.d/trusttunnel, regenerate()
_cert=$(uci -q get trusttunnel.endpoint.certificate)
_cert_pem=""
if [ -n "$_cert" ]; then
    printf '%s\n' "$_cert" > "$OUTDIR/endpoint.pem"
    chmod 600 "$OUTDIR/endpoint.pem"
    # gen-config takes the pem FILE PATH, not the content: the
    # certificate is multi-line (never a record value) and is read
    # back from the file written just above.
    _cert_pem="$OUTDIR/endpoint.pem"
else
    rm -f "$OUTDIR/endpoint.pem"
fi

if [ -n "$_cert_pem" ]; then
    if ! "$LIBDIR/gen-config" "$RECORDS" "$_cert_pem" > "$OUTDIR/client.toml"; then
        return 1
    fi
else
    if ! "$LIBDIR/gen-config" "$RECORDS" > "$OUTDIR/client.toml"; then
        return 1
    fi
fi
```
Regression test: new `tests/test_init_regenerate.sh` runs the **real**
`regenerate()` (test_init_reload.sh stubs it on purpose) against logging
stubs for `uci` / `uci-export` / `gen-config` — 17 assertions covering the
pinned path, the unpinned path, clearing a pin and the two failure paths.
Verified: the test fails 4 ways against the pre-fix code (negative control)
and passes with the fix; the whole unit suite, the install harness and the
backend contract test stay green; shellcheck is clean.

## 5. Topology

```
                     ┌────────────── docker network: tt-lab (44.55.66.0/24) ──────────────┐
                     │                                                                    │
   repo server ──────┤  (python http.server, serves the built+locally-signed repo)        │
   44.55.66.10       │                                                                    │
                     │                                                                    │
   endpoint ─────────┤  (alpine + pinned trusttunnel_endpoint v1.1.0, self-signed         │
   44.55.66.20       │   cert for tt.test, allow_private_network_connections = true,      │
                     │   listens TCP+UDP 8443)                                            │
                     │                                                                    │
   router ───────────┤  (openwrt/rootfs:x86-64-25.12.0 or -22.03.7, /sbin/init,           │
   44.55.66.30       │   --cap-add NET_ADMIN --device /dev/net/tun)                       │
                     │    eth0 = lan, static 44.55.66.30/24, gw 44.55.66.1                │
                     │    install.sh + uci + /etc/init.d/trusttunnel                      │
                     │    nft mark → table 880 → tun0 → endpoint                          │
                     │                                                                    │
   target ───────────┤  (python whoami server: replies with REMOTE_ADDR)                  │
   44.55.66.40       │                                                                    │
                     └────────────────────────────────────────────────────────────────────┘

   router also on the docker default bridge (172.17.0.0/16, private):
   direct target ──── (python whoami server; only reachable directly, never tunneled)
```

Why this exact shape:

- **Lab subnet must look public.** The router's nft ruleset refuses to mark
  private ranges, and the endpoint refuses to dial documentation/private
  ranges (`allow_private_network_connections=false` → `resolved address in
  non-routable network` for e.g. 203.0.113.0/24). The suite sets
  `allow_private_network_connections = true` on the endpoint (test-lab only)
  and uses a globally-shaped subnet (44.55.66.0/24) that the router *does*
  mark. 44.55.66.0/24 is a real allocated block, not in the endpoint's
  non-routable list, and docker accepts it as a bridge subnet.
- **The whoami target is the oracle.** Through-tunnel requests arrive with
  the endpoint's IP as source; direct requests with the router's own IP. One
  tiny HTTP server, two assertions, no internet dependency.
- **The direct target sits on a private subnet** so the router never marks
  it — it proves the direct path is untouched by the tunnel.
- **Router boots with `/sbin/init`** so procd, netifd, fw4 and logread are
  real (uci-defaults, firewall zone, service management all behave like on a
  device). The one required configuration step — point `network.lan` at eth0
  with a static address — is performed with the router's own tools.

## 6. The flow the harness runs (per PM variant)

```
1  preflight          docker present, /dev/net/tun present (mknod fallback),
                      scratch dir under $HOME (Docker Desktop sharing)
2  repo               build (CI: openwrt SDK; local: TT_REPO_DIR), assemble
                      apk/opkg layout, sign with a FRESH keypair, serve via
                      python http.server container; health-check the index
                      URL from the router container
3  endpoint           download pinned vendor tarball (hash-checked), write
                      vpn.toml / hosts.toml / credentials.toml / self-signed
                      cert, run in alpine container; health-check :8443
4  targets            whoami server on tt-lab + whoami server on the default
                      bridge (private)
5  router             openwrt/rootfs with /sbin/init, NET_ADMIN, /dev/net/tun
6  router network     uci set network.lan.device=eth0, static IP/gw/dns;
                      uci commit network; /etc/init.d/network restart;
                      assert gateway ping + docker DNS resolution
7  install            TT_REPO_URL=http://44.55.66.10 sh -s install.sh
                      (fetched from the repo server, exactly as the README
                       documents for real devices)
8  install asserts    exit 0; apk info -e / opkg list-installed for
                      luci-app-trusttunnel, luci-i18n-trusttunnel-ru,
                      trusttunnel-client; /opt/trusttunnel_client binary
                      runs (--version); /etc/config/trusttunnel seeded:
                      Default routing profile, firewall trusttunnel zone +
                      lan→trusttunnel forwarding, rc.d link enabled
9  configure          uci set trusttunnel.endpoint.* (hostname tt.test,
                      address 44.55.66.20:8443, creds, pinned certificate),
                      routing_profile Default, network.lan_devices=eth0,
                      network.include_router_traffic=1, main.enabled=1;
                      uci commit trusttunnel
10 service            /etc/init.d/trusttunnel enable && start
11 connect asserts    poll ≤ 60 s for: service running; tun0 + carrier 1;
                      routing status all green; client log
                      "Successfully connected to endpoint"
12 traffic asserts    curl http://44.55.66.40:8080/ → REMOTE_ADDR=44.55.66.20
                      (through tunnel); curl http://172.17.0.x:8080/ →
                      REMOTE_ADDR=<router IP> (direct, untouched)
13 killswitch asserts ip route get <target> mark 0x9527 → dev tun0 (up) and
                      → blackhole (after routing up + device down);
                      stop → routing torn down, direct traffic still works
14 idempotence        rerun install.sh (exit 0, no duplicate feed lines);
                      /etc/init.d/trusttunnel reload (noop);
                      rerun /etc/uci-defaults/40-luci-trusttunnel (no dupes)
15 teardown           containers + network removed (TT_KEEP to debug);
                      on failure: dump logread, client log, endpoint log,
                      routing status into a logs/ dir for the CI artifact
```

## 7. Test matrix and assertions

### 7.1 Matrix, phase 1 (both run in CI, both locally)

| Variant | Router image | PM | Installer branch | SDK build |
|---|---|---|---|---|
| apk | `openwrt/rootfs:x86-64-25.12.0` | apk | 25.12+ | `releases/25.12.5`, x86-64 |
| opkg | `openwrt/rootfs:x86-64-22.03.7` | opkg | 22.03–24.10 | `releases/22.03.7`, x86-64 |

Protocol: `http2` (default) in phase 1.

### 7.2 Matrix, phase 2 (cheap extensions, listed for later)

- `upstream_protocol=http3` scenario (QUIC path; endpoint already listens UDP 8443).
- opkg on `openwrt/rootfs:x86-64-23.05.6` and `x86-64-24.10.8` (same opkg branch, extra images).
- Routing-profile scenario: a Bypass profile whose `vpn_rules` contain the target — assert `vpn_mode = "selective"` in client.toml and the generated `exclusions`; a VPN profile with `bypass_rules` — assert `vpn_mode = "general"` and the exclusions. (Rule enforcement on live traffic is client-internal; assert config + client log.)
- Uninstaller round trip (`uninstall.sh -y`): packages gone, feed/keys gone, kernel leftovers reported.

### 7.3 The assertion contract (each is an explicit assert_* in the harness)

| # | Assertion | Level |
|---|---|---|
| A1 | install.sh exits 0 and prints the closing banner | install |
| A2 | package managers report the three packages installed (incl. i18n) | install |
| A3 | `/opt/trusttunnel_client/trusttunnel_client --version` prints the pinned version | install |
| A4 | `/etc/config/trusttunnel` seeded: Default profile, `endpoint.routing_profile=Default` | install |
| A5 | firewall zone `trusttunnel` (bound to `tun+`) and `lan → trusttunnel` forwarding exist; `/etc/init.d/firewall reload` runs clean | install |
| A6 | service is registered (`/etc/rc.d/` link) but not started by a fresh install | install |
| A7 | service starts; `running` reports true; procd instance alive | service |
| A8 | tun0 exists with carrier 1; `routing status` reports device/rule/table/nft present | kernel |
| A9 | client log contains "Successfully connected to endpoint" | connect |
| A10 | generated `client.toml` contains the pinned certificate block, `killswitch_enabled = false`, `change_system_dns = false` | config |
| A11 | through-tunnel traffic: curl to the target returns `REMOTE_ADDR=<endpoint IP>` | traffic |
| A12 | direct traffic: curl to the private target returns `REMOTE_ADDR=<router IP>` | traffic |
| A13 | `ip route get <target> mark 0x9527` resolves via tun0 while up, via blackhole with the device down | killswitch |
| A14 | clean stop: rule/table/nft removed; direct traffic still works; start restores everything | lifecycle |
| A15 | install.sh rerun is idempotent (single feed line, exit 0); uci-defaults rerun creates no duplicates; `reload` is a noop when nothing changed | idempotence |
| A16 | the endpoint log shows the CONNECT for the tunneled target (diagnostics value) | traffic |

Phase 2 additions: A17 http3 end-to-end; A18 bypass/vpn profile config assertions; A19 uninstaller round trip.

### 7.4 Deliberately NOT asserted in phase 1

- **Endpoint-down behavior with the client alive.** The generated config sets
  `killswitch_enabled = false` (routing-table killswitch by design); the
  client keeps the tun device up with carrier 1 while recovering and its
  recovery-state behavior was observed to vary (dropped vs. direct-fallback
  windows). This is a product-behavior question, not a harness one; pin it
  as a snapshot test in phase 2 after deciding the intended semantics (and
  possibly filing an upstream issue). The *deterministic* killswitch (device
  down → blackhole) IS asserted (A13).
- **The update check / versions** (needs GitHub API; out of scope).
- **LuCI UI rendering** (no browser in the suite; the backend contract test
  covers the RPC surface).

## 8. CI wiring

New workflow `.github/workflows/integration.yml` (kept separate from
`ci.yml` so the fast contract gates stay fast; the release workflow stays
the single publisher).

```yaml
name: integration
on:
  workflow_dispatch:
  push: { branches: [ main ] }
  pull_request:
  # (optional later) schedule — nightly smoke

jobs:
  build-repo:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { version: 22.03.7, ext: ipk }
          - { version: 25.12.5, ext: apk }
    steps:
      - checkout (full history — luci.mk findrev derives the version)
      - mkdir -p out
      - openwrt/gh-action-sdk@v7        # exactly as release.yml:
        env: { VERSION_PATH: "releases/${{ matrix.version }}",
               ARCH: "x86-64-${{ matrix.version }}",
               FEEDNAME: ttowrt, FEED_DIR: ${{ github.workspace }},
               ARTIFACTS_DIR: ${{ github.workspace }}/out,
               PACKAGES: luci-app-trusttunnel }
      - collect dist/ (luci-app, luci-i18n, trusttunnel-client) + ARCH marker
      - upload artifact repo-${{ matrix.version }}

  integration:
    needs: build-repo
    runs-on: ubuntu-latest
    steps:
      - checkout
      - preflight /dev/net/tun:
          ls -la /dev/net/tun || { sudo mknod -m 666 /dev/net/tun c 10 200;
                                    sudo modprobe tun || true; }
      - download both artifacts into tests/integration/scratch/repo-*
      - for pm in apk opkg:
          TT_PM=$pm TT_REPO_DIR=scratch/repo-* sh tests/integration/run.sh
            # on failure: upload tests/integration/scratch/logs/* as an artifact
```

Notes:

- The SDK build is the slow part (≈5 min per variant, as in release.yml); a
  PR trigger is acceptable but can be made path-filtered or label-gated
  later if the cost bites.
- The harness itself never needs the private signing keys: it generates a
  fresh EC P-256 key (apk) / usign key (opkg) per run and serves the public
  half — which also exercises install.sh's key-distribution path.
- The pinned `alpine:edge@sha256:266f…` image from release.yml is reused for
  `apk mkndx`/`adbsign`; the opkg index recipe (ipkg-make-index.sh + usign,
  including the two-line padding workaround) is copied from release.yml.
  Later refactor option: extract the repo-assembly steps of release.yml into
  a shared script both workflows call.

## 9. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `/dev/net/tun` missing on a GitHub runner host | low–medium | preflight + `mknod` + `modprobe tun` fallback; the module is in the default runner kernel; verified working on Docker Desktop's Linux VM |
| Vendor endpoint/client release changes (URLs, config schema) | medium over time | pin exact versions (server v1.1.0, client v1.1.5 = what the package ships) + SHA-256 of the tarballs in the harness; version constants at the top of `run.sh` |
| SDK build cost on PRs | medium | separate workflow; optional path/label gating later; results cached via the standard action behavior |
| Endpoint-down behavior varies with client recovery state (A-note) | certain | excluded from phase-1 assertions; snapshot test in phase 2 after the semantics are decided |
| "Connected" waits flake on slow runners | medium | poll-based waits with generous timeouts (60 s), retry the traffic assertions once |
| docker bridge subnet collision on a runner | low | configurable `TT_LAB_SUBNET` (default 44.55.66.0/24); the harness probes for an unused range |
| Docker Desktop path-sharing (macOS) | certain | scratch dir under `$HOME` (existing install-harness convention); CI runs on Linux where /tmp is fine |
| OpenWrt default repos unreachable at install time (apk/opkg update) | low in CI | documented; CI runners have internet; the assertion A2 would fail loudly |
| apk index signing drift (apk-tools versions) | low | reuse the exact pinned alpine:edge digest release.yml already uses; the whole sign→install loop was verified |
| Busybox wget quirks in assertions | certain | use `curl` (installed by install.sh) for traffic checks; `wget -4` only where curl is absent |

## 10. Files to add / change

```
NEW  .github/workflows/integration.yml        CI wiring (build-repo + integration jobs)
NEW  tests/integration/run.sh                 the harness (docker-gated, TT_* overrides,
                                              assert_* helpers mirroring tests/lib.sh,
                                              exit 77 without docker)
NEW  tests/integration/lib.sh                 scenario runner helpers (or reuse tests/lib.sh)
NEW  tests/integration/fixtures/vpn.toml      endpoint main settings (listen_protocols,
                                              allow_private_network_connections=true)
NEW  tests/integration/fixtures/hosts.toml    main_hosts tt.test + cert paths
NEW  tests/integration/fixtures/credentials.toml  one test user
NEW  tests/integration/fixtures/whoami.py     REMOTE_ADDR HTTP oracle
NEW  tests/integration/fixtures/network.uci   the router network configuration snippet
NEW  tests/integration/README.md              how to run locally (TT_REPO_DIR, TT_PM, TT_KEEP)
FIX  packages/luci-app-trusttunnel/root/etc/init.d/trusttunnel
                                             regenerate(): pass the endpoint.pem PATH to
                                             gen-config (Phase 0 — DONE, §4)
NEW  tests/test_init_regenerate.sh           regression for the pinned-cert path
                                             (Phase 0 — DONE, §4)
EDIT ci.yml                                  shellcheck list += tests/test_init_regenerate.sh
                                             (Phase 0 — DONE)
EDIT AGENTS.md / README.md                    document the suite and how to run it
```

## 11. Implementation order

| Phase | Work | Done when |
|---|---|---|
| 0 | Fix the pinned-cert bug (§4) + unit regression | **DONE** — `sh tests/run.sh` green; `client.toml` contains the cert block; negative control verified; install harness + backend contract test + shellcheck green |
| 1 | Repo assembly + signing helpers (apk + opkg) in the harness; serve + install into a scratch router container; install-side assertions A1–A6 | harness install stage green locally (apk variant) |
| 2 | Endpoint + target containers; full connect + traffic flow; assertions A7–A12 | harness green end to end (apk variant, http2) |
| 3 | Killswitch/lifecycle/idempotence assertions A13–A16; opkg variant; `TT_FILTER`/`TT_KEEP`; failure log dumps | both variants green locally |
| 4 | `integration.yml`; /dev/net/tun preflight; artifact upload of logs on failure; PR run passes | CI green on a PR |
| 5 | Phase-2 matrix (§7.2): http3, extra opkg images, profile scenarios, uninstaller round trip | optional, incremental |
| 6 | Docs: AGENTS.md/README section; shellcheck wiring | docs match the suite |

## 12. Out of scope

- LuCI UI/browser testing (backend contract test covers RPC; views have
  syntax/require gates in ci.yml).
- Multi-architecture builds in the integration job (x86_64 only; the arch
  matrix is the release pipeline's job).
- The endpoint-down semantic decision (§7.4) — flagged for a product-level
  decision, then snapshotted.
- Replacing the existing unit tests, the install harness, or the release
  verification — the suite complements all three.
