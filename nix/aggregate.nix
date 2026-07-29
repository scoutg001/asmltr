# nix/aggregate.nix — the `asmltr` aggregate: ONE closure that bundles the built
# workspace tree together with the dashboard's static `dist/` at a predictable
# subpath, so a single store path carries everything a deploy needs. This is the
# closure Phase 5's release artifact exports.
#
# Layout under $out:
#   lib/node_modules/asmltr   → the workspace tree (symlink to nix/package.nix out)
#   share/asmltr/dashboard    → the dashboard dist/ (symlink to nix/dashboard.nix out)
#
# The dashboard path is the value the module hands the collector as
# ASMLTR_DASHBOARD_DIST to turn the front door on; keeping it at a fixed,
# documented subpath means anything consuming this closure (the release tarball,
# an operator, a future single-service unit) finds the SPA the same way.
#
# FLAKE-AGNOSTIC (the nix/ rule): no `self`, no `inputs`. Node + the two component
# derivations resolve through callPackage + versions.nix, the same single-source
# pattern package.nix/dashboard.nix/module.nix use, so the flake path and the bare
# `callPackage ./nix/aggregate.nix {}` path build the identical thing.
{ lib, pkgs, runCommand
, nodejs ? pkgs.${(import ./versions.nix).nodejs}
, workspace ? pkgs.callPackage ./package.nix { inherit nodejs; }
, dashboard ? pkgs.callPackage ./dashboard.nix { inherit nodejs; }
}:

runCommand "asmltr-${lib.fileContents ../VERSION}"
  {
    # Expose the components so a consumer (the module, the flake, a release script)
    # can reach either half without re-deriving it.
    passthru = { inherit workspace dashboard nodejs; };
    meta = {
      description = "asmltr aggregate — workspace bundle + dashboard dist in one closure";
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p "$out/lib/node_modules" "$out/share/asmltr"
    # Symlink both halves in: the aggregate's closure references each component
    # store path, so the workspace's node_modules + the dashboard dist ship together.
    ln -s "${workspace}/lib/node_modules/asmltr" "$out/lib/node_modules/asmltr"
    ln -s "${dashboard}" "$out/share/asmltr/dashboard"
  ''
