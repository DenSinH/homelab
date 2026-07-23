{
  pkgs,
  modulesPath,
  lib,
  host,
  ...
}:

{
  # container-related settings
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  nix.settings = {
    sandbox = false;
    experimental-features = [
      "nix-command"
      "flakes"
    ];
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

  time.timeZone = "Europe/Amsterdam";

  # ssh settings
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      PermitEmptyPasswords = "yes";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    lib.admin.ssh_key
  ];

  # LXC container template based on 26.05 release
  system.stateVersion = host.stateVersion;

  # inject LXC rotation script
  environment.etc."init-lxc.sh" = {
    source = ./init-lxc.sh;
    mode = "0500"; # root-only, executable
  };
}
