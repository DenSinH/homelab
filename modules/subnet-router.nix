{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Doesn't affect this LXC's FORWARD-ed tailnet<->LAN routing, only OUTPUT.
  homelab.egress.enable = true;
  homelab.ingress.enable = true;

  # Enable tailscale
  imports = [
    ./tailscale.nix
  ];

  # Enable kernel IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  services.tailscale = {
    useRoutingFeatures = "server";

    extraSetFlags = [
      # advertise a larger subnet so LAN takes priority at home
      "--advertise-routes=192.168.50.0/23"
    ];
  };
}
