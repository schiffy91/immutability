# Reset volumes at boot and keep the paths named to persist. `immutability.*` are this module's options; a
# configuration with settings of its own fills them from those.
{ inputs }:
{ config, lib, pkgs, utils, ... }:
let
	cfg = config.immutability;
	persistKey = (import ./lib.nix { inherit lib; }).persistKey;
	immutabilityBin = (import ./package.nix { inherit pkgs inputs; }).immutability;
	setting = type: default: description: lib.mkOption { inherit type default description; };
	options = with lib.types; {
		enable = setting bool false "Reset the volumes marked `resetOnBoot` at every boot.";
		device = setting str "" "The btrfs filesystem's device, opened if it is encrypted.";
		volumes = setting (listOf (submodule { options = {
			name = lib.mkOption { type = str; };
			mountPoint = lib.mkOption { type = str; };
			resetOnBoot = lib.mkOption { type = bool; default = false; };
			neededForBoot = lib.mkOption { type = bool; default = false; };
		}; })) [] "The filesystem's subvolumes: name, mount point, and which reset.";
		snapshotsSubvolume = setting str "@snapshots" "The subvolume that holds each volume's CLEAN, NEXT and generations.";
		snapshotsMountPoint = setting str "/.snapshots" "Where that subvolume is mounted on the running system.";
		cleanName = setting str "CLEAN" "The name of a volume's read-only base snapshot.";
		base = setting (enum [ "clean" "empty" ]) "clean" "What a reset starts from: the CLEAN snapshot, or a new, empty subvolume.";
		mode = setting (enum [ "converge" "reset" "prepare-only" "publish-prepared" "snapshot-only" "restore-a" "restore-b" "restore-c" "restore-generation" "restore-previous" "restore-penultimate" "disabled" ]) "converge" "What the boot-time run does.";
		dryRun = setting bool false "Log what a run would do and change nothing.";
		enforceOnReboot = setting bool true "Run in the initrd, before the root is mounted.";
		generations = setting ints.unsigned 3 "How many earlier roots are kept as generation-N snapshots.";
		restoreGeneration = setting ints.positive 1 "The generation `restore-generation` goes back to.";
		after = setting (listOf str) [] "Units the boot-time run waits for, such as the one that opens an encrypted device.";
		diffIgnore = setting path ../share/diffignore "Patterns `immutability diff` leaves out, one to a line.";
		persist = {
			enable = setting bool true "Mount the persisted paths.";
			subvolumeRoot = setting str "@persist" "The subvolume that holds what persists.";
			paths = lib.mkOption { type = listOf str; default = []; apply = lib.unique; description = "Paths that outlive a reset."; };
			neededForBoot = setting (listOf str) [] "Persisted directories mounted in the initrd, before activation.";
			required = setting (listOf str) [] "Of those, the ones boot must not go on without.";
		};
		package = lib.mkOption { type = package; readOnly = true; default = immutabilityBin; description = "The tool."; };
	};
	settingsFile = (pkgs.formats.json {}).generate "immutability-settings.json" {
		inherit device cleanName;
		snapshotsSubvolume = snapshotsSubvolumeName;
		inherit (cfg) snapshotsMountPoint base;
		persistRoot = immutabilityPersistRoot;
		specFile = "/etc/immutability/spec.toml";
		diffIgnore = "${cfg.diffIgnore}";
		keepGenerations = nonPersistedGenerations;
		inherit restoreGeneration;
		volumes = map (volume: "${volume.name}=${volume.mountPoint}") resetVolumes;
		persistPaths = pathsToKeep;
	};
	# The layout on disk has a number. A tool reads its own number and every one below it, and brings an
	# older layout up to its own; a higher number was written by a newer generation, and this one must not
	# touch what it cannot read. The word is what generations from before the number look for, so one of
	# them that is booted again still knows this layout; it changes when the number next does.
	immutabilityFormat = 3;
	immutabilityVersion = "2026.11.17";
	immutabilityBase = cfg.base;
	device = cfg.device;
	deviceDependency = "${utils.escapeSystemdPath cfg.device}.device";
	snapshotsSubvolumeName = cfg.snapshotsSubvolume;
	cleanName = cfg.cleanName;
	immutabilityMode = cfg.mode;
	immutabilityPersistRoot = cfg.persist.subvolumeRoot;
	immutabilityDryRun = cfg.dryRun;
	immutabilityEnabled = cfg.enable;
	nonPersistedGenerations = cfg.generations;
	restoreGeneration = cfg.restoreGeneration;
	restoreGenerationMinimum =
		if immutabilityMode == "restore-generation" then restoreGeneration
		else if immutabilityMode == "restore-previous" || immutabilityMode == "restore-a" then 1
		else if immutabilityMode == "restore-penultimate" || immutabilityMode == "restore-b" then 2
		else if immutabilityMode == "restore-c" then 3
		else 0;
	persistenceEnabled = cfg.persist.enable;
	pathsToKeep = cfg.persist.paths;
	homeOwners = lib.mapAttrsToList (_: user: { inherit (user) home name; })
		(lib.filterAttrs (_: user: (user.isNormalUser or false) && user.home != null) config.users.users);
	ancestorsUnderHome = home: path:
		let
			parts = lib.init (lib.splitString "/" (lib.removePrefix "${home}/" path));
			step = state: part:
				let next = "${state.prefix}/${part}";
				in { prefix = next; paths = state.paths ++ [ next ]; };
		in (lib.foldl' step { prefix = home; paths = [ ]; } parts).paths;
	homePersistRules = lib.concatMap (owner:
		map (directory: "d ${directory} - ${owner.name} ${owner.name} -")
			(lib.unique (lib.concatMap (ancestorsUnderHome owner.home)
				(lib.filter (path: lib.hasPrefix "${owner.home}/" path) pathsToKeep)))
	) homeOwners;
	allVolumes = cfg.volumes;
	resetVolumes = lib.filter (volume: volume.resetOnBoot) allVolumes;
	pathDepth = path: builtins.length (lib.splitString "/" (lib.removePrefix "/" path));
	sortPaths = paths: lib.sort (a: b:
		let
			aDepth = pathDepth a;
			bDepth = pathDepth b;
		in if aDepth == bDepth then builtins.stringLength a < builtins.stringLength b else aDepth < bDepth
	) paths;

	pathsForVolume = volume: let
		inherit (volume) mountPoint;
		otherMounts = lib.filter (other: other.mountPoint != mountPoint && other.mountPoint != "/") allVolumes;
	in builtins.filter (path:
			if mountPoint == "/" then
				!(builtins.any (other: path == other.mountPoint || lib.hasPrefix (other.mountPoint + "/") path) otherMounts)
			else path == mountPoint || lib.hasPrefix (mountPoint + "/") path
		) pathsToKeep;

	bootPersistPaths = cfg.persist.neededForBoot;
	bootPersistCandidates = lib.concatMap pathsForVolume resetVolumes;
	bootPersistNested = path: lib.any (other: other != path && lib.hasPrefix (other + "/") path) bootPersistCandidates;
	bootPersistValid = path: lib.elem path bootPersistCandidates && !lib.hasSuffix "/" path && !bootPersistNested path;
	bootPersistFileSystems = lib.genAttrs bootPersistPaths (path: {
		inherit device;
		fsType = "btrfs";
		options = [ "subvol=${immutabilityPersistRoot}/dirs/${persistKey path}" "compress=zstd" "noatime" "x-systemd.after=persistence-mounts.service" ]
			++ lib.optional (!(lib.elem path cfg.persist.required)) "nofail";
		neededForBoot = true;
	});
	bootPersistInitrdMountUnits = map (path: "${utils.escapeSystemdPath "/sysroot${path}"}.mount") bootPersistPaths;

	immutabilityPairArgs = lib.concatMapStringsSep " " (volume:
		lib.escapeShellArg "${volume.name}=${volume.mountPoint}"
	) resetVolumes;
	immutabilityOptions = lib.escapeShellArgs [ "--keep-generations" (toString nonPersistedGenerations) "--restore-generation" (toString restoreGeneration) "--base" immutabilityBase ];
	immutabilityCommandArgs = lib.escapeShellArgs [ device snapshotsSubvolumeName cleanName immutabilityMode immutabilityPersistRoot immutabilitySpecFile ];
	immutabilityResetMountUnits = map (volume: "${utils.escapeSystemdPath volume.mountPoint}.mount") resetVolumes;
	immutabilityVersionDir = "${snapshotsSubvolumeName}/.immutability";
	immutabilityVersionFile = "${immutabilityVersionDir}/version";
	immutabilityVersionPreflight = ''
		immutability_version_top="/run/immutability-version-top"
		immutability_version_dir="$immutability_version_top/${immutabilityVersionDir}"
		immutability_version_file="$immutability_version_top/${immutabilityVersionFile}"
		immutability_format_file="$immutability_version_top/${immutabilityVersionDir}/format"
		immutability_version_cleanup() {
			umount "$immutability_version_top" 2>/dev/null || true
			rmdir "$immutability_version_top" 2>/dev/null || true
		}
		trap immutability_version_cleanup EXIT
		mkdir -p "$immutability_version_top"
		mount -t btrfs -o subvolid=5 ${lib.escapeShellArg device} "$immutability_version_top"

		# A boot that does not reset goes on, so that an earlier generation can still be booted, and says so
		# where it is seen afterwards: immutability-refused.service fails with these words.
		immutability_refuse() {
			echo "immutability: NOT RESET: $1" >&2
			printf '%s\n' "$1" > /run/immutability-refused
			exit 1
		}
		immutability_found=0
		if [ -f "$immutability_format_file" ]; then
			IFS= read -r immutability_found < "$immutability_format_file" || true
		elif [ -f "$immutability_version_file" ]; then
			IFS= read -r immutability_word < "$immutability_version_file" || true
			case "$immutability_word" in
				"") immutability_found=0 ;;
				"0.1") immutability_found=1 ;;
				"2026.08.22") immutability_found=2 ;;
				"2026.11.17") immutability_found=3 ;;
				*) immutability_refuse "the volumes on this disk are in a layout this generation does not know ($immutability_word), so they were left as they are. Boot the generation that last ran, or a newer one." ;;
			esac
		fi
		case "$immutability_found" in
			""|*[!0-9]*) immutability_refuse "the layout number on this disk cannot be read ($immutability_found), so the volumes were left as they are." ;;
		esac
		if [ "$immutability_found" -gt ${toString immutabilityFormat} ]; then
			immutability_refuse "the volumes on this disk are in layout $immutability_found, written by a newer generation; this one reads up to ${toString immutabilityFormat} and left them as they are. Boot that generation, or a newer one."
		fi
	'';
	# The mount taken above is kept until the root is mounted (immutability-release lets it go). Unmounting
	# here would be the filesystem's last mount going away: the kernel then finishes the subvolumes the
	# reset just deleted, close to three seconds on a real root, and the root's own mount starts from
	# nothing again. The version is written only when it changes, so an ordinary boot waits for no sync.
	immutabilityVersionCommit = ''
		if [ "$immutability_found" != ${toString immutabilityFormat} ] || [ ! -f "$immutability_format_file" ]; then
			mkdir -p "$immutability_version_dir"
			printf '%s\n' ${lib.escapeShellArg immutabilityVersion} > "$immutability_version_file"
			printf '%s\n' ${toString immutabilityFormat} > "$immutability_format_file"
			sync "$immutability_format_file" || sync
		fi
		trap - EXIT
	'';
	immutabilityVersionFinish = if immutabilityDryRun then ''
		immutability_version_cleanup
		trap - EXIT
	'' else immutabilityVersionCommit;
	immutabilitySpecFile = (pkgs.formats.toml {}).generate "immutability-spec.toml" {
		keep = lib.concatMap (volume:
			map (path: {
				inherit path;
				kind = "auto";
				mountPoint = volume.mountPoint;
				volume = volume.name;
			}) (sortPaths (pathsForVolume volume))
		) resetVolumes;
	};

