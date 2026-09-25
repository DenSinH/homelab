{ config, pkgs, ... }:

let
  usbip = config.boot.kernelPackages.usbip;
in
{
  # USB/IP: exports the zigbee dongle (plugged directly into the router)
  # over the network, so e.g. Home Assistant can use it without a USB
  # extension cord + passthrough into a VM/LXC.
  # see also nftables rule in router.nix, tcp/3240.
  boot.kernelModules = [ "usbip-host" ];

  # for manual `usbip list -l`/`usbip port` on the router
  environment.systemPackages = [ usbip ];

  systemd.services.usbipd = {
    description = "USB/IP host daemon";

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${usbip}/bin/usbipd";
      Restart = "on-failure";

      # suppress messages like
      # usbipd: info: connection from 192.168.50.31:34106
      LogLevelMax = "notice";

      RestartSec = 5;

      # Privilege
      User = "root";
      Group = "root";

      # Filesystem
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = false;

      # Host/kernel isolation
      ProtectKernelTunables = true;
      ProtectKernelModules = false;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectHostname = true;

      LockPersonality = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";

      LimitCORE = 0;

      # USB/IP needs networking.
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];

      # Only allow the LAN to connect to usbipd.
      IPAddressDeny = "any";
      IPAddressAllow = "192.168.50.0/24";
    };
  };

  # Auto-bind the dongle (Silicon Labs CP210x UART bridge, 10c4:ea60) to the
  # usbip-host driver whenever it's plugged in.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="ea60", TAG+="systemd", ENV{SYSTEMD_WANTS}="usbip-bind@%k.service"
  '';

  systemd.services."usbip-bind@" = {
    description = "Bind USB device %i to USB/IP";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${usbip}/bin/usbip bind -b %i";
    };
  };
}
