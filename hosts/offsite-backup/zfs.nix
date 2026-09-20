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

  # MAY HAVE TO BE DISABLED, however, will work after initial deploy
  # and after importing / creating `tank`
  #
  # Otherwise the deploy might fail, and you won't have access
  # to the zpool / zfs commands to even create or import `tank`
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

  # Pool-level ZFS tuning
  systemd.services.zfs-pool-tuning = {
    description = "Tune ZFS parameters on the tank pool root";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.zfs}/bin/zfs set atime=off tank
      ${pkgs.zfs}/bin/zfs set compression=zstd tank
    '';
  };
}
