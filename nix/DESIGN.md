# asmltr Nix flake + NixOS module — design

Date: 2026-07-15
Status: approved for planning
Home: this repo. Developed on an unpublished branch of the `scoutg001/asmltr` fork (`nix-packaging`) until it's ready to PR to `jarethmt/asmltr`. Not a separate repo.

## Goal

Package asmltr as a target-agnostic Nix flake that lives IN the asmltr repo: a root `flake.nix` exposing `nixosModules.asmltr` plus `packages.*`, with the real content in flake-agnostic `nix/` files. The flake builds the repo it sits in (`src = ./.`, version from `./VERSION`), so the flake and the code can't drift.

It stays a surprise by living on an unpublished fork branch. When it runs, it becomes a PR to `jarethmt/asmltr` offering a first-class Nix install method. Building it on the fork branch first means the PR shows up as a tested, working thing, and the pace stays ours until then.

## What the prereqs already bought us (verified against `fb6cdba`)

- **`buildNpmPackage` inputs are in sync.** `npm ci --dry-run` on the root workspace passes (699 packages); `insights/dashboard` carries its own lockfile, also in sync (172 packages).
- **The Agent SDK bundles its own CLI runtime** (`core/src/runner.js:15`). No separate `claude` binary to package; it ships inside `node_modules`.
- **Version** comes from the `VERSION` file (no git needed in the store).
- **The updater stands down** on a managed install: `ASMLTR_UPDATE_MANAGED=<manager>` makes `scripts/update.js` exit 6 before any git operation.
- **Data stores are already env-driven**, all six: `ASMLTR_CORE_DB`, `ASMLTR_TRUST_DB`, `ASMLTR_CORE_DATA`, `ASMLTR_MOD_LOG_DIR`, `ASMLTR_CONNECTORS_DB`, `ASMLTR_INSIGHTS_DB`.

## Structure: flake-agnostic core, thin flake shim

The real content lives in plain `.nix` files that never mention flakes; `flake.nix` is a thin exporter over them. This keeps a non-flake consumer working too, and makes the PR palatable whether or not Jareth wants flakes.

```
flake.nix           # root; ~15 lines: src = ./.; import the nix/ files into the output schema
nix/package.nix     # the workspace buildNpmPackage; a callPackage-able derivation
nix/dashboard.nix   # the dashboard buildNpmPackage -> static dist/
nix/module.nix      # the NixOS module: { config, lib, pkgs, ... }: ...
```

- `flake.nix` produces `packages.<system>.*` via `pkgs.callPackage ./nix/package.nix {}` (and dashboard), and `nixosModules.asmltr = import ./nix/module.nix`. It adds pinning (`flake.lock`) and the standard output names, nothing more.
- A non-flake consumer skips `flake.nix` entirely: `pkgs.callPackage ./nix/package.nix {}` for the build, `imports = [ ./nix/module.nix ]` for the service. Same files, no flake required.
- `nix/module.nix` references the package through a `package` option defaulting to `pkgs.callPackage ../nix/package.nix {}`, so it never depends on flake wiring to find its own build.

The rule: no file under `nix/` may read `self`, `inputs`, or any flake-only value. Anything flake-specific stays in `flake.nix`.

## Flake outputs (the shim's surface)

- `packages.${system}.asmltr-workspace` — the four host workspaces (core, connectors, cli, insights/collector) built as one `buildNpmPackage` (`nix/package.nix`).
- `packages.${system}.asmltr-dashboard` — the Vue SPA built to a static `dist/` (`nix/dashboard.nix`).
- `packages.${system}.asmltr` — the aggregate: runtime components + wrapper entrypoints + the dashboard `dist/` wired to the collector.
- `nixosModules.asmltr` — the deployable systemd module (`nix/module.nix`, imported verbatim).
- `devShells.${system}.default` — Node 20 + the node-gyp toolchain, so in-tree `npm ci` and iteration work too.

## Package build (Approach A: hermetic `buildNpmPackage`)

**`asmltr-workspace`.** `src = ./.` (the repo the flake lives in). Dependencies come through `npmDepsHash` against the committed root `package-lock.json`. Native modules:

- `better-sqlite3` and `@discordjs/opus` build from source under the Nix node-gyp toolchain (`nodejs`, `python3`, `node-gyp`, `npm_config_build_from_source=true`).
- `@picovoice/porcupine-node` ships a prebuilt `.so`; `autoPatchelfHook` fixes its interpreter and RPATH against `stdenv.cc.cc.lib` and `libstdc++`. Its `.ppn` and `.pv` model blobs pass through as data.
- The Agent SDK's bundled CLI runs through `nodejs_20`; patch its shebang if the vendored interpreter path doesn't resolve.

**`asmltr-dashboard`.** A separate `buildNpmPackage` off `insights/dashboard` (its own lockfile) whose output is the static `dist/`. The collector serves it. No Docker on the Nix host.

## NixOS module (`nixosModules.asmltr`)

