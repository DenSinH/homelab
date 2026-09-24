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
    "(^|\\.)sdk-games\\.brightdata\\.com$" # Some mobile game I don't remember
    "(^|\\.)admarkt\\.marktplaats\\.nl$" # Marktplaats ads
    "(^|\\.)click\\.aliexpress\\.com$" # AliExpress links
    "(^|\\.)vanced\\.to$" # YouTube Vanced homepage
    "(\\.|^)googleadservices\\.com$" # Google product results
  ];
  upstreams = [
    "127.0.0.1#5335" # unbound
  ];
  localRecords = [
    ### NETWORK
    "192.168.50.1 router.home"
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
    "${lib.storage.nas.ip} nas.home"
    "${lib.storage.nas.tailnet_ip} nas.vpn"
    "192.168.50.22 hp-ilo.home"

    "${lib.backup.offsite-backup.tailnet_ip} offsite-backup.vpn"

    ### SERVICES
    "${lib.lxcs.reporting.ip} reporting.home"

    "192.168.50.31 homeassistant.home"
    "100.85.36.70 homeassistant.vpn"

    "${lib.lxcs.static-site.ip} static.home"
    "${lib.lxcs.static-site.tailnet_ip} static.vpn"

    "192.168.50.33 actual.home"

    "${lib.lxcs.telemetry.ip} telemetry.home"
    "${lib.lxcs.telemetry.tailnet_ip} telemetry.vpn"

    "${lib.lxcs.gatus.ip} gatus.home"
    "${lib.lxcs.gatus.ip} status.home" # alias
    "${lib.lxcs.cookbook.ip} cookbook.home"

    "${lib.lxcs.immich.ip} immich.home"
    "${lib.lxcs.immich.tailnet_ip} immich.vpn"

    "${lib.lxcs.vaultwarden.ip} vaultwarden.home"
    "${lib.lxcs.vaultwarden.tailnet_ip} vaultwarden.vpn"

    "${lib.lxcs.blog.ip} blog.home"

    "${lib.lxcs.nixflix.ip} nixflix.home"
    "${lib.lxcs.nixflix.tailnet_ip} nixflix.vpn"

    "${lib.lxcs.dawarich.ip} dawarich.home"
    "${lib.lxcs.dawarich.tailnet_ip} dawarich.vpn"

    "${lib.lxcs.garage.ip} garage.home"

    "${lib.lxcs.bentopdf.ip} bentopdf.home"

    "${lib.lxcs.paperless.ip} paperless.home"
    "${lib.lxcs.paperless.tailnet_ip} paperless.vpn"

    "192.168.50.46 byparr.home"
    "192.168.50.47 bazarr.home"

    "192.168.50.203 playstation.home"
  ];

  # subdomain mappings for (exposed) nixflix services
  cnameRecords = [
    "radarr.nixflix.home,nixflix.home"
    "sonarr.nixflix.home,nixflix.home"
    "jellyfin.nixflix.home,nixflix.home"
    "prowlarr.nixflix.home,nixflix.home"
    "qbittorrent.nixflix.home,nixflix.home"

    "radarr.nixflix.vpn,nixflix.vpn"
    "sonarr.nixflix.vpn,nixflix.vpn"
    "jellyfin.nixflix.vpn,nixflix.vpn"
    "prowlarr.nixflix.vpn,nixflix.vpn"
    "qbittorrent.nixflix.vpn,nixflix.vpn"
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
      dns.cnameRecords = cnameRecords;

      # these can grow pretty big
      dns.queryLogging = false;

      # needed for tailscale DNS
      dns.listeningMode = "ALL";

      # limit database retention
      database.maxDBDays = 7;
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

      User = config.services.pihole-ftl.user;
      Group = config.services.pihole-ftl.group;

      # Privilege / filesystem hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;

      # Kernel / namespace hardening
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      MemoryDenyWriteExecute = true;

      # Don't allow the service to create additional namespaces.
      RestrictNamespaces = true;

      # Only native syscalls for this architecture.
      SystemCallArchitectures = "native";

      # No need for raw/network administration capabilities.
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";

      # Make the filesystem explicitly read-only except for Pi-hole state.
      #
      # Pi-hole's database/configuration lives here.
      ReadWritePaths = [
        "/etc/pihole"
        "/var/lib/pihole"
      ];

      # Don't leave core dumps containing potentially useful information.
      LimitCORE = 0;
    };

    script = ''
      set -euo pipefail

      PIHOLE=${pkgs.pihole}/bin/pihole
      SED=${pkgs.gnused}/bin/sed

      echo "Waiting for Pi-hole FTL..."

      for attempt in $(seq 1 30); do
        if "$PIHOLE" status >/dev/null 2>&1; then
          break
        fi

        if [ "$attempt" -eq 30 ]; then
          echo "Pi-hole FTL did not become ready" >&2
          exit 1
        fi

        sleep 1
      done

      echo "Applying Pi-hole regex allowlist..."

      "$PIHOLE" allow --regex --list \
        | "$SED" -n 's/^- "\(.*\)"$/\1/p' \
        | while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            echo "Removing: $rule"
            "$PIHOLE" --allow-regex remove "$rule"
          done

      ${lib.concatMapStringsSep "\n" (r: ''"$PIHOLE" --allow-regex '${r}' '') allowlist}

      echo "Done."
    '';
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = "127.0.0.1";
        port = 5335;
        do-ip4 = "yes";
        do-udp = "yes";
        do-tcp = "yes";
        do-ip6 = "no";
        prefer-ip6 = "no";

        # Cache slabs reduce lock contention
        msg-cache-slabs = 2;
        rrset-cache-slabs = 2;
        infra-cache-slabs = 2;
        key-cache-slabs = 2;

        # Performance
        msg-cache-size = "64m";
        rrset-cache-size = "128m"; # ~2x msg-cache-size

        # Hardening / privacy
        # Based on recommended settings in
        # https://docs.pi-hole.net/guides/dns/unbound/#configure-unbound
        harden-glue = "yes";
        harden-dnssec-stripped = "yes";
        use-caps-for-id = "no";
        edns-buffer-size = 1232;
        prefetch = "yes";
        prefetch-key = "yes";
        num-threads = 1;

        # Local/private networks
        private-domain = "dennishilhorst.nl";
        private-address = [
          "192.168.0.0/16"
          "169.254.0.0/16"
          "172.16.0.0/12"
          "10.0.0.0/8"
          "fd00::/8"
          "fe80::/10"
          "100.0.0.0/8" # tailnet
        ];
      };
    };
  };

  # debugging tools
  environment.systemPackages = with pkgs; [
    dig
  ];

  # this conflicts with the pihole port 53 mapping
  services.resolved.enable = false;
  networking.nameservers = upstreams;

  # required for running as tailscale dns server
  # https://tailscale.com/docs/solutions/block-ads-all-devices-anywhere-using-raspberry-pi#step-3-install-tailscale-on-your-raspberry-pi
  services.tailscale.extraUpFlags = [
    "--accept-dns=false"
  ];
}
