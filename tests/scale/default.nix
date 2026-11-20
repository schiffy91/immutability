{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
, base ? "empty"
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  inherit (pkgs) lib;
  module = import ../../nix/module.nix { inherit inputs; };
  count = { folders = 50; files = 30; made = 20; };  # a hundred, in about the mix the real machines have
  numbered = amount: path: lib.genList (index: path (toString (index + 1))) amount;
in (import ../lib/vm-test.nix { inherit pkgs inputs; }) {
  name = "immutability-scale-${base}";
  nodes.machine = import ../lib/machine.nix {
    inherit module base;
    paths = numbered count.folders (n: "/var/lib/scale/folder-${n}/")
      ++ numbered count.files (n: "/etc/scale/file-${n}")
      ++ numbered count.made (n: "/home/alice/made-${n}");
  };
  scenario = ./Main.btrc;
  settings = count // {
    inherit base;
    # Seconds and counts, as words. Measured on 19 Nov 2026 with a child for each path: reset 1.36 s, mounts
    # 2.80 s. Now: 0.59 s and 0.16 s, with 26 and 4 children. The seconds leave room for a loaded machine.
    ceilings = { resetTool = "1.2"; resetUnit = "1.3"; mountsTool = "0.8"; mountsUnit = "0.9"; resetChildren = "40"; mountsChildren = "6"; };
  };
}
