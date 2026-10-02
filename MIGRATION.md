# Migration plan: `i-zhirov/trusttunnel-openwrt` → `TrustTunnel/TrustTunnelOpenWrt`

One-time operational plan for moving this project to the TrustTunnel
organization. Keep this file updated as the migration progresses; delete
it after the go-live step completes.

## Status (verified against current `origin/main`)

- **Source of truth for the move: `origin/main`** = `dc99be1` ("Merge
  pull request #21 from i-zhirov/trusttunnel-client-pinning").
  The `main` worktree was released and `main` is synced to
  `origin/main`; all line numbers below were re-verified against
  `origin/main` at this commit.
- **Current repo:** `https://github.com/i-zhirov/trusttunnel-openwrt`
  (public, Pages at `https://i-zhirov.github.io/trusttunnel-openwrt/`,
  branch `main`, **10 releases: `v1.0.26` … `v1.0.35`**, latest
  `v1.0.35` published 2026-10-01).
- **Target repo:** `https://github.com/TrustTunnel/TrustTunnelOpenWrt`
  (exists, empty, **private**; to be renamed from `trusttunnel-openwrt`).
- **Postponed:** making the target repo public and everything that
  depends on that exposure (see "Go-live block (postponed)").
- Everything else can (and should) proceed while the target stays
  private — the release pipeline and all verification harnesses are
  hermetic and never depend on the public Pages URL.

## Verified facts (2026-10-02, against `origin/main`)

- Target repo exists, is empty (no branches, no releases), default
  branch configured as `main` (unborn), currently private.
- `i-zhirov` is an active TrustTunnel org member with **admin** on the
  target repo (can rename, change visibility, set secrets, enable Pages,
  archive the old repo).
- The org already uses GitHub Pages (`trusttunnel.org` site), so no
  org-level Pages friction. Pages is **not** enabled on the target repo
  yet (API returns 404).
- The old repo has **10 releases** (`v1.0.26` … `v1.0.35`) and matching
  tags.
- **Releases are tag-based** (release.yml): `on: push: tags:
  ['v*', 'client-v*']` + `workflow_dispatch`. A gate refuses any other
  trigger and restricts dispatch runs to `refs/heads/main`. The
  pipeline creates the GitHub release itself on a tag push.
- **Versioning is `git describe` again**: `PKG_VERSION` in each package
  Makefile = `git describe --tags --abbrev=0` with a literal fallback
  (currently `1.0.35` for all packages). A release is a fallback-bump
  commit + a `vX.Y.Z` tag push.
- **Package set** (all versioned together): `luci-app-trusttunnel`,
  `luci-app-trusttunnel-diagnostics`, `trusttunnel` (runtime), plus the
  per-arch `trusttunnel-client` (`PKG_VERSION:=1.1.7` from
  `TrustTunnel/TrustTunnelClient`). `install.sh` installs
  `luci-app-trusttunnel` and asserts `trusttunnel` + `trusttunnel-client`
  are present.
- **Tag pushes also trigger ci.yml** (`push: branches: [main],
  tags: ['v*', 'client-v*']`); integration.yml has no tag trigger.
- No org repo (`TrustTunnel`, `TrustTunnelClient`,
  `TrustTunnelFlutterClient`, `trusttunnel.org`) references the OpenWrt
  package — no cross-repo updates needed.
- The pipeline is hermetic (works on a private repo): the only
  location-dependent strings in release.yml are the ones in the Phase 1
  matrix (client-reuse curls, `refs/heads/main` checks, comments); the
  rootfs verification containers install from locally staged
  repositories and `tests/integration/run.sh` serves the repo from a
  python `http.server` on the docker lab network (`TT_REPO_URL`), with
  the GitHub-release fallback only for manual runs without
  `TT_REPO_DIR`.

## Target state

- Repo: `TrustTunnel/TrustTunnelOpenWrt` (org naming convention:
  `TrustTunnel` + descriptor in PascalCase, like `TrustTunnelClient`,
  `TrustTunnelFlutterClient`)
- Default branch: **`master`** (org convention)
- Pages URL: `https://trusttunnel.github.io/TrustTunnelOpenWrt/`
- Install URLs: `raw.githubusercontent.com/TrustTunnel/TrustTunnelOpenWrt/master/...`
- Next release: **`1.0.36`** (fallback-bump commit + `v1.0.36` tag push,
  per the standard release flow)
- Signing keys: unchanged (`TT_APK_SIGN_KEY` / `TT_OPKG_SIGN_KEY`
  secrets re-created with the same values; public halves are committed)

## Phase 1 — retarget commit (do now, on the old repo, via PR)

One `repo:` commit swapping account / repo / branch
(`i-zhirov` → `TrustTunnel`, `trusttunnel-openwrt` → `TrustTunnelOpenWrt`,
`main` → `master`). Line numbers verified against `origin/main`:

| File:line | Change |
|---|---|
| `install.sh:3` | comment → `raw.githubusercontent.com/TrustTunnel/TrustTunnelOpenWrt/master/install.sh` |
| `install.sh:28` | `TT_REPO_URL` default → `https://trusttunnel.github.io/TrustTunnelOpenWrt` |
| `uninstall.sh:3` | comment → `.../master/uninstall.sh` |
| `README.md:65,67` | issues/pulls links → `github.com/TrustTunnel/TrustTunnelOpenWrt/...` |
| `README.md:77,450` | install/uninstall snippets → `/master/...` |
| `README.md:583` | Pages URL → `https://trusttunnel.github.io/TrustTunnelOpenWrt` |
| `README.md:587` | prose "tag push on main" → "...on master" |
| `.github/workflows/release.yml:74` | `"$GITHUB_REF" != "refs/heads/main"` → `refs/heads/master` (dispatch gate) |
| `.github/workflows/release.yml:78` | comment "Dispatch on main" → "...on master" |
| `.github/workflows/release.yml:418,431` | client-reuse curl URLs → new Pages URL |
| `.github/workflows/release.yml:662` | `github.ref == 'refs/heads/main'` → `refs/heads/master` (job condition) |
| `.github/workflows/release.yml:1357` | comment → new Pages URL |
| `.github/workflows/ci.yml:14` | `branches: [ main ]` → `[ master ]` (the `tags:` line stays) |
| `.github/workflows/integration.yml:34` | `branches: [ main ]` → `[ master ]` |
| `repo-site/_config.yml:8` | `branch: main` → `branch: master` |
| `repo-site/README.md:4,16,18,30,36` | URLs → new account/repo/branch |
| `repo-site/README.md:66` | sample client ipk URL → new Pages URL (the `1.0.49` in the sample is also stale — vendor is `1.1.7`; optional docs cleanup) |
| `repo-site/release-index.md:18` | Pages URL → new URL |
| `packages/luci-app-trusttunnel/Makefile:35` | `LUCI_URL` → `https://github.com/TrustTunnel/TrustTunnelOpenWrt` |
| `packages/luci-app-trusttunnel-diagnostics/Makefile:22` | `LUCI_URL` → same |
| `packages/trusttunnel/Makefile:32` | `URL` → same |
| `tests/integration/run.sh:441,443,460` | release-fallback API/download URLs → `TrustTunnel/TrustTunnelOpenWrt` |
| `AGENTS.md:63,558,660,677,808` | prose (`main` pushes, "Merged to `main`", "PRs/main") → `master` |

Also in this commit (or the following one): a short README note that
existing routers must re-run `install.sh` to switch to the new feed URL.

Notes:

- `packages/**` changes are safe in Phase 1: release.yml has **no PR
  trigger** (only tag pushes and dispatch), so touching the Makefiles
  does not fire the release pipeline. `ci.yml` runs on the push
  (expected, must stay green); integration.yml runs its heavy suite on
  any main push (it does so already).
- Do NOT touch: UCI section names (`main.enabled`, `main.mode` —
  unrelated to the branch), the release-tree constants
  (`TT_REPO_APK_RELEASE=25.12.5`, `TT_REPO_OPKG_RELEASE=22.03.7` —
  they build on `TT_REPO_URL`), the `PKG_VERSION` fallbacks (currently
  `1.0.35` — the `1.0.36` bump is a separate, standard release
  commit), and upstream OpenWrt/vendor URLs.
- After this commit merges, the **old repo's** workflows (now
  triggering on `branches: [ master ]`) stop running on its `main`
  pushes — the old repo is effectively frozen from that point, which
  is fine (it gets archived at go-live).

