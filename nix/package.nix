{ lib, buildNpmPackage, nodejs_22, python3, node-gyp, asmltrSrc ? lib.cleanSource ../. }:

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

  # Defer voice native builds: skip ALL install scripts, then rebuild only the
  # native module core actually needs (better-sqlite3). @discordjs/opus and
  # @picovoice/porcupine-node stay present-but-unbuilt; core never loads them,
  # so a text turn works. Phase 2 removes --ignore-scripts and handles them.
  npmFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [ python3 node-gyp ];

  # The backend workspaces are plain node; there is no build/compile step.
  dontNpmBuild = true;

  # node-gyp wants the node prefix that contains include/node/node.h, i.e. ${nodejs_22}
  # itself (NOT .../include/node). better-sqlite3 is the one native module core needs;
  # the config hook's `npm rebuild --ignore-scripts` leaves every native dep unbuilt,
  # so we compile only better-sqlite3 here and the voice deps stay deferred.
  postBuild = ''
    npm rebuild better-sqlite3 --build-from-source --nodedir=${nodejs_22}
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