- **Dedicated `asmltr` system user.** Not `DynamicUser`: the Max credential refreshes in place and needs a stable, writable HOME.
- **`StateDirectory=asmltr` → `/var/lib/asmltr`**, used both as the data root and as the service HOME. The Max credential lives at `/var/lib/asmltr/.claude`, persists across `nixos-rebuild`, and stays out of the store and out of git.
- **Three systemd services**: `asmltr-core` (:3023), `asmltr-connector-manager` (:3024), `asmltr-insights-collector` (:3017). Ports are options.
- **Env wiring**: point the six data env vars plus the new announcements path (see Prerequisite) under `/var/lib/asmltr`. Set `ASMLTR_UPDATE_MANAGED=nixos` so the updater stands down. Channel/model/assistant-name are options.
- **Secrets** (Discord, Telegram, OpenAI, ElevenLabs tokens) come from an `environmentFile` an operator points at agenix or sops. Nothing secret enters the store. This matches asmltr's own convention (`shared/secrets.js`, gitignored config with `.example` twins).
- **Connector spawning stays intact.** The manager spawns `runtime/run-instance.js` children resolving `../types/<type>`; the built workspace tree preserves that layout, so it resolves under the store path.
- **Hardening**: `ProtectSystem=strict` with `/var/lib/asmltr` writable, `NoNewPrivileges=true`. Services bind `127.0.0.1` (asmltr non-negotiable #3); a reverse proxy is out of scope for the module.

## Auth: the one runtime bootstrap

asmltr runs every turn through the local Agent SDK on the Claude Max subscription, never an `ANTHROPIC_API_KEY` (non-negotiable #1). `core/src/runner.js` calls `query()` with no explicit credential handling; the SDK reads the OAuth token from `HOME/.claude`, and cost is ~0 on Max.

So the module needs exactly one manual step:

- Once, as the `asmltr` user with `HOME=/var/lib/asmltr`, run `claude login`. The token lands in `/var/lib/asmltr/.claude`, refreshes in place, and survives rebuilds.

No credential material is ever baked into the flake.

## Prerequisite (upstream, filed as a standalone cleanup)

`connectors/manager/server.js:221` writes `announcements.json` to `path.join(__dirname, 'data', ...)` with no env escape, the one store-path write left after the data-dir env vars. Fix it upstream the same way as the last three cleanups: give it an env var (or fold the manager's data under one configurable dir), no Nix mention. This is Phase 0 of the plan, and it lands independently of the flake branch.

## Error handling and edge cases

- **Lock drift**: the flake builds the branch's working tree, whose committed root lockfile is kept in sync (`npm ci --dry-run` gates it; asmltr's `release.js` keeps tag locks in sync).
- **Native build failure**: `autoPatchelfHook` for porcupine, source builds for opus and better-sqlite3; the devShell mirrors the same `buildInputs` so failures reproduce outside the sandbox.
- **Missing credential**: a turn fails if `/var/lib/asmltr/.claude` has no login; `/health` still answers, and the module docs the one-time login.
- **Updater collision**: `ASMLTR_UPDATE_MANAGED=nixos` makes `update.js` exit 6, so no in-place git operations run against the read-only store.

## Testing and validation (no external host)

Everything validates on this box or inside the Nix sandbox. No deploy target, no Heimdall.

- `nix flake check`; `nix build .#asmltr .#asmltr-dashboard`.
- **Non-flake path** (proves "gets both" isn't just claimed): `nix-build -E 'with import <nixpkgs> {}; callPackage ./nix/package.nix {}'` builds the workspace with no flake, and a throwaway host config that does `imports = [ ./nix/module.nix ]` evaluates. If either breaks, a `nix/` file leaked a flake-only value.
- **Real turn, on this box (Thor)**: `nix build` the workspace, then run the built core from its store path against a scratch data dir plus this machine's existing `~/.claude` login, and drive one `query()` turn. This proves the native deps, the bundled SDK CLI, and a real Max turn all work from the Nix-built artifact, without deploying anywhere.
- **Module wiring**: a `nixosTest` (a QEMU VM in the Nix build sandbox) boots the three services and asserts the `/health` endpoints answer and `/version` reports `managed:true`. Hermetic, no external host, no credential needed (a turn isn't exercised here; the real-turn check above covers that).

## Phasing

- **Phase 0** — upstream `announcements.json` cleanup PR (Nix-hidden), lands independently.
- **Phase 1** — the flake-agnostic skeleton on the fork branch: `nix/package.nix` (text core, no voice deps yet) + the root `flake.nix` + devShell. Prove `nix build .#asmltr-workspace` builds, the non-flake `callPackage` path builds the same thing, and the built core drives one real turn on this box.
- **Phase 2** — voice deps: porcupine `autoPatchelfHook` + opus source build.
- **Phase 3** — the dashboard derivation.
- **Phase 4** — `nixosModules.asmltr` + the `nixosTest` (VM in the sandbox).
- **Phase 5** — open the PR to `jarethmt/asmltr`: the flake as a first-class, tested Nix install method.