## Phase 2 — target repo configuration (admin, can be done while private)

1. Rename the empty repo:
   `gh repo rename TrustTunnelOpenWrt --repo TrustTunnel/trusttunnel-openwrt --yes`
2. Add secrets `TT_APK_SIGN_KEY`, `TT_OPKG_SIGN_KEY` (same values as on
   the old repo; no key rotation — the archived old feed's signatures
   stay valid with the old keys).
3. Enable Pages: Settings → Pages → Source: **GitHub Actions**
   (works on a private repo; the site is member-visible until the flip).
4. **Postponed:** visibility → public (blocks public serving; do not do
   before the go-live step).

## Phase 3 — git migration (can be done while private)

1. Merge the Phase 1 PR on the old repo.
2. Local: `git branch -m main master` (before the first push, so the new
   repo never sees a `main` branch).
3. Add the target remote, push the branches **only**:
   `git push <target> master` + the feature branches (`readme-reorg`,
   `ui-local-dev-setup`, plus whatever else is active).
   **Do NOT push the tags** — every `v*`/`client-v*` tag push fires
   release.yml (a full publish run) and ci.yml on the new repo. Tags
   are pushed deliberately at go-live.
4. GitHub settings on the target: set default branch to `master`.
5. Re-point `origin` to `git@github.com:TrustTunnel/TrustTunnelOpenWrt.git`.

