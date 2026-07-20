# asmltr Nix Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package asmltr as an in-repo, flake-agnostic Nix flake + NixOS module, built and validated with no external host.

**Architecture:** Plain `nix/` files (`package.nix`, `dashboard.nix`, `module.nix`) hold all the real logic and never read flake-only values; a thin root `flake.nix` (`src = ./.`) exports them. Approach A: `buildNpmPackage` against the committed root + dashboard lockfiles. Dedicated `asmltr` user, `claude login` once into a persistent HOME. Developed on the unpublished `nix-packaging` branch of `scoutg001/asmltr`.

**Tech Stack:** Nix (flakes + `nixpkgs` `buildNpmPackage`, `autoPatchelfHook`, `nixosTest`), Node 20, node-gyp toolchain.

## Global Constraints

- No `ANTHROPIC_API_KEY` anywhere; auth is the local Agent SDK on the Max subscription reading `HOME/.claude` (asmltr non-negotiable #1).
- Services bind `127.0.0.1` only (non-negotiable #3).
- No file under `nix/` may reference `self`, `inputs`, or any flake-only value; flake-specific wiring lives only in `flake.nix`.
- Version string is `lib.fileContents ../VERSION` (currently `0.2.0`); never hardcode it.
- The design source of truth is `nix/DESIGN.md`.
- All asmltr commits: conventional-commit style, NO AI-attribution trailers, authored as Gianni LaMolinare <gianni@scoutg.tech>.
- Phase 0 is a standalone cleanup PR on its own branch off `origin/main`, PR'd to `jarethmt/asmltr` with NO mention of Nix (same pattern as issues #17/#18/#23). All other phases live on `nix-packaging`.
- Nix hash discovery pattern: set the hash to `lib.fakeHash`, run the build, copy the `got: sha256-...` value from the error into the derivation. This is the standard, expected loop; treat the first build of any dep-fetching derivation as a two-run step.

---

## Phase 0 — `announcements.json` env escape (standalone upstream PR, Nix-hidden)

Only the NixOS module (Phase 4) needs this; it lands independently and does not touch the `nix-packaging` branch.

### Task 0: give the manager's announcements file an env override

**Files:**
- Modify: `connectors/manager/server.js:221`

**Interfaces:**
- Produces: env var `ASMLTR_ANNOUNCE_FILE` honored by the manager; default unchanged.

- [ ] **Step 1: create the branch off current origin/main**

```bash
git -C ~/workspace/asmltr fetch origin -q
git -C ~/workspace/asmltr worktree add -b fix/manager-announce-path \
  "$CLAUDE_JOB_DIR/tmp/wt-announce" origin/main
```

- [ ] **Step 2: read the current line to confirm the pattern**

Run: `sed -n '221p' "$CLAUDE_JOB_DIR/tmp/wt-announce/connectors/manager/server.js"`
Expected: `const ANNOUNCE_FILE = path.join(__dirname, 'data', 'announcements.json');`

- [ ] **Step 3: apply the env override (match the sibling pattern used by registry.js's `ASMLTR_CONNECTORS_DB`)**

Change line 221 to:

```js
const ANNOUNCE_FILE = process.env.ASMLTR_ANNOUNCE_FILE || path.join(__dirname, 'data', 'announcements.json');
```

- [ ] **Step 4: syntax check**

Run: `node --check "$CLAUDE_JOB_DIR/tmp/wt-announce/connectors/manager/server.js"`
Expected: no output, exit 0.

- [ ] **Step 5: behavior check (env honored, default preserved)**

Run:
```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-announce/connectors/manager"
ASMLTR_ANNOUNCE_FILE=/tmp/x.json node -e "process.env.ASMLTR_ANNOUNCE_FILE='/tmp/x.json'; const p=require('path'); console.log(process.env.ASMLTR_ANNOUNCE_FILE || p.join(__dirname,'data','announcements.json'))"
node -e "const p=require('path'); console.log(process.env.ASMLTR_ANNOUNCE_FILE || p.join(__dirname,'data','announcements.json'))"
```
Expected: first prints `/tmp/x.json`; second prints the `.../data/announcements.json` default.

- [ ] **Step 6: commit**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-announce"
git add connectors/manager/server.js
git commit -m "feat(manager): honor ASMLTR_ANNOUNCE_FILE for the announcements path

Every manager/collector data store already reads an env var
(ASMLTR_CONNECTORS_DB, ASMLTR_INSIGHTS_DB, ...) except announcements.json,
which was pinned to __dirname/data. Give it the same escape so a read-only
or relocated install can point it elsewhere; default is unchanged."
```

- [ ] **Step 7: file the issue + push + open the PR (fork remote, Nix-hidden body)**

```bash
gh issue create -R jarethmt/asmltr \
  --title "announcements.json is the one manager data path with no env override" \
  --body "Every other manager/collector store honors an env var (\`ASMLTR_CONNECTORS_DB\`, \`ASMLTR_INSIGHTS_DB\`, and the core \`ASMLTR_*_DB\` set); \`connectors/manager/server.js:221\` still pins \`announcements.json\` to \`__dirname/data\`. On a read-only or relocated install that write has nowhere to go. Give it an \`ASMLTR_ANNOUNCE_FILE\` escape, default unchanged."
git -C "$CLAUDE_JOB_DIR/tmp/wt-announce" push -u fork fix/manager-announce-path
gh pr create -R jarethmt/asmltr --base main --head scoutg001:fix/manager-announce-path \
  --title "feat(manager): honor ASMLTR_ANNOUNCE_FILE for the announcements path" \
  --body "Closes the issue above. Adds an env override for the one manager data path still hardcoded to \`__dirname/data\`, matching the pattern the other stores already use. Default unchanged; one-line change."
```

- [ ] **Step 8: clean up the worktree**

```bash
git -C ~/workspace/asmltr worktree remove --force "$CLAUDE_JOB_DIR/tmp/wt-announce"
```

---

## Phase 1 — flake-agnostic skeleton: build the core with Nix and run one real turn

All work here is on the `nix-packaging` branch worktree (already created at `$CLAUDE_JOB_DIR/tmp/wt-nix`). Deliverable: `nix build .#asmltr-workspace` produces a store path from which the core runs one real Max turn on this box, and the same derivation builds via plain `callPackage` with no flake.

### Task 1: the thin flake shim + devShell

**Files:**
- Create: `flake.nix`

**Interfaces:**
- Produces: `packages.<system>.asmltr-workspace` (defined in Task 2), `packages.<system>.default`, `devShells.<system>.default`, `nixosModules.asmltr` (stubbed here, real in Phase 4).

- [ ] **Step 1: write `flake.nix` (no `nix/` file referenced yet exists; it will error until Task 2, which is expected)**

```nix
{
  description = "asmltr — channel-agnostic assistant backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          asmltr-workspace = pkgs.callPackage ./nix/package.nix { };
          default = self.packages.${system}.asmltr-workspace;
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = [ pkgs.nodejs_20 pkgs.python3 pkgs.node-gyp pkgs.pkg-config ];
          };
        });

      # Real module lands in Phase 4; exported now so the output schema is stable.
      nixosModules.asmltr = import ./nix/module.nix;
    };
}
```

- [ ] **Step 2: create a placeholder `nix/module.nix` so `flake.nix` evaluates**

Create `nix/module.nix`:

```nix
# Placeholder; real module in Phase 4. Must stay flake-agnostic.
{ config, lib, pkgs, ... }:
{
  options.services.asmltr.enable = lib.mkEnableOption "asmltr";
  config = { };
}
```

- [ ] **Step 3: verify the flake evaluates its non-package outputs (package will fail until Task 2)**

Run: `cd "$CLAUDE_JOB_DIR/tmp/wt-nix" && nix flake show 2>&1 | head -40`
Expected: `devShells` and `nixosModules.asmltr` show; `packages` errors on missing `./nix/package.nix`. That error is expected and resolved by Task 2.

- [ ] **Step 4: commit**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
git add flake.nix nix/module.nix
git commit -m "feat(nix): thin flake shim + devShell + module placeholder"
```

### Task 2: `nix/package.nix` — build the workspace, voice deps deferred

**Files:**
- Create: `nix/package.nix`

**Interfaces:**
- Consumes: the committed root `package-lock.json` and `package.json` `workspaces`.
- Produces: a derivation whose `$out/lib/node_modules/asmltr` holds the built workspace tree (core/connectors/cli/insights-collector + a working `better-sqlite3`), with `node` on the wrapper path. Voice native deps (`@discordjs/opus`, `@picovoice/porcupine-node`) are installed but unbuilt.

- [ ] **Step 1: write `nix/package.nix` with a fake hash**

```nix
{ lib, stdenv, buildNpmPackage, nodejs_20, python3 }:

buildNpmPackage {
  pname = "asmltr-workspace";
  version = lib.fileContents ../VERSION;

  # src = the repo this file lives in. cleanSource drops .git and result symlinks.
  src = lib.cleanSource ../.;

  # Filled in Step 2 via the fakeHash loop.
  npmDepsHash = lib.fakeHash;

  nodejs = nodejs_20;

  # Defer voice native builds: skip ALL install scripts, then rebuild only the
  # native module core actually needs (better-sqlite3). @discordjs/opus and
  # @picovoice/porcupine-node stay present-but-unbuilt; core never loads them,
  # so a text turn works. Phase 2 removes --ignore-scripts and handles them.
  npmFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [ python3 ];

  # The backend workspaces are plain node; there is no build/compile step.
  dontNpmBuild = true;

  postBuild = ''
    npm rebuild better-sqlite3 --build-from-source --nodedir=${nodejs_20}/include/node
  '';

  meta = {
    description = "asmltr channel-agnostic assistant backend (workspace bundle)";
    platforms = lib.platforms.linux;
  };
}
```

- [ ] **Step 2: resolve `npmDepsHash` (the two-run fakeHash loop)**

Run: `cd "$CLAUDE_JOB_DIR/tmp/wt-nix" && nix build .#asmltr-workspace 2>&1 | tee /tmp/build1.log | tail -20`
Expected: fails with `hash mismatch ... specified: sha256-AAAA... got: sha256-<REAL>`.
Copy the `got:` value and replace `npmDepsHash = lib.fakeHash;` with `npmDepsHash = "sha256-<REAL>";`.

- [ ] **Step 3: build again; fix native/script issues as they surface**

Run: `cd "$CLAUDE_JOB_DIR/tmp/wt-nix" && nix build .#asmltr-workspace 2>&1 | tail -40`
Expected outcomes and fixes:
- If `better-sqlite3` rebuild fails to find node headers: confirm `--nodedir=${nodejs_20}/include/node`; add `node-gyp` to `nativeBuildInputs` if `node-gyp: not found`.
- If the Agent SDK's vendored CLI shebang fails at runtime later (not build): handled in Task 3.
- On success: a `result` symlink appears. Run `ls -la result/lib/node_modules/asmltr` and confirm `core/`, `connectors/`, `cli/`, `insights/` are present.

- [ ] **Step 4: verify the non-flake path builds the identical derivation**

Run:
```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
nix-build -E 'with import <nixpkgs> {}; callPackage ./nix/package.nix {}' --no-out-link 2>&1 | tail -5
```
Expected: builds to a store path with no flake involved. If it errors on a flake-only value, a leak violated the Global Constraint; fix `nix/package.nix`.

- [ ] **Step 5: commit**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
git add nix/package.nix
git commit -m "feat(nix): buildNpmPackage workspace derivation (voice deps deferred)"
```

### Task 3: prove the built core runs one real Max turn on this box

**Files:**
- Create: `nix/smoke-turn.sh` (a validation helper kept in-repo)

**Interfaces:**
- Consumes: `result/lib/node_modules/asmltr` from Task 2; this box's existing `~/.claude` login.
- Produces: evidence that the Nix-built core completes a real `query()` turn (native deps load, SDK CLI runs, Max auth works) with no deploy.

- [ ] **Step 1: write `nix/smoke-turn.sh`**

```bash
#!/usr/bin/env bash
# Run the Nix-built core against a scratch data dir + this box's Claude login,
# and drive one real turn through the same runner the service uses.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="$ROOT/result/lib/node_modules/asmltr"
[ -d "$BUILT" ] || { echo "build first: nix build .#asmltr-workspace"; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export ASMLTR_CORE_DB="$SCRATCH/core.db" ASMLTR_TRUST_DB="$SCRATCH/trust.db" \
       ASMLTR_CORE_DATA="$SCRATCH/data" ASMLTR_MOD_LOG_DIR="$SCRATCH/modlogs"
export ASMLTR_MODEL="${ASMLTR_MODEL:-haiku}"   # cheap model for the smoke turn

node -e '
  const { runTurn } = require(process.env.BUILT + "/core/src/runner.js");
  // runTurn is exported by runner.js; if the export name differs, read runner.js
  // and call the single-turn entrypoint it exposes.
  (async () => {
    const r = await runTurn({ prompt: "Reply with exactly: NIXOK", systemPrompt: "", cwd: process.env.HOME });
    const text = (r && (r.text || r.output || JSON.stringify(r))) || "";
    console.log("TURN_RESULT:", text.slice(0, 200));
    process.exit(/NIXOK/.test(text) ? 0 : 2);
  })().catch(e => { console.error("TURN_ERR:", e.message); process.exit(3); });
' 
```

- [ ] **Step 2: confirm the runner's single-turn export name before running**

Run: `grep -nE "module.exports|exports\\.[a-zA-Z]+ =|^async function run" "$CLAUDE_JOB_DIR/tmp/wt-nix/core/src/runner.js" | head`
Expected: shows the exported turn function. If it is not `runTurn`, edit `smoke-turn.sh` to call the actual name (e.g. `run`, `runOnce`). Do not guess; match the source.

- [ ] **Step 3: run the smoke turn against the built artifact**

Run:
```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
chmod +x nix/smoke-turn.sh
BUILT="$PWD/result/lib/node_modules/asmltr" HOME="$HOME" ASMLTR_MODEL=haiku ./nix/smoke-turn.sh
```
Expected: `TURN_RESULT: ... NIXOK ...` and exit 0. This proves better-sqlite3 loaded, the bundled SDK CLI ran, and the Max login worked from the Nix-built tree.
- If it fails on the SDK CLI shebang/interpreter: add a `postBuild` patch in `nix/package.nix` to point the vendored CLI shebang at `${nodejs_20}/bin/node` (`patchShebangs` over the SDK's bin dir), rebuild, re-run.
- If it fails on a missing native `.node`: that dep needed a script; add a targeted `npm rebuild <dep>` to `postBuild`.

- [ ] **Step 4: commit**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
git add nix/smoke-turn.sh
git commit -m "test(nix): on-box smoke turn proving the built core completes a real turn"
```

### Task 4: pin the flake lock and confirm a clean full build

**Files:**
- Create: `flake.lock` (generated)
- Create: `.gitignore` (add `result`, `result-*`)

- [ ] **Step 1: add `.gitignore` entries**

Append to `.gitignore` (create if absent) at repo root:
```
result
result-*
```

- [ ] **Step 2: generate and commit the lock, then a clean rebuild**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
nix flake lock
nix build .#asmltr-workspace
nix flake check 2>&1 | tail -20
```
Expected: `flake.lock` created; build succeeds; `nix flake check` passes (module placeholder + package eval clean).

- [ ] **Step 3: commit**

```bash
cd "$CLAUDE_JOB_DIR/tmp/wt-nix"
git add flake.lock .gitignore
git commit -m "chore(nix): pin flake.lock; ignore result symlinks"
```

- [ ] **Step 4: push the branch (private; no PR yet)**

```bash
git -C "$CLAUDE_JOB_DIR/tmp/wt-nix" push -u fork nix-packaging
```

---

## Phases 2–5 — roadmap (detailed after Phase 1 lands)

These are deliberately not broken into TDD steps yet: each depends on empirical results from Phase 1 (the resolved `npmDepsHash`, whether the SDK shebang needed patching, exactly which deps have install scripts). A detailed per-task plan for Phase 2 gets written once Phase 1 is green.

- **Phase 2 — voice deps.** Drop `--ignore-scripts`; let `@discordjs/opus` build from source (node-gyp toolchain already in `nativeBuildInputs`); add `autoPatchelfHook` + `stdenv.cc.cc.lib` so `@picovoice/porcupine-node`'s prebuilt `.so` resolves; confirm the `.ppn`/`.pv` model blobs land. Validate: `nix build` succeeds and a smoke that loads the porcupine + opus modules exits clean.
- **Phase 3 — dashboard derivation.** `nix/dashboard.nix`: a second `buildNpmPackage` off `insights/dashboard` (its own lockfile) with `npmBuild` running `vite build`, output = the static `dist/`. Wire it as `packages.<system>.asmltr-dashboard` and have the aggregate serve it via the collector. Validate: `nix build .#asmltr-dashboard` yields a `dist/` with `index.html`.
- **Phase 4 — NixOS module + nixosTest.** Replace the `nix/module.nix` placeholder with the real module (dedicated `asmltr` user, `StateDirectory=asmltr`, three systemd services, the six data env vars + `ASMLTR_ANNOUNCE_FILE` under `/var/lib/asmltr`, `ASMLTR_UPDATE_MANAGED=nixos`, `environmentFile` secrets, `127.0.0.1` binds, hardening). Add a `nixosTest` that boots the module and asserts the three `/health` endpoints answer and `/version` reports `managed:true`. Validate: `nix build .#checks.<system>.vm` (the nixosTest) passes; no credential needed.
- **Phase 5 — the PR.** Open the PR from `nix-packaging` to `jarethmt/asmltr` presenting the flake as a tested Nix install method, with `nix/DESIGN.md` as the design note.
