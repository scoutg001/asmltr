{ lib, stdenv, buildNpmPackage, nodejs_22, python3, node-gyp, autoPatchelfHook
, asmltrSrc ? lib.cleanSource ../. }:

# NOTE: the source arg is NOT named `src`; callPackage would try to autofill it
# from `pkgs.src` (a renamed throwing alias) and abort. A repo-specific name is
# not in the pkgs scope, so callPackage falls back to the default below.
buildNpmPackage {
  pname = "asmltr-workspace";
  version = lib.fileContents ../VERSION;

  # The repo this file lives in. cleanSource drops .git and result symlinks.
  # Overridable so the flake can pass its own filtered source and the non-flake
  # callPackage path still gets a sensible default.
  src = asmltrSrc;

  # Resolved via the fakeHash loop (nix build → copy the `got:` value).
  npmDepsHash = "sha256-fv4HodS2a1T3pBoN402CTb56PCxEFH5rLCzM5nb+nc8=";

  # Node 22 LTS: nodejs_20 (20.20.2) is EOL and flagged insecure in current nixpkgs
  # (and has no binary cache, forcing a from-source V8 compile). 22 is cached and
  # builds better-sqlite3 11.10.0 cleanly. The smoke turn's code path loads no native
  # module, so build-node ABI does not affect it.
  nodejs = nodejs_22;

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

  # node-gyp wants the node prefix that contains include/node/node.h, i.e. ${nodejs_22}
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

    npm rebuild better-sqlite3 --build-from-source --nodedir=${nodejs_22}
    npm rebuild @discordjs/opus --build-from-source --nodedir=${nodejs_22}
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
