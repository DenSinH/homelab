{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/host/default.nix
    # must be reachable over tailscale
    ../../modules/tailscale.nix
    ./zfs.nix
    ./pbs.nix
    ./replication.nix
    ./health.nix
  ];

  # ensure tailscale shuts down only after libvirtd is shut down
  systemd.services.tailscaled.before = [
    "libvirtd.service"
  ];

  # currently, no wi-fi antenna is connected, which causes failures
  systemd.services.disable-wifi-pcie = {
    description = "Remove unused PCIe WiFi device";
    wantedBy = [ "multi-user.target" ];
    after = [ "sysinit.target" ];

    serviceConfig.Type = "oneshot";

    script = ''
      if [ -e /sys/bus/pci/devices/0000:02:00.0/remove ]; then
        echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove
      fi
    '';
  };

  boot.blacklistedKernelModules = [
    "iwlwifi"
    "iwlmvm"
  ];

  networking.wireless.enable = false;
  # /end of wifi disabling

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/nvme0n1";
  boot.loader.grub.useOSProber = true;

  # no other networking setup, will get it from offsite router
  networking.hostName = "offsite-backup";

  system.stateVersion = "26.05";
}
