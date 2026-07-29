{ lib, stdenv, buildNpmPackage, pkgs, python3, node-gyp, autoPatchelfHook
, nodejs ? pkgs.${(import ./versions.nix).nodejs}
, asmltrSrc ?
    # SECURITY + closure: do NOT use `lib.cleanSource ../.`. cleanSource does NOT
    # honor .gitignore, so a non-flake callPackage build on the real asmltr checkout
    # copies gitignored secrets (.env, connectors/types/mcp/clients.json,
    # connectors/types/openai/keys.json, core/src/trust/seed.json, CLAUDE.local.md)
    # into the world-readable /nix/store, bloats the closure with docs/site/DBs, and
    # makes the src hash non-reproducible. Instead include ONLY the paths the workspace
    # build (npm ci over the root lockfile + the four workspaces) and the three services
    # read at runtime, then subtract the gitignored secrets/data that live inside them.
    let
      fs = lib.fileset;
      wanted = fs.unions [
        # Root manifests buildNpmPackage resolves deps + version from.
        ../package.json
        ../package-lock.json
        ../VERSION
        # The four workspaces named in package.json "workspaces".
        ../core
        ../connectors
        ../cli
        ../insights/collector
        # Non-workspace source the servers require() at load/runtime:
        ../shared        # every server: require('../../shared/...') — core breaks at runtime without it
        ../integrations  # core/src/server.js:52 require('../../integrations/registry') (top-level)
        ../scripts       # core/src/server.js:828 + cli/asmltr.js:631 require('../../scripts/backup') (top-level)
        ../setup.d       # scripts/run-setup-steps.js reads REPO/setup.d on the restore/setup path
      ];
      # Gitignored secrets + runtime data dirs that live INSIDE the wanted dirs above;
      # cleanSource would have shipped them. Subtract explicitly. maybeMissing: absent
      # on a clean checkout, present on a live install. (Root .env/.env.*/CLAUDE.local.md
      # are already excluded — they are not under any wanted dir.)
      secretsAndData = fs.unions [
        (fs.maybeMissing ../connectors/types/mcp/clients.json)
        (fs.maybeMissing ../connectors/types/openai/keys.json)
        (fs.maybeMissing ../connectors/types/discord/channel-aliases.json)
        (fs.maybeMissing ../core/src/trust/seed.json)
        (fs.maybeMissing ../core/data)
        (fs.maybeMissing ../connectors/manager/data)
        (fs.maybeMissing ../insights/collector/data)
      ];
      # Drop every *.md that lives inside a wanted dir (e.g. a package README). None is
      # read at runtime; keeps the closure to code + manifests.
      mdFiles = fs.fileFilter (f: f.hasExt "md") ../.;
    in
    fs.toSource {
      root = ../.;
      fileset = fs.difference wanted (fs.unions [ secretsAndData mdFiles ]);
    }
}:

