{
  pkgs,
  modulesPath,
  lib,
  host,
  ...
}:

{
  # container-related settings
  imports = [
    ../common/default.nix
    ../https.nix
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # iot untrusted by default for every LXC; mkDefault lets a module override.
  homelab.ingress.blockIot = lib.mkDefault true;

  nix.settings = {
    sandbox = false;
  };
  proxmoxLXC = {
    manageNetwork = false;
    privileged = true;
  };
  # pve host's pve_lxc_fstrim role runs pct fstrim
  services.fstrim.enable = false;

  boot.isContainer = true;
  boot.loader.grub.enable = false;

  # have to be disabled, according to
  # https://taoofmac.com/space/blog/2024/08/17/1530
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # LXC container template based on 26.05 release
  system.stateVersion = host.stateVersion;

  # inject LXC rotation script
  environment.etc."init-lxc.sh" = {
    source = ./init-lxc.sh;
    mode = "0500"; # root-only, executable
  };

  # log persistence based on host settings
  services.journald = lib.mkIf (!host.persistLogs or false) {
    storage = "volatile";

    # most LXCs don't have _that_ much memory
    extraConfig = ''
      RuntimeMaxUse=10M
      RuntimeMaxFileSize=2M
      RuntimeMaxFiles=5
    '';
  };
}
