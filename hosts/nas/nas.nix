{ config, pkgs, ... }:

{
  imports = [
    ./zfs.nix
    ./nfs.nix
    ./smb.nix
    ./replication.nix
    ./health.nix
    ./offsite-backup.nix
  ];

  services.zfs.autoScrub = {
    enable = true;
    pools = [
      "tank"
      "backup"
    ];
    interval = "monthly"; # recommended and default
  };
}
