# Integration harness (`tests/integration/`)

End-to-end suite that installs this project **as intended** into a
dockerized OpenWrt router, connects it to a real TrustTunnel endpoint
container, and verifies the traffic through the tunnel. The harness runs
the real `install.sh` against a locally assembled and signed package
repository, configures the router with its own tools (`uci`,
`/etc/init.d/*`), and asserts the install contract, the service contract
and the traffic contract.

## Running

```sh
sh tests/integration/build-sdk.sh          # build THIS tree's packages (one-time, ~15-30 min)
TT_PM=apk sh tests/integration/run.sh      # OpenWrt 25.12, apk
TT_PM=opkg sh tests/integration/run.sh     # OpenWrt 22.03, opkg
```

Both variants need docker and internet (install.sh updates the default
OpenWrt package repositories). Without docker the harness reports SKIP
(exit 77), like the other docker-gated tests. It is deliberately NOT
picked up by `tests/run.sh` (the runner globs `tests/test_*.sh`); CI runs
it as its own workflow.

### Where the packages come from

The harness prefers, in order:

1. `TT_REPO_DIR` — a flat dir of built packages (the CI artifact layout);
2. `dist/` — the output of `tests/integration/build-sdk.sh`, which builds
   `luci-app-trusttunnel` and `trusttunnel-client` from
   **this tree** with the OpenWrt SDK (the same recipe the release
   pipeline's SDK action uses);
3. the latest GitHub release (`TT_RELEASE_TAG` pins a specific one).

Tree-built packages matter: the published release can lag the tree, and a
stale package would fail the tunnel assertions for a reason unrelated to
the harness (the pinned-certificate fix is the first such case).

The repository itself is assembled per run with a **fresh** signing key
(EC P-256 for apk, usign for opkg) — the private key exists only in the
scratch directory and the served public key is what install.sh installs.

### What a run does

| Stage | What it verifies |
|---|---|
| `preflight` | docker, `/dev/net/tun` |
| `pkgs` | the two packages for the PM (luci-app + client), from TT_REPO_DIR / dist/ / release |
| `repo` | hermetic repo assembly + signing (apk: mkndx+adbsign; opkg: ipkg-make-index+usign) |
| `serve` | repo server on the lab network (44.55.66.0/24), polled until it answers |
| `router` | openwrt/rootfs booted with `/sbin/init`, network configured via `uci import` + `/etc/init.d/network restart`, firewall settled |
| `endpoint` | pinned TrustTunnel endpoint release (hash-checked), self-signed cert with SAN `tt.test`, listening on TCP+UDP 8443 |
| `targets` | two REMOTE_ADDR oracle servers: on the lab net (through-tunnel target) and on the docker default bridge (private, direct target); both answer directly before the tunnel |
| `install` | the real `install.sh` with `TT_REPO_URL` pointing at the served repo |
| `asserts` | install contract: packages installed, client binary runs, Default profile + firewall zone seeded, service registered but not started, repo entry + keys |
| `connect` | endpoint configured via uci (hostname, address, credentials, the **pinned** certificate), service enabled+started, tunnel up |
| `traffic` | service running, tun0 + routing state, client log connected, client.toml carries the pin, through-tunnel traffic arrives with the **endpoint's** source address, private traffic stays direct |
| `lifecycle` | the blackhole killswitch (kernel-level: with the device down, the marked lookup fails into the blackhole), a clean stop tears the routing down and a start restores it, install.sh / uci-defaults / reload idempotence, and the endpoint log shows the tunneled CONNECTs |

### Knobs

| Variable | Default | Meaning |
|---|---|---|
| `TT_PM` | `apk` | `apk` (OpenWrt 25.12) or `opkg` (22.03) |
| `TT_REPO_DIR` | — | flat dir of prebuilt packages (CI artifact layout) |
| `TT_RELEASE_TAG` | `latest` | release tag to download packages from |
| `TT_SERVER_VERSION` | `v1.1.0` | the endpoint release (tarball is hash-checked) |
| `TT_LAB_SUBNET` | `44.55.66.0/24` | the lab network (must be a /24, globally-shaped range) |
| `TT_FILTER` | — | space-separated list of stage names to run; a partial run must include the stages it depends on (e.g. `TT_FILTER="serve router targets"`) |
| `TT_LOGS_DIR` | — | fixed directory for the failure logs (the CI artifact upload); defaults to `$SCRATCH/logs` |
| `TT_KEEP` | `0` | keep containers/network/scratch for debugging |

On failure the harness collects the router state (logread, trusttunnel log,
routing status, kernel state, configs) and the container logs into
`$TT_LOGS_DIR` (or `$SCRATCH/logs`) before tearing anything down, and
prints the scratch path; `TT_KEEP=1` keeps the containers too.

## CI

`.github/workflows/integration.yml` runs the suite on pull requests, main
pushes and manual dispatch and is verified green end to end (PR #20):
a matrix job builds this tree's packages with the OpenWrt SDK (apk on
25.12, ipk on 22.03), then one job per package manager runs the harness
against the built repositories and uploads the failure logs as an
artifact. The `/dev/net/tun` preflight (with a mknod/modprobe fallback)
fails loudly instead of letting the harness confuse everyone.

Note: `main` dropped the localisation (PRs #17/#19), so the suite's
contract is the two packages — `luci-app-trusttunnel` and
`trusttunnel-client` — and the harness has no translation-specific
steps.

The release pipeline additionally runs the harness against the
release's own x86-64 packages (`verify-integration` in `release.yml`)
and waits for it before publishing — no SDK rebuild there, the release
artifacts are consumed directly.

## Why the stages look the way they do

- **The lab subnet must look public.** The router's own marking rules (and
  the endpoint) refuse private and documentation ranges, so the lab
  network uses a globally-shaped range that docker can host as a private
  bridge (44.55.66.0/24 by default). The endpoint runs with
  `allow_private_network_connections = true` — a test-only relaxation,
  documented in the vpn.toml fixture.
- **The router boots with `/sbin/init`** so procd, netifd, fw4 and logread
  behave like on a device. netifd would otherwise enslave eth0 into the
  default `br-lan` bridge and break docker networking — the harness
  reconfigures `network.lan` to use eth0 directly with the router's own
  tools.
- **The whoami targets are the traffic oracle.** Through-tunnel requests
  arrive with the endpoint's IP as source, direct requests with the
  caller's own IP. The direct target lives on a dedicated private docker
  network (a range the router never marks). A custom network adds only
  the connected route — joining the docker DEFAULT bridge would inject a
  second default route, and the client binds its endpoint sockets to the
  interface of the default route.
- **The lab default route is enforced.** The direct-net connect can race
  netifd's asynchronous installation of the static default; if docker's
  connected gateway wins (metric 0), the client dials the endpoint via
  the wrong gateway and the tunnel never comes up. The harness replaces
  the default with the lab gateway after the connect and again before
  the service starts, and asserts it (counting `^default` lines — busybox
  `ip` ignores the `default` filter before install.sh replaces it).
- **The pinned certificate is exercised for real.** The client connects
  with `skip_verification = false`; the self-signed certificate carries
  the SAN for the SNI hostname (`tt.test`), so a working tunnel proves
  the pin from `client.toml` authenticated the endpoint — the Phase 0
  fix, end to end.
- **Startup races are waited out deterministically:** the python servers
  (repo + targets) take a moment to bind their sockets, the firewall
  loads the lan-zone rule asynchronously after the network restart, and
  the tunnel needs up to a minute to establish — the harness polls for
  all three instead of sleeping.
- **apk fetches packages by their metadata-derived names.** The release
  assets carry a `-x86_64` suffix (per-arch uploads), which would 404 on
  the metadata-derived name, so
  every package file is renamed to `name-version.apk` (read via
  `apk adbdump`) before the index is created.
- **The install retries once on a package-manager mirror flake.** The
  update step hits the public OpenWrt mirrors, and busybox wget does not
  retry; install.sh is safe to rerun (its repository setup is
  idempotent, which the lifecycle stage asserts), so one retry absorbs
  the transient download failures.
- **On the apk path the uci-defaults script is consumed by the package
  manager.** apk runs `/etc/uci-defaults/*` right after placing them and
  removes them; install.sh's immediate run is the fallback that only
  fires on opkg. The lifecycle stage runs the idempotence rerun only
  when the file still exists and asserts the no-duplicate state on both
  paths.
- **The killswitch is asserted at the kernel level.** `ip route get
  <target> mark 0x9527` resolves via tun0 while the tunnel is up; with
  the device down the kernel drops the attached route, the table holds
  only the blackhole, and the same lookup fails (`ip route get` answers
  EINVAL for a blackhole match) — no client process is involved, so the
  check is deterministic.

## Possible extensions

Cheap, incremental additions that were designed for but not implemented:

- an `upstream_protocol = http3` scenario (the endpoint already listens
  on UDP 8443);
- the opkg variant on `openwrt/rootfs:x86-64-23.05.6` and
  `x86-64-24.10.8` (same opkg branch, extra images);
- routing-profile scenarios: a Bypass profile whose `vpn_rules` contain
  the lab target (assert `vpn_mode = "selective"` and the generated
  `exclusions`) and a VPN profile with `bypass_rules` (assert
  `vpn_mode = "general"`);
- the uninstaller round trip (`uninstall.sh -y`): packages gone,
  feed/keys gone, kernel leftovers reported;
- a snapshot test of the endpoint-down behavior with the client alive:
  the generated config sets `killswitch_enabled = false` and the
  client's recovery behavior was observed to vary, so the intended
  semantics should be decided first (possibly with an upstream issue).
