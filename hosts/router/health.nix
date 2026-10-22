{
  config,
  pkgs,
  lib,
  ...
}:

let
  network = import ./network.nix { inherit lib; };
  inherit (network) lanIf lanSubnet;

  lanNetwork = "${lanSubnet}.0/24";

  # Loopback-only now; nginx (below) is the LAN-facing side on 80/443.
  # Keep in sync with the nftables input-chain rule in router.nix.
  webPort = 8080;
in
{
  homelab.hardenedServices = [ "darkstat" ];

  homelab.selfSignedCerts.darkstat.hostName = "router.home";

  services.nginx = {
    enable = true;

    virtualHosts."router.home" = {
      forceSSL = true;
      sslCertificate = config.homelab.selfSignedCerts.darkstat.certFile;
      sslCertificateKey = config.homelab.selfSignedCerts.darkstat.keyFile;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString webPort}";
      };
    };
  };

  # darkstat: lightweight passive traffic monitor - shows currently active
  # LAN hosts and per-host traffic on a small built-in web dashboard.
  # Deliberately kept minimal: no --daylog/--export, so nothing is ever
  # written to disk (stats live in memory only, reset on restart), no
  # database, no separate Prometheus/Grafana wiring needed.
  # https://unix4lyfe.org/darkstat/
  systemd.services.darkstat = {
    description = "darkstat - per-host LAN traffic dashboard";
    after = [ "sys-subsystem-net-devices-${lanIf}.device" ];
    bindsTo = [ "sys-subsystem-net-devices-${lanIf}.device" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig =
      # darkstat does its own privilege drop (root -> chroot -> setuid
      # nobody), which fights with several of our restrictions in practice:
      # tested and confirmed these have to go.
      removeAttrs lib.hardenedService [
        "CapabilityBoundingSet"
        "AmbientCapabilities"
        "PrivateUsers"
        "SystemCallFilter"
        "NoNewPrivileges"
        "RestrictSUIDSGID"
        "RestrictNamespaces"
      ]
      // {
        ExecStart = "${pkgs.darkstat}/bin/darkstat --no-daemon -i ${lanIf} -l ${lanNetwork} --local-only -p ${toString webPort} -b 127.0.0.1 --chroot /var/empty --user nobody";
        Restart = "on-failure";
        RestartSec = 5;

        User = "root";
        Group = "root";
        PrivateDevices = false; # needs the NIC for packet capture

        # The dashboard is only reachable through nginx now (loopback).
        IPAddressDeny = "any";
        IPAddressAllow = [ "127.0.0.1" ];
      };
  };
}
