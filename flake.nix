{
  description = "immutability: btrfs volumes that reset at boot, and the paths that outlive it";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    btrc = { url = "github:schiffy91/btrc"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, btrc }@inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = body: nixpkgs.lib.genAttrs systems body;
      pkgsFor = system: import nixpkgs { inherit system; };
      test = system: path: import path { inherit inputs system; };  # a check is a test's default.nix
    in {
      packages = each (system: rec {
        immutability = (import ./nix/package.nix { pkgs = pkgsFor system; inherit inputs; }).immutability;
        default = immutability;
      });

      nixosModules.default = import ./nix/module.nix { inherit inputs; };

      lib = import ./nix/lib.nix { inherit (nixpkgs) lib; };

      checks = each (system: {
        unit-tool = test system ./tests/unit;
        vm-reset-clean = import ./tests/reset { inherit inputs system; base = "clean"; };
        vm-reset-empty = import ./tests/reset { inherit inputs system; base = "empty"; };
        vm-scale = import ./tests/scale { inherit inputs system; };
      });

      devShells = each (system: {
        default = (pkgsFor system).mkShell { packages = [ btrc.packages.${system}.btrcpy ]; };
      });
    };
}
