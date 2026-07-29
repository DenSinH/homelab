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
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${usbip}/bin/usbipd";
      Restart = "on-failure";
    };
  };

  # Auto-bind the dongle (Silicon Labs CP210x UART bridge, 10c4:ea60) to the
  # usbip-host driver whenever it's plugged in.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="ea60", RUN+="${usbip}/bin/usbip bind -b %k"
  '';
}
