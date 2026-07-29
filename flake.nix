{
  description = "asmltr — channel-agnostic assistant backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      # Node version comes from nix/versions.nix, the same definition the non-flake
      # callPackage path reads, so both paths resolve to the identical node.
      nodeAttr = (import ./nix/versions.nix).nodejs;
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          asmltr-workspace = pkgs.callPackage ./nix/package.nix { nodejs = pkgs.${nodeAttr}; };
          asmltr-dashboard = pkgs.callPackage ./nix/dashboard.nix { nodejs = pkgs.${nodeAttr}; };
          # The aggregate: workspace tree + dashboard dist in one closure (nix/aggregate.nix).
          # This is the closure Phase 5's release artifact exports, so it is the default.
          asmltr = pkgs.callPackage ./nix/aggregate.nix { nodejs = pkgs.${nodeAttr}; };
          default = self.packages.${system}.asmltr;
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = [ pkgs.${nodeAttr} pkgs.python3 pkgs.node-gyp pkgs.pkg-config ];
          };
        });

      # The deployable systemd module (nix/module.nix, imported verbatim — flake-agnostic).
      nixosModules.asmltr = import ./nix/module.nix;

      # `nix flake check` builds these:
      #   module      — a QEMU VM boots the three services with the Nix-built
      #                 workspace and asserts /health + managed:true (nix/test.nix).
      #   native-load — dlopens @discordjs/opus + @picovoice/porcupine-node from the
      #                 built tree so a broken native rebuild fails CI (nix/native-load.nix).
      checks = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          module = import ./nix/test.nix { inherit pkgs; };
          native-load = import ./nix/native-load.nix { inherit pkgs; };
        });
    };
}
