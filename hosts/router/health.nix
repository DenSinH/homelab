{ pkgs, lib, ... }:

let
  inherit (lib.router) lanIf;
  lanNetwork = lib.lan.cidr;

  # Keep in sync with the nftables input-chain rule in router.nix that
  # allows this port from lanIf.
  webPort = 80;
in
{
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
    # darkstat does its own privilege drop (root -> chroot -> nobody), which fights these (tested).
    hardening = {
      enable = true;
      maxExposure = 6.9;
      relax = [
        "CapabilityBoundingSet"
        "AmbientCapabilities"
        "PrivateUsers"
        "SystemCallFilter"
        "NoNewPrivileges"
        "RestrictSUIDSGID"
        "RestrictNamespaces"
      ];
    };

    serviceConfig = {
      ExecStart = "${pkgs.darkstat}/bin/darkstat --no-daemon -i ${lanIf} -l ${lanNetwork} --local-only -p ${toString webPort} -b 0.0.0.0 --chroot /var/empty --user nobody";
      Restart = "on-failure";
      RestartSec = 5;

      User = "root";
      Group = "root";
      PrivateDevices = false; # needs the NIC for packet capture

      # The dashboard is deliberately LAN-only.
      IPAddressDeny = "any";
      IPAddressAllow = [ lanNetwork ];
    };
  };
}
