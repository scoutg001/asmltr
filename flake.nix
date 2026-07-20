{
  description = "asmltr — channel-agnostic assistant backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          asmltr-workspace = pkgs.callPackage ./nix/package.nix { };
          default = self.packages.${system}.asmltr-workspace;
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = [ pkgs.nodejs_20 pkgs.python3 pkgs.node-gyp pkgs.pkg-config ];
          };
        });

      # Real module lands in Phase 4; exported now so the output schema is stable.
      nixosModules.asmltr = import ./nix/module.nix;
    };
}
