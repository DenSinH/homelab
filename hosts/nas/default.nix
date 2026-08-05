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

  networking = {
    hostName = "nas";
    defaultGateway = {
      address = "192.168.50.1";
      interface = "eno1";
    };
    interfaces.eno1.ipv4.addresses = [
      {
        address = lib.storage.nas.ip;
        prefixLength = 24;
      }
    ];
    nameservers = [
      # forwarded to piholes
      "192.168.50.1"
    ];
  };

  system.stateVersion = "25.11";
}
