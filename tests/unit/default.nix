{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  programs = (inputs.btrc.lib.buildPackage pkgs) {
    name = "immutability-unit-tests";
    src = (import ../lib/test-source.nix { inherit pkgs inputs; }) {
      root = ../..;
      fileset = pkgs.lib.fileset.unions [ ./PathsTests.btrc ./OwnershipTests.btrc ../../src/lib ];
    };
    programs.immutability-paths = "tests/unit/PathsTests.btrc";
    programs.immutability-ownership = "tests/unit/OwnershipTests.btrc";
  };
in pkgs.runCommand "immutability-unit" { } ''
  ${programs}/bin/immutability-paths
  ${programs}/bin/immutability-ownership
  touch $out
''
