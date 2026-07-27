{ lib, buildNpmPackage, nodejs_24
, dashboardSrc ? lib.cleanSource ../insights/dashboard }:

# NOTE: the source arg is NOT named `src` (same gotcha as nix/package.nix):
# callPackage would autofill `src` from `pkgs.src` (a renamed throwing alias)
# and abort. A repo-specific name is not in the pkgs scope, so callPackage
# falls back to the default below.
buildNpmPackage {
  pname = "asmltr-dashboard";
  version = lib.fileContents ../VERSION;

  # The Vue 3 + Vite SPA. cleanSource drops .git and result symlinks.
  # Overridable so the flake can pass its own filtered source and the non-flake
  # callPackage path still gets a sensible default.
  src = dashboardSrc;

  # Resolved via the fakeHash loop (nix build → copy the `got:` value). This is
  # the dashboard's OWN lockfile (insights/dashboard/package-lock.json), 207
  # entries, complete — separate from the root workspace hash.
  npmDepsHash = "sha256-gqGynjzEjEgTWpKf81Z4RDjlScA9z4m0wGRA9x4xJFQ=";

  # Node 24: the dashboard's package.json pins engines.node >=24.0.0. This is a
  # separate derivation from the workspace (node 22); the build output is static
  # HTML/JS/CSS, so the build-node version has no runtime effect.
  nodejs = nodejs_24;

  # buildNpmPackage runs `npm run build` (vite build) by default via
  # npmBuildScript = "build". Nothing to override there.

  # The default install runs `npm pack`, which is wrong for a static site. Copy
  # the Vite output (dist/: index.html + assets/) straight to $out instead.
  installPhase = ''
    runHook preInstall
    cp -r dist "$out"
    runHook postInstall
  '';

  meta = {
    description = "asmltr insights observability dashboard (static Vue 3 SPA)";
    platforms = lib.platforms.linux;
  };
}
