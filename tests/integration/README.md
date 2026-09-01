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
   `luci-app-trusttunnel`, the i18n package and `trusttunnel-client` from
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
| `pkgs` | the three packages for the PM, from TT_REPO_DIR / dist/ / release |
| `repo` | hermetic repo assembly + signing (apk: mkndx+adbsign; opkg: ipkg-make-index+usign) |
| `serve` | repo server on the lab network (44.55.66.0/24), polled until it answers |
| `router` | openwrt/rootfs booted with `/sbin/init`, network configured via `uci import` + `/etc/init.d/network restart`, firewall settled |
| `endpoint` | pinned TrustTunnel endpoint release (hash-checked), self-signed cert with SAN `tt.test`, listening on TCP+UDP 8443 |
| `targets` | two REMOTE_ADDR oracle servers: on the lab net (through-tunnel target) and on the docker default bridge (private, direct target); both answer directly before the tunnel |
| `install` | the real `install.sh` with `TT_REPO_URL` pointing at the served repo |
| `asserts` | install contract: packages installed, client binary runs, Default profile + firewall zone seeded, service registered but not started, repo entry + keys |
| `connect` | endpoint configured via uci (hostname, address, credentials, the **pinned** certificate), service enabled+started, tunnel up |
| `traffic` | service running, tun0 + routing state, client log connected, client.toml carries the pin, through-tunnel traffic arrives with the **endpoint's** source address, private traffic stays direct |

### Knobs

| Variable | Default | Meaning |
|---|---|---|
| `TT_PM` | `apk` | `apk` (OpenWrt 25.12) or `opkg` (22.03) |
| `TT_REPO_DIR` | — | flat dir of prebuilt packages (CI artifact layout) |
| `TT_RELEASE_TAG` | `latest` | release tag to download packages from |
| `TT_SERVER_VERSION` | `v1.1.0` | the endpoint release (tarball is hash-checked) |
| `TT_LAB_SUBNET` | `44.55.66.0/24` | the lab network (must be a /24, globally-shaped range) |
| `TT_FILTER` | — | run only stages whose name contains the value (`preflight`, `pkgs`, `repo`, `serve`, `router`, `endpoint`, `targets`, `install`, `asserts`, `connect`, `traffic`) |
| `TT_KEEP` | `0` | keep containers/network/scratch for debugging |

On failure the scratch directory (logs, install output, repository state)
is kept and its path is printed; `TT_KEEP=1` keeps the containers too.

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
  assets carry a `-x86_64` suffix (per-arch uploads) and the i18n
  version's tilde is mangled into a dot by GitHub — both would 404, so
  every package file is renamed to `name-version.apk` (read via
  `apk adbdump`) before the index is created.
