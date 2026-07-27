# Single source of truth for the Node.js version across every asmltr derivation
# (workspace + dashboard) and the flake devShell. Bumping Node is a one-line
# change here: edit the attribute name below and every consumer follows.
#
# The value is the nixpkgs attribute name (a string), resolved against `pkgs` by
# each consumer (`pkgs.${(import ./versions.nix).nodejs}`). Kept flake-agnostic
# (no self/inputs), per the nix/ rule, so the non-flake callPackage path and the
# flake path read the identical definition.
{
  nodejs = "nodejs_24";
}
