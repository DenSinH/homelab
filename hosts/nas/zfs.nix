{ config, pkgs, ... }:

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
}
