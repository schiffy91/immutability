{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
, base ? "clean"
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  module = import ../../nix/module.nix { inherit inputs; };
in (import ../lib/vm-test.nix { inherit pkgs inputs; }) {
  name = "immutability-reset-${base}";
  nodes.machine = import ../lib/machine.nix {
    inherit module base;
    paths = [ "/var/keep/" "/var/two words/" "/etc/keep-file" "/home/alice/kept" "/var/index-live" "/var/index-boot" ];  # by its slash, one with a space, a file, one the user makes, two with a file that cannot be cloned
  };
  scenario = ./Main.btrc;
  settings = { inherit base; };
}
