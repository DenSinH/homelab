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
      "--advertise-routes=${lib.lan.subnet}.0/23"
    ];
  };

  # Replaces tailscaled's own (non-functional under declarative nftables)
  # SNAT for subnet-routed traffic.
  networking.nftables.tables.subnet_router_nat = {
    family = "ip";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 100.64.0.0/10 oifname "eth0" masquerade comment "SNAT tailnet clients using the advertised LAN route"
      }
    '';
  };
}
