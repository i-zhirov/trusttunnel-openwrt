# Integration harness (`tests/integration/`)

End-to-end suite that installs this project **as intended** into a
dockerized OpenWrt router and verifies the result against the router's own
state. Phase 1 covers the install side: a locally assembled and signed
package repository, served from a container, installed by the real
`install.sh` with the `TT_REPO_URL` override.

Later phases add the endpoint and target containers (traffic through the
tunnel) — see `integration-tests-plan.md` at the repository root.

## Running

```sh
TT_PM=apk sh tests/integration/run.sh                 # OpenWrt 25.12, apk
TT_PM=opkg sh tests/integration/run.sh                # OpenWrt 22.03, opkg
```

Both variants need docker and internet (install.sh updates the default
OpenWrt package repositories). Without docker the harness reports SKIP
(exit 77), like the other docker-gated tests. It is deliberately NOT
picked up by `tests/run.sh` (the runner globs `tests/test_*.sh`).

### Where the packages come from

By default the harness downloads the luci-app, i18n and client packages of
the latest GitHub release (`TT_RELEASE_TAG` pins a specific one). To test
the tree under test instead, point it at a flat directory with the built
packages (the artifact layout of the CI build job):

```sh
TT_REPO_DIR=/path/to/dist sh tests/integration/run.sh
```

The repository itself is assembled per run with a **fresh** signing key
(EC P-256 for apk, usign for opkg) — the private key exists only in the
scratch directory and the served public key is what install.sh installs.

### Knobs

| Variable | Default | Meaning |
|---|---|---|
| `TT_PM` | `apk` | `apk` (OpenWrt 25.12) or `opkg` (22.03) |
| `TT_REPO_DIR` | — | flat dir of prebuilt packages (CI artifact layout) |
| `TT_RELEASE_TAG` | `latest` | release tag to download packages from |
| `TT_LAB_SUBNET` | `44.55.66.0/24` | the lab network (must be a /24, globally-shaped range) |
| `TT_FILTER` | — | run only stages whose name contains the value (`preflight`, `pkgs`, `repo`, `serve`, `router`, `install`, `asserts`) |
| `TT_KEEP` | `0` | keep containers/network/scratch for debugging |

On failure the scratch directory (logs, install output, repository state)
is kept and its path is printed; `TT_KEEP=1` keeps the containers too.

## Why the stages look the way they do

- **The lab subnet must look public.** The router's own marking rules (and,
  in later phases, the endpoint) refuse private and documentation ranges,
  so the lab network uses a globally-shaped range that docker can host as
  a private bridge (44.55.66.0/24 by default).
- **The router boots with `/sbin/init`** so procd, netifd, fw4 and logread
  behave like on a device. netifd would otherwise enslave eth0 into the
  default `br-lan` bridge and break docker networking — the harness
  reconfigures `network.lan` to use eth0 directly with the router's own
  tools (`uci import` + `/etc/init.d/network restart`).
- **Two startup races are waited out deterministically:** the python
  repository server takes a moment to bind its socket, and the firewall
  loads the lan-zone rule for eth0 asynchronously after the network
  restart — the harness polls for both instead of sleeping.
- **apk fetches packages by their metadata-derived names.** The release
  assets carry a `-x86_64` suffix (per-arch uploads) and the i18n
  version's tilde is mangled into a dot by GitHub — both would 404, so
  every package file is renamed to `name-version.apk` (read via
  `apk adbdump`) before the index is created.
