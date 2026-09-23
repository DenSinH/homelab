{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common/default.nix
    # must be reachable over tailscale
    ../../modules/tailscale.nix
    ./zfs.nix
    ./pbs.nix
    ./replication.nix
    ./health.nix
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/nvme0n1";
  boot.loader.grub.useOSProber = true;

  # no other networking setup, will get it from offsite router
  networking.hostName = "offsite-backup";

  system.stateVersion = "26.05";
}
