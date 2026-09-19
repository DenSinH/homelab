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

    # fail script if datasets don't exist (before initial setup)
    script =
      let
        zfs = "${pkgs.zfs}/bin/zfs";
      in
      ''
        ${zfs} set atime=off tank
        ${zfs} set compression=zstd tank

        ${zfs} set compression=zstd tank/pbs
        ${zfs} set atime=off tank/pbs

        # replication targets are created by syncoid on first run,
        # so they may not exist yet
        for ds in tank/photos tank/drive; do
          if ${zfs} list -H -o name "$ds" >/dev/null 2>&1; then
            ${zfs} set compression=zstd "$ds"
            ${zfs} set atime=off "$ds"
            ${zfs} set readonly=on "$ds"
          fi
        done
      '';
  };
}
