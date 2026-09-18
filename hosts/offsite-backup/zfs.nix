{
  config,
  lib,
  pkgs,
  ...
}:

{
  # enable ZFS
  boot.supportedFilesystems = [ "zfs" ];

  # root file system is NOT zfs
  boot.zfs.forceImportRoot = false;

  # generate with
  # head -c8 /etc/machine-id
  networking.hostId = "2c0a1a3b";

  # will work after initial import, i.e.
  # check available pools with
  #   zpool list
  # import with
  #   zpool import <pool>
  # rename with
  #   zpool import <pool> tank
  # or creation with
  #   zpool create tank /dev/disk/by-id/...
  # otherwise the deploy might fail, and you won't have access
  # to the zpool / zfs commands
  # autoload "tank" pool
  boot.zfs.extraPools = [
    "tank"
  ];

  services.zfs.autoScrub = {
    enable = true;
    pools = [
      "tank"
    ];
    interval = "monthly"; # recommended and default
  };

  # dataset tuning
  # datasets created with
  #   zfs create tank/pbs
  #   zfs create tank/photos
  #   zfs create tank/drive
  systemd.services.zfs-dataset-tuning = {
    description = "Tune ZFS parameters for various datasets";

    after = [ "zfs-import.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script =
      let
        zfs = "${pkgs.zfs}/bin/zfs";
      in
      ''
        # General pool settings.
        ${zfs} set atime=off tank
        ${zfs} set compression=zstd tank

        # PBS datastore.
        ${zfs} set compression=zstd tank/pbs
        ${zfs} set atime=off tank/pbs

        # ZFS-replicated datasets.
        ${zfs} set compression=zstd tank/photos
        ${zfs} set compression=zstd tank/drive

        ${zfs} set atime=off tank/photos
        ${zfs} set atime=off tank/drive

        # These datasets are replication targets and should not be
        # modified locally.
        ${zfs} set readonly=on tank/photos
        ${zfs} set readonly=on tank/drive
      '';
  };
}