## Phase 4 — private-phase verification (can be done while private)

- `ci.yml` runs on the new repo as-is (works on private repos) — all
  contract gates must go green before anything is exposed.
- The release pipeline is NOT exercised yet: its triggers are `v*` tag
  pushes and dispatches, which do not happen while the tags stay on the
  old repo.
- Optionally run `tests/integration/run.sh` against locally built
  artifacts while waiting for go-live.

## Go-live block (postponed — execute when the org is ready)

1. Make the target repo **public** (Settings → Danger Zone). This is
   what unblocks router access to the feeds.
2. **Archive-continuity decision** (see Notes) — two options:
   - **Option A — complete archive on the new site (expensive):**
     push the tags `v1.0.26` → `v1.0.35` in **strictly ascending
     order, one at a time**, waiting for each release run to complete
     before the next (runs can race; a later run overwrites the site,
     so the final run must be the highest version — if they overlap,
     the archive can end up partial). Each run is the full pipeline
     (SDK matrix + integration verification + publish) — 10 runs,
     many hours of CI, but the new site ends up serving every prior
     version.
   - **Option B — start fresh (recommended, matches the archived-repo
     decision):** merge the standard fallback-bump commit
     (`release: bump luci-app-trusttunnel to 1.0.36`), then push the
     single tag `v1.0.36` → one pipeline run (the client-reuse curl
     404s on the fresh repo → full client rebuild, handled
     gracefully). The new site carries `1.0.36+`; `v1.0.26`–`v1.0.35`
     remain installable from the **old site, which keeps serving after
     the archive**.
3. Verify publicly: `curl -I` the site root and a feed URL
   (`.../releases/25.12.5/packages/x86_64/trusttunnel/packages.adb`);
   confirm the canonical-case URLs resolve.
4. Old repo wrap-up — **before** archiving (archived repos are
   read-only):
   - edit the old repo's README/description to point at the new repo;
   - archive `i-zhirov/trusttunnel-openwrt` (Danger Zone → Archive).
     Its Pages site keeps serving the frozen `v1.0.26`–`v1.0.35` feeds
     — installed routers stay functional but receive no further
     updates until they re-run the new `install.sh` (per the
     archived-repo decision).
5. Communicate: release notes on the `1.0.36` release with the
   migration instruction for existing routers:
   `sh -c "$(wget -O - https://raw.githubusercontent.com/TrustTunnel/TrustTunnelOpenWrt/master/install.sh)"`

## Notes and risks

- **`refs/heads/main` in release.yml (lines 74 and 662) is critical**:
  both must become `refs/heads/master`, or a `workflow_dispatch` on the
  new repo's master is refused and the publish job's condition never
  matches.
- **Tag pushes are expensive and now also run ci.yml** on the new repo
  — never push tags during the private phase.
- **`client-v*` tags** also trigger release.yml and ci.yml (vendor
  client releases). Only relevant if the org starts using them; nothing
  to migrate.
- **Archive split with Option B:** the "every released version stays
  installable" contract is preserved globally — old versions on the old
  site, new ones on the new site — but a migrated router pinned to an
  old version would need the old feed URL. Acceptable per the
  archived-repo decision; Option A avoids the split at 10× CI cost.
- **Key rotation:** if the signing keys are ever rotated, old routers on
  the frozen feed need `install.sh` re-run regardless — already covered
  by the migration note.
- **Legacy filters:** the "-lite / dropped i18n" filter and the merge
  patterns in release.yml already cover the current package set
  (`luci-app-trusttunnel`, `luci-app-trusttunnel-diagnostics`,
  `trusttunnel`, `trusttunnel-client`) — no changes needed for the move.
- **Pages URL case:** project-site URLs are served case-insensitively by
  GitHub Pages, but keep the canonical case
  (`TrustTunnelOpenWrt`) in all code and docs.
- **Continuity:** until go-live, the old repo keeps serving existing
  routers exactly as today; the new repo exists as a private, dormant
  copy of the code.
