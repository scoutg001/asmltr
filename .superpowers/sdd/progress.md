# asmltr Nix packaging — progress ledger

Plan: nix/PLAN.md (branch nix-packaging). Pre-flight scan: clean.

- Task 0 (Phase 0, announcements PR): complete (commit 46e5387; issue #29 + draft PR #30)
- Task 1 (flake shim + devShell): pending
- Task 2 (nix/package.nix): pending
- Task 3 (on-box smoke turn): pending
- Task 4 (flake.lock + push): pending

- Task 1 (flake shim + devShell): complete (9603a57)
- Lockfile backfill prereq: complete (67369d7) — VERIFIED upstream lock missing resolved/integrity 618/703; validated by hermetic build. OPEN: propose as standalone upstream PR before Phase 5.
- Task 2 (nix/package.nix, nodejs_22, voice deferred): complete (063337b)
- Task 3 (on-box smoke turn, NIXOK): complete (fda9444)
- Task 4 (flake.lock + .gitignore + push fork/nix-packaging): complete (27cbc4d)
Phase 1: COMPLETE — nix build + non-flake callPackage + flake check all pass; real turn ran (NIXOK). Node 20->22 (sound). Phase 2 pending.

- Lockfile upstream PR: FILED (issue #47, draft PR #48) — 614 entries backfilled off current origin/main (0.7.0), zero drift, verified npm ci --ignore-scripts 696 pkgs exit 0. Once merged: rebase nix-packaging onto it, drop local backfill 67369d7.
- FLAG: asmltr-insights-collector now requires node >=24 (main advanced to 0.7.0). Nix uses node 22. Check for Phase 4 (collector under systemd).
- Phase 2 (voice deps): dispatched, building in background.

- Phase 2 (voice deps): commits f0a0fa6 + c68f60a. VERIFIED by controller: flake build BUILD_EXIT=0; smoke-voice OPUS_OK(encoded)+PORCUPINE_OK(autopatchelf)+VOICEOK; smoke-turn NIXOK (no regression); flake check exit 0. Approach: kept --ignore-scripts, autoPatchelfHook + stdenv.cc.cc.lib, patchShebangs then rebuild better-sqlite3+@discordjs/opus from source, deleted porcupine foreign-arch binaries so autopatchelf only sees x86_64. Non-flake callPackage build: in progress (last check).

- Phase 3 (dashboard): commit 02bd77d. VERIFIED by controller: nix build .#asmltr-dashboard -> result/index.html + result/assets/ (Access-*.js/.css, BaseChart). Dashboard lockfile was already complete (no backfill). nix/dashboard.nix uses nodejs_24 (engine >=24). Non-flake path builds; flake check passes.
- OPEN for Phase 4: node version. Workspace built on node 22; insights-collector + dashboard declare engines.node >=24. Module must pick the runtime node for core/manager/collector services. Decide before Phase 4.
- Phase 4 (module + nixosTest) + Phase 5 (PR): pending. CI/cache: under discussion with Gianni.

- Phase 2 CONFIRMED complete (agent final report, non-flake CALLPKG_EXIT=0, autopatchelf 0 unsatisfied). Two Phase-4 concerns:
  (1) opus binary is ABI+glibc-locked to the exact build node (prebuild/node-v127-... = node 22). Services MUST run under the same nixpkgs node pin the package built with, else opus fails to load. -> node version is load-bearing.
  (2) foreign-arch prune list is x86_64-specific; aarch64 build would need to keep the aarch64 porcupine binary. meta.platforms=linux is currently optimistic.

- CI/cache DECISIONS (Gianni): NO third-party (no Cachix). Node bump to 24 confirmed, version centralized in nix/versions.nix.
  * CI incrementality (fork, now): nix-community/cache-nix-action (GitHub's own Actions cache holds /nix/store; 10GB LRU cap). DeterminateSystems/nix-installer-action. runs-on = configurable repo var (self-hosted-ready for Jareth's VM later). nix flake check + nix build workspace+dashboard. lib.fileset src filter (docs/nix-only commits don't rebuild workspace). paths-ignore **.md.
  * Consumer/release artifact (Phase 5): closure attached to each vX.Y.Z GitHub Release (nix-store --export | zstd -> release asset; consumer curl|zstd -d|nix-store --import before nixos-rebuild). NOT GitHub Pages (Gianni: don't pollute Pages). No signing key needed (import path). Rides release.js tag flow.
- Node-24 validation: running (validate-node24.sh, task bb188tyue). Commit node-24 when green, then write CI workflow, then Phase 4.

- Node-24 bump + centralization: VERIFIED green (commits eed0ec2, 8a70a0f). opus ABI node-v137, VOICEOK/NIXOK, both builds, flake check, nodejs_24 in ONE place (nix/versions.nix).
- CI workflow: committed 3abb1d2 (.github/workflows/nix.yml). Determinate installer + cache-nix-action + configurable runs-on + flake check + build. YAML valid locally; UNTESTED on GitHub until first fork push (action versions may need bump).
- DEFERRED optimization: lib.fileset src filter in package.nix (so docs/nix-only commits don't rebuild the workspace). Workflow file done; fileset is a separate package.nix change, not yet applied.
- Phase 4 (module + nixosTest): DISPATCHED (agent a5b77a2295f8bc8d9). Entrypoints: core=core/src/server.js:3023, manager=connectors/manager/server.js:3024, collector=insights/collector/server.js:3017. Node 24 for ABI match. StateDirectory=/var/lib/asmltr=HOME. environmentFile secrets. nixosTest asserts /health x3 + managed:true, no real turn.
- Phase 5 (PR + release closure): pending.

- CI workflow VERIFIED on GitHub: pushed 3abb1d2 to fork/nix-packaging, run 30301237626 = SUCCESS (all steps: install nix, cache /nix/store, flake check, build workspace+dashboard). Action versions + cache step confirmed working (the local-untestable caveat is resolved). Cold-cache run; cache now populated for incremental.

- Phase 4 (module + nixosTest): commits ce471eb (module) + 4ff54c9 (test). DONE_WITH_CONCERNS.
  Module verified via report: 3 systemd services, dedicated asmltr user, StateDirectory=/var/lib/asmltr=HOME, node 24 from versions.nix passed into package (opus ABI match), loopback-only (HOST hardcoded 127.0.0.1 in source), environmentFile secrets, hardening. All 3 boot with ZERO secrets (OpenAI client lazy).
  nixosTest (nix/test.nix): substantive assertions (units active, /health bodies, managed:true+manager:nixos via POST /v2/update/run, ss loopback, statedir owner+db). Agent proved GREEN via direct nixos-test-driver (exit 0).
  CONCERN 1 (KVM): `nix flake check`/`nix build .#checks..module` FAILS in this daemon env — nixbld users not in kvm group, QEMU 'failed to initialize kvm'. NOT a test defect. Local fix = host config (nixbld in kvm); agent's temp /dev/kvm widen was safety-blocked, correctly not worked around. CI impact: nixosTest in `checks` makes flake check need KVM -> hosted runner needs an enable-KVM step (uncertain) OR gate VM test to the self-hosted (configurable) runner. DECISION PENDING.
  CONCERN 2 (managed via status): GET /v2/update/status drops `managed` in git-less store (error branch after git rev-parse throws). Real UX gap: a Nix-host dashboard won't show "managed". Possible follow-up fix to the managed-mode code. Test works around via POST path.
  CONCERN 3: ASMLTR_ANNOUNCE_FILE set by module but not yet read by tree (PR #30 unmerged); harmless/forward-compatible.

- KVM-on-hosted RESOLVED: added Enable-KVM udev step to workflow (commit 2d496fd). Pushed; CI run 30304222119 = SUCCESS with the nixosTest: log shows nixos-test-driver-asmltr-module built, vm-test-run booted the VM ("machine: starting vm"), all assertions passed. So flake check builds+boots+passes the module VM test on a stock ubuntu-latest hosted runner. No self-hosted runner needed now (still configurable via ASMLTR_CI_RUNNER for later).
- STATUS: Phases 0-4 DONE + verified. CI (build + VM test) green on hosted. Remaining: Phase 5 (PR to jarethmt + release-closure artifact) + deferred lib.fileset optimization + concern-2 managed-via-status follow-up.

- FINAL REVIEW done: 1 Critical (C1 cleanSource secret leak on non-flake path), 2 Important (I1 closure bloat, I2 native build ships green — smokes wired to nothing), 3 Minor (M1 announce comment, M2 aggregate+dashboard-serving unimplemented, M3 health always-200). Report /tmp/final-review.md.
- Fix agent DISPATCHED (a6509f56) for C1+I1 (lib.fileset src, leak-tested), I2 (native-load check in flake checks), M1 (comment). Build-validated.
- managed-via-GET fix: FILED upstream (issue #67, draft PR #68) — hoist getManaged() before git, include in catch, gate available on !managed. Verified via failing-git-on-PATH test. Own branch off origin/main (380b380).
- M2 (aggregate + dashboard-serving): reality = dashboard served by separate nginx (static + bearer injection) behind Authelia 2FA; collector is API-only. "Collector serves dist" needs app+security change. Re-presenting options to Gianni.

- Review fixes COMMITTED + validated: 83213c3 (C1+I1 lib.fileset — LEAK CANARY test PASS, secrets absent from store; NIXOK/VOICEOK still pass), 4fe77a8 (I2 native-load check in flake checks, NATIVE_EXIT=0), aa9dece (M1 + doc comments). flake check local fails only on KVM (nixosTest), expected.
- M2 = option A chosen (Gianni): collector becomes the front door — serves dist + proxies/injects bearers to collector/manager/core. Security-sensitive upstream feature; build to PRESERVE current posture (loopback + operator Authelia proxy still required; keep read-vs-control distinction); flag for Jareth's review. TODO.
- Upstream PRs open: #30 (announce), #48 (lockfile), #67/#68 (managed-status). Rebase branch onto these when merged.

- Review fixes VERIFIED in CI (run 30469773752 success: fileset build + native-load + nixosTest all green on hosted).
- M2-A DECISION (Gianni): roll the front-door into the Phase-5 reveal PR (not a separate PR). So it lands on nix-packaging.
- Front-door spec = insights/dashboard/nginx.conf.template (line-for-line): static SPA + gate via core GET /v2/auth/verify (sets Remote-User, confirmed core/src/server.js:710) + per-route token injection (/api INSIGHTS_TOKEN, /api/control CONTROL_TOKEN, /manager MANAGER_TOKEN, /trust+/v2 X-Remote-User, /socket.io INSIGHTS_TOKEN) + /v2/auth + /oidc ungated. OPT-IN via ASMLTR_DASHBOARD_DIST (off by default = zero regression). Agent af0f4e9f building it in insights/collector/frontdoor.js. REVIEW AUTH LINE-BY-LINE.
- Then Part 2: aggregate packages.asmltr + module wiring (enable front-door, set dist + tokens) + extend nixosTest. Then Phase 5 reveal PR.

- M2-A Part 1 (front-door): DONE + auth-reviewed line-by-line + 20/20 test verified by controller. Commits 1db2a5c (frontdoor.js), 6580f2f (mount, no-op off), adb81b1 (test), 59e6948 (.env.example). Fail-closed gate, strips client Remote-User (spoof-hardened over nginx), read-vs-control token split preserved, opt-in (off=zero regression), correct mount order (proxies<json<static). Flagged reproduced-not-patched: /api/control/audit token, socket.io no-op bearer.
- M2-A Part 2 (aggregate packages.asmltr + module dashboard.enable wiring + nixosTest 2nd node asserting served-SPA + gate-401): DISPATCHED (agent ab5bc01f). Then Phase 5 = reveal PR (nix packaging + front-door bundled), flagged for Jareth security review.

- M2-A Part 2 DONE: 76603e3 (packages.asmltr aggregate = workspace + dashboard dist symlinkJoin), 1d1de96 (module dashboard.enable → sets ASMLTR_DASHBOARD_DIST, tokens via environmentFile), 80eb396 (nixosTest 2nd node: SPA served + /api 401 fail-closed + /v2/auth/status 200). Local VM driver exit=0 (assertions pass); throwaway test-local.nix (RAM-trimmed) not committed. nix build .#asmltr OK, flake check --no-build clean.
- M2-A COMPLETE. Pushing for full CI (2-node VM test needs runner RAM+KVM).

- M2-A VERIFIED IN CI: run 30479183329 SUCCESS. flake check built vm-test-run-asmltr-module, booted BOTH nodes (machine + dashboard), all assertions passed (dashboard SPA served + /api 401 fail-closed + /v2/auth/status 200; machine health/managed/loopback/statedir). Aggregate + all packages build.
- ENTIRE nix-packaging branch COMPLETE + CI-green: Phases 0-4 + review fixes (secret-leak + native check) + M2-A (front-door + aggregate + served dashboard). Ready for Phase 5 (reveal PR).
- Before reveal PR: reconcile upstream PRs #30 (announce), #48 (lockfile), #67 (managed-status) — rebase onto #48 if merged (drop 67369d7 0.6.0 backfill); the branch's own lockfile has 8 benign local-package 'resolved' warnings (workspace packages, not cached — fine).

- AUDIT (workflow wf_6b2bf3f2): 22 verified findings (0 crit, 2 high, 7 med, 13 low; 19 after merge). Report /tmp/nix-audit-report.md. Secret-leak fix confirmed clean.
- REBASE onto origin/main 0.9.1 DONE (backup ref nix-packaging-prerebase=d2c0946): clean, no conflicts; #48 MERGED so our interim lockfile backfill 67369d7 auto-dropped ("already upstream"); npmDepsHash re-resolved to sha256-4WwVs28bFkBE5+Q2WI56WKBRY0eWgEJ78QQOxaJpwHw= (commit 1486fa9). Verified green: builds + VOICEOK + NIXOK + native-load + frontdoor unit test on 0.9.1. Front-door mount survived.
- FIX GROUP 1 (agent ab26ce2e, code/security/childEnv): HIGH-1 stream.pipeline error handling + crash test, MEDIUM-4 timeouts (ASMLTR_FRONTDOOR_TIMEOUT_MS), MEDIUM-3 audit->requireControl, LOW-3 collector accepts ASMLTR_CONTROL_TOKEN too, HIGH-2+MEDIUM-2 childEnv spreads parent env to connector children, LOW-5 positive-path gate test. REVIEW security diffs on return.
- FIX GROUP 2 (next): MEDIUM-1 node_modules fileset subtract, MEDIUM-7 drop aarch64 claim, LOW-1 dashboard fileset, LOW-4 CI build aggregate, LOW-6 cache purge scope, MEDIUM-5 pin nix-installer-action, native-load .node assert, LOW-2/7/8/9/10 doc fixes.

- FIX GROUP 1 COMMITTED + verified (agent died on transient 529 but edits complete; controller reviewed security diffs + ran verify green): 36f2f11 (HIGH-1 stream.pipeline + MEDIUM-4 timeouts + crash test), 42546a6 (MEDIUM-3 audit->requireControl + LOW-3 control-token alias), 76a8782 (HIGH-2+MEDIUM-2 childEnv spreads process.env), 38ff6dc (LOW-5 positive-path VM test). frontdoor unit test 0 failures, flake eval clean, build+VOICEOK+NIXOK green. ASMLTR_AUTH_INSECURE_COOKIE confirmed real (core server.js:663).
- FIX GROUP 2 (agent ad54f6f3, nix/CI/docs): MEDIUM-1 node_modules fileset subtract, LOW-1 dashboard fileset, MEDIUM-7 drop aarch64 + meta.platforms=x86_64, native-load .node assert, MEDIUM-5 pin nix-installer-action, LOW-4 CI build aggregate, LOW-6 cache purge scope, LOW-2 announce comment, LOW-7/8/9/10 doc drift. Leak-check + build self-verify. Then final CI + reveal PR ready.

- FIX GROUP 2 COMMITTED + verified (agent also died on transient 529; controller reviewed + verified green): dd34d88 (MEDIUM-1 node_modules + MEDIUM-7 x86_64-only + LOW-1 dashboard fileset + LOW-9), 207307f (native-load .node assert), 1d85e5a (MEDIUM-5 pin @v22 + LOW-4 aggregate + LOW-6 cache), adac9dc (LOW-2/7/8/10 docs). Verified: eval + 4 builds + aarch64 gone + LEAK CANARY PASS (node_modules excluded).
- ALL 19 AUDIT FINDINGS FIXED + committed (8 commits across 2 groups on rebased 0.9.1 base). nix-installer-action@v22 confirmed real. Force-pushed nix-packaging (backup nix-packaging-prerebase). FINAL CI run on adac9dc in progress (aggregate build + pinned installer + native-.node + 2-node VM test w/ positive-path). Then: reveal PR ready.

- FINAL CI GREEN: nix workflow run 30493192482 SUCCESS on adac9dc — Enable KVM + Install Nix(@v22) + Cache + Flake check (2-node VM test incl positive-path + native-.node assert) + Build packages (incl .#asmltr aggregate). AUDIT-CLEAN BRANCH FULLY VERIFIED.
- NOTE: the separate `test` workflow is RED but PRE-EXISTING on origin/main (android-connector.test.js SSE test; main's last 6 runs all fail); NOT caused by our work (we touched no core/). Flag to Jareth separately.
- DONE: rebase + all 19 audit findings fixed + committed (8 commits) + CI-verified. Branch nix-packaging @ adac9dc ready for Phase 5 reveal PR (Gianni's call).