in
{
	options.immutability = options;
	config = lib.mkMerge [
		(lib.mkIf (persistenceEnabled || immutabilityEnabled) {
			assertions = [
				{
					assertion = !immutabilityEnabled || restoreGenerationMinimum <= nonPersistedGenerations;
					message = "settings.disk.immutability.nonPersistedGenerations must keep enough generations for settings.disk.immutability.mode";
				}
			];
			environment.systemPackages = [ immutabilityBin ];
			environment.etc."immutability/spec.toml".source = immutabilitySpecFile;
			environment.etc."immutability/settings.json".source = settingsFile;
			systemd.services."persistence-mounts" = {
				description = "Mount persistent BTRFS subvolumes into place";
				wantedBy = lib.optionals persistenceEnabled [ "local-fs.target" ];
				requires = [ deviceDependency ] ++ immutabilityResetMountUnits;
				after = [ deviceDependency ] ++ immutabilityResetMountUnits;
				before = [ "local-fs.target" ];
				unitConfig.DefaultDependencies = "no";
				serviceConfig = {
					Type = "oneshot";
					RemainAfterExit = true;
				};
				path = with pkgs; [ btrfs-progs coreutils util-linux ];
				script = ''
					umount /run/immutability-version-top 2>/dev/null && rmdir /run/immutability-version-top 2>/dev/null || true  # should the initrd have left the reset's mount
					${immutabilityBin}/bin/immutability ${lib.optionalString immutabilityDryRun "--dry-run "}mount ${lib.escapeShellArg device} ${lib.escapeShellArg immutabilityPersistRoot} ${immutabilitySpecFile}
				'';
			};
		})
		(lib.mkIf persistenceEnabled {
			assertions = [
				{
					assertion = lib.all bootPersistValid bootPersistPaths;
					message = "settings.disk.immutability.persist.neededForBoot entries must be top-level persisted directories (no trailing slash) on a resetOnBoot volume";
				}
			];
			fileSystems = bootPersistFileSystems;
			systemd.tmpfiles.rules = homePersistRules;
			boot.initrd.systemd.services.initrd-nixos-activation.after = bootPersistInitrdMountUnits;
		})
		(lib.mkIf (immutabilityEnabled && cfg.enforceOnReboot) {
			systemd.services.immutability-refused = {  # a boot without its reset shows as a failed unit, with the reason
				description = "The volumes were not reset at this boot";
				wantedBy = [ "multi-user.target" ];
				unitConfig.ConditionPathExists = "/run/immutability-refused";
				serviceConfig = {
					Type = "oneshot";
					ExecStart = "${pkgs.bash}/bin/sh -c 'cat /run/immutability-refused >&2; exit 1'";
				};
			};
		})
		(lib.mkIf (immutabilityEnabled && immutabilityBase == "empty") {
			systemd.services.immutability-marker = {  # `nixosctl diff` lists what changed after this
				description = "Record where the reset volumes stood when boot finished";
				wantedBy = [ "multi-user.target" ];
				after = [ "multi-user.target" ];
				serviceConfig = {
					Type = "oneshot";
					RemainAfterExit = true;
					RuntimeDirectory = "immutability";
					RuntimeDirectoryPreserve = true;
				};
				path = with pkgs; [ btrfs-progs coreutils gnused ];
				script = ''
					for pair in ${immutabilityPairArgs}; do
						btrfs filesystem sync "''${pair#*=}"
						transaction=$(btrfs subvolume find-new "''${pair#*=}" 9999999 | sed -n 's/^transid marker was //p')
						[ -n "$transaction" ]
						printf '%s %s\n' "''${pair%%=*}" "$transaction"
					done > /run/immutability/marker.new
					mv /run/immutability/marker.new /run/immutability/marker
				'';
			};
		})
		(lib.mkIf (immutabilityEnabled && cfg.enforceOnReboot) {
			fileSystems = lib.mkMerge (lib.lists.forEach (lib.filter (volume: volume.neededForBoot) cfg.volumes) (volume: { "${volume.mountPoint}".neededForBoot = lib.mkForce true; }));
			boot = {
				nixStoreMountOpts = [ "ro" ];
				initrd = {
					supportedFilesystems = [ "btrfs" ];
					systemd = {
						storePaths = [ "${immutabilityBin}" immutabilitySpecFile ];
							extraBin = {
								btrfs = "${pkgs.btrfs-progs}/bin/btrfs";
								cp = "${pkgs.coreutils}/bin/cp";
								mkdir = "${pkgs.coreutils}/bin/mkdir";
								mv = "${pkgs.coreutils}/bin/mv";
								rmdir = "${pkgs.coreutils}/bin/rmdir";
								sync = "${pkgs.coreutils}/bin/sync";
								findmnt = "${pkgs.util-linux}/bin/findmnt";
								mount = lib.mkDefault "${pkgs.util-linux}/bin/mount";
								umount = lib.mkDefault "${pkgs.util-linux}/bin/umount";
							};
						services."immutability" = {
							description = "Factory resets BTRFS subvolumes using persistent keep subvolumes";
							wantedBy = [ "initrd.target" ];
							requires = [ deviceDependency ];
							after = cfg.after ++ [ deviceDependency "systemd-hibernate-resume.service" ];  # never reset under a hibernated kernel
							before = [ "sysroot.mount" ];
								unitConfig.DefaultDependencies = "no";
								serviceConfig.Type = "oneshot";
								script = ''
									${immutabilityVersionPreflight}
									${immutabilityBin}/bin/immutability ${lib.optionalString immutabilityDryRun "--dry-run "}${immutabilityOptions} ${immutabilityCommandArgs} ${immutabilityPairArgs} \
										|| immutability_refuse "the reset did not finish (see immutability.service in this boot's journal), so the volumes may hold what the last boot left."
									${immutabilityVersionFinish}
								'';
							};
						services."immutability-release" = {
							description = "Let go of the mount the reset held until the root was mounted";
							wantedBy = [ "initrd.target" ];
							after = [ "sysroot.mount" "immutability.service" ];
							before = [ "initrd-switch-root.target" ];
							unitConfig.DefaultDependencies = "no";
							serviceConfig.Type = "oneshot";
							script = ''
								umount /run/immutability-version-top 2>/dev/null || true
								rmdir /run/immutability-version-top 2>/dev/null || true
							'';
						};
					};
				};
			};
			})
	];
}
