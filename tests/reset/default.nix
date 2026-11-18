{ inputs ? (builtins.getFlake "git+file://${toString ../..}").inputs
, system ? builtins.currentSystem
, base ? "clean"
}:
let
  pkgs = import inputs.nixpkgs { inherit system; };
  module = import ../../nix/module.nix { inherit inputs; };
in (import ../lib/vm-test.nix { inherit pkgs inputs; }) {
  name = "immutability-reset-${base}";
  nodes.machine = { lib, pkgs, ... }: {
    imports = [ module ];
    virtualisation.emptyDiskImages = [ 1024 ];  # /dev/vdb, the btrfs filesystem under test
    virtualisation.fileSystems = {
      "/" = lib.mkForce { device = "/dev/vdb"; fsType = "btrfs"; options = [ "subvol=@root" ]; };
      "/home" = { device = "/dev/vdb"; fsType = "btrfs"; options = [ "subvol=@home" ]; neededForBoot = true; };
      "/.snapshots" = { device = "/dev/vdb"; fsType = "btrfs"; options = [ "subvol=@snapshots" ]; };
    };
    # The first boot makes the filesystem and its subvolumes, as an installer would; later boots find them.
    boot.initrd.systemd.extraBin."mkfs.btrfs" = "${pkgs.btrfs-progs}/bin/mkfs.btrfs";
    boot.initrd.systemd.extraBin.blkid = "${pkgs.util-linux}/bin/blkid";
    boot.initrd.systemd.services.make-volumes = {
      wantedBy = [ "initrd.target" ];
      requires = [ "dev-vdb.device" ];
      after = [ "dev-vdb.device" ];
      before = [ "immutability.service" "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        [ "$(blkid -o value -s TYPE /dev/vdb)" = btrfs ] && exit 0
        mkfs.btrfs -q /dev/vdb
        mkdir -p /run/make-volumes
        mount -t btrfs -o subvolid=5 /dev/vdb /run/make-volumes
        for volume in @root @home @snapshots @persist; do btrfs subvolume create /run/make-volumes/$volume; done
        ${lib.optionalString (base == "clean") ''
          mkdir -p /run/make-volumes/@root/etc /run/make-volumes/@home/alice
          echo "from the installer" > /run/make-volumes/@root/etc/installed
          chown 1000:100 /run/make-volumes/@home/alice
          chmod 700 /run/make-volumes/@home/alice
          for volume in @root @home; do
            mkdir -p /run/make-volumes/@snapshots/$volume
            btrfs subvolume snapshot -r /run/make-volumes/$volume /run/make-volumes/@snapshots/$volume/CLEAN
          done
        ''}
        umount /run/make-volumes
      '';
    };
    boot.initrd.systemd.extraBin.chown = "${pkgs.coreutils}/bin/chown";
    boot.initrd.systemd.extraBin.chmod = "${pkgs.coreutils}/bin/chmod";
    immutability = {
      enable = true;
      device = "/dev/vdb";
      inherit base;
      mode = "reset";
      after = [ "make-volumes.service" ];
      volumes = [
        { name = "@root"; mountPoint = "/"; resetOnBoot = true; neededForBoot = true; }
        { name = "@home"; mountPoint = "/home"; resetOnBoot = true; neededForBoot = true; }
        { name = "@snapshots"; mountPoint = "/.snapshots"; }
      ];
      persist.paths = [ "/var/keep/" "/etc/keep-file" "/home/alice/kept" ];  # a directory by its slash, a file, and one the user makes
    };
    users.users.alice = { isNormalUser = true; uid = 1000; group = "users"; };
    environment.systemPackages = [ pkgs.btrfs-progs ];
    virtualisation.memorySize = 2048;
  };
  scenario = ./Main.btrc;
  settings = { inherit base; };
}
