{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./nas.nix
  ];

  # HP MicroServer Gen8 runs in BIOS mode, will need
  boot.loader.grub = {
    enable = true;
    # HP MicroServer Gen8 has some quirks with disk /dev/sdX indexing
    # depending on the number of HDDs connected
    # this is the device ID for the SSD NixOS is installed to
    device = "/dev/disk/by-id/ata-M4-CT128M4SSD2_00000000112803146A4B";
    useOSProber = true;
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = false;

  # The Gen8's Xeon E3-12xx v2 has a well-documented C-state bug on Linux:
  # random full-system freezes (sometimes logged as "NMI: IOCK error") when
  # the CPU enters deep idle states, especially on newer kernels. If we
  # encounter unexplained freezes, uncomment:
  # boot.kernelParams = ["intel_idle.max_cstate=1"];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking = {
    defaultGateway = {
      address = "192.168.50.1";
      interface = "eno1";
    };
    hostName = "nas";
    interfaces.eno1.ipv4.addresses = [
      {
        address = lib.storage.nas.ip;
        prefixLength = 24;
      }
    ];
  };

  time.timeZone = "Europe/Amsterdam";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "nl_NL.UTF-8";
    LC_IDENTIFICATION = "nl_NL.UTF-8";
    LC_MEASUREMENT = "nl_NL.UTF-8";
    LC_MONETARY = "nl_NL.UTF-8";
    LC_NAME = "nl_NL.UTF-8";
    LC_NUMERIC = "nl_NL.UTF-8";
    LC_PAPER = "nl_NL.UTF-8";
    LC_TELEPHONE = "nl_NL.UTF-8";
    LC_TIME = "nl_NL.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "yes";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    lib.admin.ssh_key
  ];

  environment.systemPackages = with pkgs; [
    git
    nano
  ];

  system.stateVersion = "25.11";
}
