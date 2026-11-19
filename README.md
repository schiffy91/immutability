# immutability

btrfs volumes that reset at every boot, and the paths that outlive it. A NixOS module and the one
program behind it: in the initrd it puts each reset volume back to its base, keeps the root before it as a
generation, and puts the persisted paths in place; on the running system it mounts what persists and
answers what changed.

## Using it

```nix
inputs.immutability = { url = "github:schiffy91/immutability"; inputs.nixpkgs.follows = "nixpkgs"; inputs.btrc.follows = "btrc"; };

# in a NixOS configuration
imports = [ inputs.immutability.nixosModules.default ];
immutability = {
  enable = true;
  device = "/dev/mapper/root";
  volumes = [
    { name = "@root"; mountPoint = "/"; resetOnBoot = true; neededForBoot = true; }
    { name = "@home"; mountPoint = "/home"; resetOnBoot = true; neededForBoot = true; }
    { name = "@snapshots"; mountPoint = "/.snapshots"; }
  ];
  persist.paths = [ "/etc/machine-id" "/var/log" "/home/me/Documents" ];
};
```

The module does not make or mount the volumes: the configuration's `fileSystems` (or an installer) does.
A configuration with settings of its own fills these options from them; schiffy91/nixos does so in
`config/system/storage/immutability`.

| Option | Default | What |
|---|---|---|
| `enable` | `false` | Reset the volumes marked `resetOnBoot` at every boot |
| `device` | | The btrfs filesystem's device, opened if it is encrypted |
| `volumes` | `[]` | The subvolumes: `name`, `mountPoint`, `resetOnBoot`, `neededForBoot` |
| `snapshotsSubvolume`, `snapshotsMountPoint` | `@snapshots`, `/.snapshots` | Where each volume's `CLEAN`, `NEXT` and generations are |
| `base` | `clean` | What a reset starts from: `clean`, the read-only `CLEAN` snapshot; or `empty`, a new subvolume |
| `mode` | `converge` | What the boot-time run does: `converge`/`reset`, `prepare-only`, `publish-prepared`, `snapshot-only`, `restore-previous`/`-a`, `restore-penultimate`/`-b`, `restore-c`, `restore-generation`, `disabled` |
| `generations` | `3` | How many earlier roots are kept as `generation-N` |
| `restoreGeneration` | `1` | The generation `restore-generation` goes back to |
| `after` | `[]` | Units the boot-time run waits for, such as the one that opens an encrypted device |
| `dryRun`, `enforceOnReboot` | `false`, `true` | Log only; run in the initrd |
| `persist.enable` | `true` | Mount the persisted paths |
| `persist.paths` | `[]` | Paths that outlive a reset. A directory is a subvolume under `persist.subvolumeRoot` mounted in place; a file is copied back at each reset. A trailing slash says directory before the path exists |
| `persist.neededForBoot`, `persist.required` | `[]` | Persisted directories mounted in the initrd, and of those the ones boot must not go on without |
| `diffIgnore` | `share/diffignore` | Patterns `immutability diff` leaves out |

With `base = "empty"` there is no `CLEAN`: an installer takes none, and a directory made on the way to a
persisted path takes its owner and mode from the same directory in the root before it, so a home folder
stays its user's. A path that should outlive a reboot is persisted on either base.

The reset holds the filesystem mounted from its own start until the root is mounted, and a small unit
after that lets its mount go. Unmounting between the two would be the filesystem's last mount going
away: the kernel then finishes the subvolumes the reset has just deleted, which took close to three
seconds on a real root, and the root's own mount starts from nothing again.

## Commands

The boot-time run is given everything as arguments by the module. The commands a person runs read
`/etc/immutability/settings.json`, which the module writes (`--settings <file>` names another):

| Command | What |
|---|---|
| `immutability diff [--recent] [--depth N] [--pattern P] [--show-persist-paths] [--show-children P] [--show-symlinks] [--diffignore F]` | What changed on the reset volumes: against `CLEAN`, or with an empty base since `immutability-marker.service` recorded each volume's transaction when boot finished |
| `immutability plan` | What a reset would keep, and from which base |
| `immutability prepare [--dry-run]` | Build `NEXT` now, without publishing it |
| `immutability materialize [--dry-run] [--refresh-clean]` | Copy what is persisted back into the volumes; `--refresh-clean` then takes `CLEAN` anew, and is refused on an empty base |
| `immutability gc [--older-than DAYS] [--delete]` | List what nothing removes by itself: the stores of paths no longer persisted that were set aside at least DAYS ago (30 unless given), slots of earlier layouts (`CURRENT`, `PREVIOUS`, `PENULTIMATE`) and folders a migration left (`migrate-*`). `--delete` deletes what is listed. `CLEAN`, the kept roots and anything it does not know are never among them |
| `immutability snapshots create [--root <dir> --base B --snapshots-mount P --clean-name N name=mount ...]` | Take each reset volume's `CLEAN`. An installer names everything itself and gives the root it installed into |

The layout on disk has a number, kept in `.immutability/format` under the snapshots subvolume (3 today).
A generation reads its own number and every one below it, and brings an older layout up to its own. A
higher number was written by a newer generation: this one then resets nothing, because it cannot know
what it would be deleting, and the boot goes on, so that an earlier generation can always be booted
again. Such a boot says so: `/run/immutability-refused` holds the reason and
`immutability-refused.service` fails with it, as it does when the reset itself did not finish. The word
in `.immutability/version` is what generations from before the number look for; it stays the one they
know for as long as the layout is one they can read.

## Tests

`nix flake check` builds them. `unit-tool` runs the path and ownership suites. `vm-reset-clean` and
`vm-reset-empty` boot a machine whose root and home are btrfs subvolumes made on its first boot, and reset
it for real: a layout newer than the generation, an unknown one and an unreadable one are each left alone by a boot that goes on and says so, an older one is brought up, the filesystem is mounted once per boot, persisted paths and their owners outlive a reset and the rest is gone, the root before it is a
generation, a store nothing names is set aside, `gc` lists and then deletes an old one with an earlier layout's slot and a migration's folder while today's stays, a generation is put back, a folder holding a file that
cannot be cloned (no-copy-on-write, as a database or a search index is) is persisted both at once and at
the next boot, and `diff`, `plan`, `materialize` and `snapshots` work from the settings. The VM checks
need KVM.

`ci/local.json` names what the owner's machine runs for a commit (`lint`, `unit`, `vm`), recorded with
[`ci-local`](https://github.com/schiffy91/ci-local); hosted CI runs what has no local pass.

## Layout

| Path | What |
|---|---|
| `src/Immutability.btrc`, `src/lib/` | The program, in [BTRC](https://github.com/schiffy91/btrc) |
| `nix/module.nix`, `nix/package.nix`, `nix/lib.nix` | The module, the package, and `lib.persistKey` (a persisted path's subvolume name) |
| `share/diffignore` | The default patterns for `diff` |
| `tests/unit`, `tests/reset` | The suites above |

Not proven here: an encrypted device, hibernation, and an installer's own layout. Those are tested where a
configuration uses the module, in schiffy91/nixos (install, host boot, recovery and hibernate scenarios).
