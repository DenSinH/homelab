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
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  nix.settings = {
    sandbox = false;
  };
  proxmoxLXC = {
    manageNetwork = false;
    privileged = true;
  };
  services.fstrim.enable = false; # Let Proxmox host handle fstrim

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
}
