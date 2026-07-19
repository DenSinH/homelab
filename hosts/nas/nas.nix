{ config, pkgs, ... }:

{
  imports = [
    ./zfs.nix
    ./nfs.nix
    ./replication.nix
    ./health.nix
  ];

  services.zfs.autoScrub = {
    enable = true;
    pools = [
      "tank"
      "backup"
    ];
    interval = "monthly"; # recommended and default
  };

  # todo: add backup management (ZFS send / rcv from / to PBS? USB backup disk?)
}
