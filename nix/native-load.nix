# checks.<system>.native-load — proves the two voice native bindings actually LOAD
# from the Nix-built workspace tree. `nix flake check`/CI otherwise never dlopens
# @discordjs/opus or @picovoice/porcupine-node (the nixosTest boots the services but
# their moderation/voice paths are lazy), so a broken native rebuild would ship green.
# This derivation builds the workspace and runs the build's node against the built
# tree; if either native addon fails to load, the run throws and the derivation fails.
#
# It reuses nix/smoke-voice.sh as the single source of the load proof: constructing an
# OpusEncoder forces the source-built opus .node to dlopen, and constructing a Porcupine
# with a dummy key forces the autopatched porcupine prebuilt to load (a key/activation
# error is proof-of-load; an ELF/loader error is the failure it guards against).
#
# Flake-agnostic: takes `pkgs`, resolves node + package the same single-source way
# (nix/versions.nix) as the module and the package.
{ pkgs }:

let
  nodejs = pkgs.${(import ./versions.nix).nodejs};
  workspace = pkgs.callPackage ./package.nix { inherit nodejs; };
in
pkgs.runCommand "asmltr-native-load" { nativeBuildInputs = [ nodejs ]; } ''
  # BUILT = the installed workspace tree in the store; NODE = the build's node (same
  # ABI the opus/porcupine binaries were compiled/patched against). Both override the
  # smoke's own discovery so the check is explicit and store-path-hermetic.
  export BUILT="${workspace}/lib/node_modules/asmltr"
  export NODE="${nodejs}/bin/node"
  bash ${./smoke-voice.sh}
  touch $out
''
