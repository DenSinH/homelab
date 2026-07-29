{ pkgs, ... }:

let
  # Shared with router.nix - see network.nix.
  network = import ./network.nix;
  inherit (network) lanIf lanSubnet;

  lanNetwork = "${lanSubnet}.0/24";

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
    serviceConfig = {
      # darkstat itself starts as root, binds the (privileged, port 80)
      # capture/web socket, then chroots and drops to an unprivileged user
      # before doing anything else - this is its own built-in privilege
      # drop (see darkstat(8) --chroot/--user), so it's intentionally run
      # without systemd's DynamicUser/capability sandboxing here to avoid
      # the two fighting over who drops privileges.
      ExecStart = "${pkgs.darkstat}/bin/darkstat --no-daemon -i ${lanIf} -l ${lanNetwork} --local-only -p ${toString webPort} -b 0.0.0.0 --chroot /var/empty --user nobody";
      Restart = "on-failure";
    };
  };
}
