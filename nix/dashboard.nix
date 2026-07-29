{ lib, buildNpmPackage, pkgs
, nodejs ? pkgs.${(import ./versions.nix).nodejs}
, dashboardSrc ?
    # closure hygiene: do NOT use `lib.cleanSource ../insights/dashboard`.
    # cleanSource strips only .git/editor-temp/result symlinks; it does NOT honor
    # .gitignore, so a non-flake callPackage build on a developed checkout copies
    # insights/dashboard/{node_modules,dist,.vite} into the src store path — a
    # non-deterministic src hash + closure bloat. Mirror package.nix: allowlist the
    # tracked build inputs, then subtract the gitignored build junk.
    let
      fs = lib.fileset;
      root = ../insights/dashboard;
      wanted = fs.unions [
        (root + "/package.json")
        (root + "/package-lock.json")
        (root + "/index.html")
        (root + "/src")
        (root + "/public")        # PWA assets (icons/manifest/sw.js) vite copies into dist
        (root + "/vite.config.js")
        (root + "/postcss.config.js")
        (root + "/tailwind.config.js")
      ];
      # Gitignored build outputs that live inside the wanted dirs (node_modules is
      # top-level, .vite lives anywhere). maybeMissing: absent on a clean checkout,
      # present on a developed one.
      junk = fs.unions [
        (fs.maybeMissing (root + "/node_modules"))
        (fs.maybeMissing (root + "/dist"))
      ];
    in
    fs.toSource { inherit root; fileset = fs.difference wanted junk; } }:

# NOTE: the source arg is NOT named `src` (same gotcha as nix/package.nix):
# callPackage would autofill `src` from `pkgs.src` (a renamed throwing alias)
# and abort. A repo-specific name is not in the pkgs scope, so callPackage
# falls back to the default below.
buildNpmPackage {
  pname = "asmltr-dashboard";
  version = lib.fileContents ../VERSION;

  # The Vue 3 + Vite SPA, as a lib.fileset of the tracked build inputs (default
  # above) with node_modules/dist subtracted. Overridable so the flake can pass its
  # own filtered source and the non-flake callPackage path still gets a leak-free
  # default.
  src = dashboardSrc;

  # Resolved via the fakeHash loop (nix build → copy the `got:` value). This is
  # the dashboard's OWN lockfile (insights/dashboard/package-lock.json), 207
  # entries, complete — separate from the root workspace hash.
  npmDepsHash = "sha256-gqGynjzEjEgTWpKf81Z4RDjlScA9z4m0wGRA9x4xJFQ=";

  # Node version comes from nix/versions.nix (the one place it is written), shared
  # with the workspace derivation. The dashboard's package.json pins
  # engines.node >=24.0.0; the build output is static HTML/JS/CSS, so the
  # build-node version has no runtime effect.
  inherit nodejs;

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
    # Match the workspace derivation: x86_64-linux is the only real target.
    platforms = [ "x86_64-linux" ];
  };
}
