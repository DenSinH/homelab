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
    "${lib.lan.gateway} router.home"
    "${lib.lxcs.ahole.ip} ahole.home"
    "${lib.lxcs.bhole.ip} bhole.home"
    "${lib.lxcs.chole.ip} chole.home"

    ### SERVER
    "${lib.hosts.proxmox1.ip} proxmox1.home"
    "${lib.hosts.proxmox2.ip} proxmox2.home"
    "${lib.hosts.proxmox3.ip} proxmox3.home"
    "${lib.lan.subnet}.18 pdm.home"
    "${lib.lan.subnet}.19 pbs.home"

    ### STORAGE
    "${lib.storage.nas.ip} nas.home"
    "${lib.storage.nas.tailnet_ip} nas.vpn"
    "${lib.lan.subnet}.22 hp-ilo.home"

    "${lib.backup.offsite-backup.tailnet_ip} offsite-backup.vpn"

    ### SERVICES

    "${lib.devices.home-assistant.ip} homeassistant.home"
    "100.85.36.70 homeassistant.vpn"

    # "${lib.lxcs.static-site.ip} static.home"
    # "${lib.lxcs.static-site.tailnet_ip} static.vpn"

    "${lib.lan.subnet}.33 actual.home"

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

    "${lib.lan.subnet}.46 byparr.home"
    "${lib.lan.subnet}.47 bazarr.home"

    "${lib.lan.subnet}.203 playstation.home"
  ];

  inherit (lib.lan) domains;
  # <name> in every zone; the short zone prefers the tailnet IP.
  recordsFor =
    name: l:
    let
      vpnIp = l.tailnet_ip or null;
    in
    [
      "address=/${name}.${domains.home}/${l.ip}"
      "address=/${name}.${domains.short}/${if vpnIp != null then vpnIp else l.ip}"
    ]
    ++ lib.optional (vpnIp != null) "address=/${name}.${domains.vpn}/${vpnIp}";
  lxcRecords = lib.concatMap (l: recordsFor l.hostname l) (lib.attrValues lib.lxcs);

  aliasRecords = lib.concatMap (l: lib.concatMap (n: recordsFor n l) (l.aliases or [ ])) (
    lib.attrValues lib.lxcs
  );
in
{
  homelab.egress.enable = true;

  # DHCP hands every device this host directly as DNS (router.nix option 6),
  # so port 53 must stay open to all; :80 admin UI keeps the default lockdown.
  homelab.ingress = {
    enable = true;
    allowed = [
      {
        host = "0.0.0.0/0";
        ports = [ 53 ];
        protos = [
          "tcp"
          "udp"
        ];
        comment = "DNS from every device";
      }
    ];
  };

  homelab.hardenedServices = [ "pihole-regex-allowlist" ];

  services.pihole-web = {
    enable = true;
    ports = [
      80
    ];
    hostName = "${lib.lan.subnet}.215";
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
      misc.dnsmasq_lines = lxcRecords ++ aliasRecords;

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

    serviceConfig = lib.hardenedService // {
      Type = "oneshot";
      RemainAfterExit = true;

      User = config.services.pihole-ftl.user;
      Group = config.services.pihole-ftl.group;

      # Make the filesystem explicitly read-only except for Pi-hole state.
      # Pi-hole's database/configuration lives here.
      ReadWritePaths = [
        "/etc/pihole"
        "/var/lib/pihole"
      ];

      # pihole-FTL is reached over its local Unix socket / loopback API.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
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