# NOTE: the source arg is NOT named `src`; callPackage would try to autofill it
# from `pkgs.src` (a renamed throwing alias) and abort. A repo-specific name is
# not in the pkgs scope, so callPackage falls back to the default below.
buildNpmPackage {
  pname = "asmltr-workspace";
  version = lib.fileContents ../VERSION;

  # A lib.fileset source (default above) containing only the workspace build +
  # runtime inputs, with gitignored secrets/data subtracted. Overridable so the
  # flake can pass its own filtered source and the non-flake callPackage path still
  # gets a sensible, leak-free default.
  src = asmltrSrc;

  # Resolved via the fakeHash loop (nix build → copy the `got:` value).
  npmDepsHash = "sha256-fv4HodS2a1T3pBoN402CTb56PCxEFH5rLCzM5nb+nc8=";

  # Node version comes from nix/versions.nix (the one place it is written); the
  # workspace and dashboard share that definition. insights/collector and
  # insights/dashboard both pin engines.node >=24, so the tree unifies on Node 24,
  # which is prebuilt in cache.nixos.org (a download, not a V8 compile) and builds
  # better-sqlite3 11.10.0 cleanly. The smoke turn's code path loads no native
  # module, so build-node ABI does not affect it.
  inherit nodejs;

  # Skip ALL npm install scripts, then rebuild the native modules ourselves in
  # postBuild. We keep --ignore-scripts (rather than letting scripts run) for one
  # reason: @discordjs/opus's install script is `node-pre-gyp install
  # --fallback-to-build`, which first tries to DOWNLOAD a prebuilt from
  # github.com/discordjs/opus/releases. The Nix build phase has no network, so an
  # unguarded install would attempt (and stall/fail on) that fetch. A targeted
  # `npm rebuild ... --build-from-source` skips the download and compiles instead.
  # @picovoice/porcupine-node has NO install script at all: its prebuilt
  # pv_porcupine.node ships inside the npm tarball, so nothing to download and
  # nothing to rebuild; autoPatchelfHook fixes the prebuilt's interpreter + RPATH.
  npmFlags = [ "--ignore-scripts" ];

  # autoPatchelfHook runs in postFixup over $out and rewrites every ELF's
  # interpreter/RPATH: the porcupine prebuilt .node, plus the opus/better-sqlite3
  # .node we compile below (harmless re-confirm for the source builds).
  nativeBuildInputs = [ python3 node-gyp autoPatchelfHook ];

  # ELF deps of the porcupine prebuilt (libstdc++.so.6, libgcc_s.so.1) beyond
  # glibc. stdenv.cc.cc.lib carries both; glibc (libc/libm/libpthread/librt/libdl)
  # is always on the autopatchelf search path.
  buildInputs = [ stdenv.cc.cc.lib ];

  # The backend workspaces are plain node; there is no build/compile step.
  dontNpmBuild = true;

  # node-gyp wants the node prefix that contains include/node/node.h, i.e. ${nodejs}
  # itself (NOT .../include/node). --build-from-source sets npm_config_build_from_source,
  # which makes node-pre-gyp (opus) skip its remote download and compile; better-sqlite3
  # honours the same flag. opus vendors its own libopus C source (deps/opus), so the
  # build is self-contained and needs no system opus.
  postBuild = ''
    # Porcupine ships a prebuilt pv_porcupine.node for every platform. We target
    # x86_64 Linux; drop the foreign-arch ELF binaries (raspberry-pi aarch64/arm)
    # so autoPatchelfHook doesn't try to resolve arm deps against an x86_64 sysroot
    # and fail. The mac (.node = Mach-O) and windows (.node = PE) blobs are non-ELF
    # and autopatchelf skips them; prune them too to keep the closure lean.
    for libdir in $(find . -type d -path '*/@picovoice/porcupine-node/lib'); do
      rm -rf "$libdir/raspberry-pi" "$libdir/mac" "$libdir/windows"
    done

    # `npm rebuild @discordjs/opus` runs the package's install script, which is
    # `node-pre-gyp install`. The @discordjs/node-pre-gyp bin still carries a
    # `#!/usr/bin/env node` shebang the config hook left unpatched, so `sh` aborts
    # with `bad interpreter`. Re-point every installed node_modules shebang at the
    # build's node before the rebuilds. (better-sqlite3 dodged this: its node-gyp
    # comes from nativeBuildInputs, already patched.)
    for nm in node_modules connectors/node_modules; do
      [ -d "$nm" ] && patchShebangs "$nm"
    done

    npm rebuild better-sqlite3 --build-from-source --nodedir=${nodejs}
    npm rebuild @discordjs/opus --build-from-source --nodedir=${nodejs}
  '';

  # Ship the ENTIRE workspace tree. The stock npmInstallHook runs `npm pack` (which
  # drops node_modules at every level) and then copies only the hoisted top-level
  # node_modules, discarding the per-workspace nested node_modules where the lockfile
  # places better-sqlite3, plus its freshly compiled .node. A whole-tree copy keeps
  # the nested modules, the compiled better-sqlite3, and the source in one place.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/node_modules/asmltr"
    cp -r . "$out/lib/node_modules/asmltr/"
    # Point any bundled CLI shebangs (e.g. the Agent SDK) at the build's node.
    patchShebangs "$out/lib/node_modules/asmltr"
    runHook postInstall
  '';

  meta = {
    description = "asmltr channel-agnostic assistant backend (workspace bundle)";
    platforms = lib.platforms.linux;
  };
}
