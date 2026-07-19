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
  networking.hostId = "fe7e6f35";

  # after initial import, i.e.
  # check available pools with
  #   zpool list
  # import with
  #   zpool import <pool>
  # rename with
  #   zpool import <pool> tank
  # then we may need to update the mountpoints
  # we can enable the below settings
  # autoload "tank" pool
  boot.zfs.extraPools = [
    "tank"
    "backup"
  ];

  boot.kernelParams = [
    # NAS has 16GB memory, set 12GiB for arc_max
    "zfs.zfs_arc_max=12884901888"
  ];

  # dataset tuning
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
        noCache = [
          "backup"
          "tank/media"
          "tank/vaultwarden"
          "tank/pbs-backup"
          "tank/proxmox-backup"
        ];
      in
      ''
        # disable ZFS cache for datasets that don't need it
        for ds in ${lib.concatStringsSep " " noCache}; do 
          ${zfs} set primarycache=metadata "$ds"
          ${zfs} set secondarycache=metadata "$ds"
        done

        ${zfs} set recordsize=1M tank/media
        ${zfs} set atime=off backup
        ${zfs} set atime=off tank
      '';
  };
}
