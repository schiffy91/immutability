# The guest every VM scenario here boots: a second disk whose btrfs subvolumes reset at boot, made on the
# first boot as an installer would make them, with the persisted paths the scenario names.
{ module, base, paths }: { lib, pkgs, ... }: {
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
    persist.paths = paths;
  };
  users.users.alice = { isNormalUser = true; uid = 1000; group = "users"; };
  environment.systemPackages = [ pkgs.btrfs-progs pkgs.e2fsprogs ];  # chattr marks a file no-copy-on-write
  virtualisation.memorySize = 2048;
}
