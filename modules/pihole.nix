{
  config,
  pkgs,
  lib,
  ...
}:

let
  blocklists = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    "https://big.oisd.nl"
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt"
  ];
  allowlist = [
    "(^|\\.)sdk-games\\.brightdata\\.com$"
    "(^|\\.)admarkt\\.marktplaats\\.nl$"
    "(\\.|^)googleadservices\\.com$"
  ];
  upstreams = [
    "1.1.1.1"
    "8.8.8.8"
    "8.8.4.4"
  ];
  localRecords = [
    ### NETWORK
    "${lib.lxcs.ahole.ip} ahole.home"
    "${lib.lxcs.bhole.ip} bhole.home"
    "${lib.lxcs.chole.ip} chole.home"

    ### SERVER
    "${lib.hosts.proxmox1.ip} proxmox1.home"
    "${lib.hosts.proxmox2.ip} proxmox2.home"
    "${lib.hosts.proxmox3.ip} proxmox3.home"
    "192.168.50.18 pdm.home"
    "192.168.50.19 pbs.home"

    ### STORAGE
    "192.168.50.20 nas.home"
    "100.127.98.109 nas.vpn"
    "192.168.50.22 hp-ilo.home"

    ### SERVICES
    "192.168.50.30 vps.home"

    "192.168.50.31 homeassistant.home"
    "100.85.36.70 homeassistant.vpn"

    "192.168.50.32 firefly.home"
    "192.168.50.33 actual.home"
    "${lib.lxcs.telemetry.ip} telemetry.home"
    "${lib.lxcs.gatus.ip} gatus.home"
    "${lib.lxcs.gatus.ip} status.home" # alias

    "${lib.lxcs.immich.ip} immich.home"
    "${lib.lxcs.immich.tailnet_ip} immich.vpn"

    "${lib.lxcs.vaultwarden.ip} vaultwarden.home"
    "${lib.lxcs.vaultwarden.tailnet_ip} vaultwarden.vpn"

    "${lib.lxcs.blog.ip} blog.home"

    ### STREAMING
    "${lib.lxcs.nixflix.ip} nixflix.home"
    "${lib.lxcs.nixflix.tailnet_ip} nixflix.vpn"

    "${lib.lxcs.nixflix.ip} jellyfin.home"
    "${lib.lxcs.nixflix.tailnet_ip} jellyfin.vpn"

    "${lib.lxcs.nixflix.ip} radarr.home"
    "${lib.lxcs.nixflix.tailnet_ip} radarr.vpn"

    "${lib.lxcs.nixflix.ip} radarr.home"
    "${lib.lxcs.nixflix.tailnet_ip} radarr.vpn"

    "${lib.lxcs.nixflix.ip} sonarr.home"
    "${lib.lxcs.nixflix.tailnet_ip} sonarr.vpn"

    "${lib.lxcs.nixflix.ip} qbittorrent.home"
    "${lib.lxcs.nixflix.tailnet_ip} qbittorrent.vpn"

    "${lib.lxcs.nixflix.ip} prowlarr.home"
    "192.168.50.45 flaresolverr.home"
    "192.168.50.46 byparr.home"
    "192.168.50.47 bazarr.home"

    "192.168.50.203 playstation.home"
  ];
in
{
  services.pihole-web = {
    enable = true;
    ports = [
      80
    ];
    hostName = "192.168.50.215";
  };

  services.pihole-ftl = {
    enable = true;

    openFirewallDNS = true;
    openFirewallWebserver = true;

    lists = map (url: {
      inherit url;
      type = "block";
      enabled = true;
    }) blocklists;

    # configuration file settings
    # see: https://docs.pi-hole.net/ftldns/configfile/
    settings = {
      dns.upstreams = upstreams;
      dns.hosts = localRecords;

      # needed for tailscale DNS
      dns.listeningMode = "ALL";
    };
  };

  systemd.services.pihole-regex-allowlist = {
    description = "Configure Pi-hole regex allowlist";
    wantedBy = [ "multi-user.target" ];

    after = [ "pihole-ftl.service" ];
    requires = [ "pihole-ftl.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      echo "Applying Pi-hole regex allowlist..."

      PIHOLE=${pkgs.pihole}/bin/pihole

      # Remove existing rules (safe cleanup)
      $PIHOLE allow --regex --list \
        | ${pkgs.gnused}/bin/sed -n "s/^- \"\(.*\)\"$/\1/p" \
        | while read -r rule; do
            echo "Removing: $rule"
            $PIHOLE --allow-regex remove "$rule" || true
          done

      # Apply desired rules
      ${pkgs.lib.concatMapStringsSep "\n" (r: "$PIHOLE --allow-regex '${r}'") allowlist}

      echo "Done."
    '';
  };

  # this conflicts with the pihole port 53 mapping
  services.resolved.enable = false;
  networking.nameservers = upstreams;

  # required for running as tailscale dns server
  # https://tailscale.com/docs/solutions/block-ads-all-devices-anywhere-using-raspberry-pi#step-3-install-tailscale-on-your-raspberry-pi
  services.tailscale.extraUpFlags = [
    "--accept-dns=false"
  ];
}
