# Single source of truth for homelab topology; exposed as lib.{lan,hosts,
# lxcs,router,storage,backup,admin,devices} via flake.nix's lib extension.
{ lib }:

let
  lan = rec {
    subnet = "192.168.50";
    prefixLength = 24;
    cidr = "${subnet}.0/${toString prefixLength}";
    gateway = "${subnet}.1";

    # Resolved by pihole only; certs via ACME DNS-01 (modules/https.nix).
    domains = {
      home = "home.hlhrst.nl";
      vpn = "vpn.hlhrst.nl";
      short = "hlhrst.nl"; # tailnet IP when there is one, else LAN IP
    };
    # Plain HTTP for cloudflared only; :80 is redirect-only (modules/https.nix).
    tunnelPort = 8090;

    # IP-range-per-purpose convention; see hosts/router/README.md for the
    # human-readable version of this table.
    ranges = {
      net = {
        lo = 1;
        hi = 9;
        who = "DNS (pihole), subnet router, cloudflared";
        assignment = "static";
      };
      compute = {
        lo = 10;
        hi = 19;
        who = "Proxmox nodes, PBS";
        assignment = "static";
      };
      storage = {
        lo = 20;
        hi = 29;
        who = "NAS (both NICs, iLO)";
        assignment = "static";
      };
      services = {
        lo = 30;
        hi = 49;
        who = "self-hosted services";
        assignment = "dhcp, self-requested IP, MAC-tag gated";
      };
      iot = {
        lo = 50;
        hi = 99;
        who = "IoT devices";
        assignment = "dhcp, fixed IP by MAC";
      };
      dynamic = {
        lo = 100;
        hi = 199;
        who = "anything with an unrecognized MAC";
        assignment = "dhcp, dynamic pool";
      };
      fixed = {
        lo = 200;
        hi = 254;
        who = "known devices, mixed trust";
        assignment = "dhcp, fixed IP by MAC";
      };
    };

    # "<subnet>.<lo>"/"<subnet>.<hi>" per range, for direct use in router's
    # dnsmasq ranges / nftables sets.
    rangeAddrs = builtins.mapAttrs (_: r: {
      lo = "${subnet}.${toString r.lo}";
      hi = "${subnet}.${toString r.hi}";
    }) ranges;

    # Every individual IP in each range, for Proxmox ipsets (e.g. ansible/roles/pve_firewall).
    rangeIps = builtins.mapAttrs (
      _: r: map (i: "${subnet}.${toString i}") (lib.range r.lo r.hi)
    ) ranges;
  };

  hosts = {
    proxmox1 = {
      hostname = "proxmox1.home";
      ip = "${lan.subnet}.11";
      mac = "6c:4b:90:5a:74:19";
      ctidRange = {
        min = 100;
        max = 199;
      };
      provision = {
        powertop = true;
        autoUpdates = true;
        ssdOptimization = true;
        consolePowerSaving = true;
        pvestatdAutoRestart = true;
        lxcFstrim = true;
      };
    };

    proxmox2 = {
      hostname = "proxmox2.home";
      ip = "${lan.subnet}.12";
      mac = "6c:4b:90:5a:73:9d";
      ctidRange = {
        min = 200;
        max = 299;
      };
      provision = {
        powertop = true;
        autoUpdates = true;
        ssdOptimization = true;
        consolePowerSaving = true;
        pvestatdAutoRestart = true;
        lxcFstrim = true;
      };
    };

    proxmox3 = {
      hostname = "proxmox3.home";
      ip = "${lan.subnet}.13";
      mac = "e0:51:d8:1b:fb:9c"; # e0:51:d8:1b:fb:9b unused
      ctidRange = {
        min = 300;
        max = 399;
      };
      provision = {
        powertop = true;
        autoUpdates = true;
        ssdOptimization = true;
        consolePowerSaving = true;
        pvestatdAutoRestart = true;
        lxcFstrim = true;
        grafanaKiosk = true; # has the attached kiosk display
      };
    };
  };

  router = rec {
    hostname = "router";
    ip = "${lan.subnet}.1";
    mac = "00:e0:4c:68:1d:ec";

    wanIf = "enp1s0"; # 1Gbit
    lanIf = "enp2s0"; # 2.5Gbit

    # Odido (ISP) dual-mode WAN, see hosts/router/README.md "WAN / ISP
    # replacement". Both paths are brought up at once so either cabling
    # works untouched; only the one actually connected gets a lease.
    #   - behind Odido's own router: plain untagged DHCP.
    #   - replacing Odido's router (straight into their ONT): 802.1Q VLAN 300 + DHCP.
    # https://gathering.tweakers.net/forum/list_messages/2206944#eigenhardware
    wanVlanId = 300;
    wanVlanIf = "${wanIf}.${toString wanVlanId}";
    wanIfs = [
      wanIf
      wanVlanIf
    ];

    # Known devices (devices.nix) reshaped into the {mac, ip, name, wan?}
    # list form the router's dnsmasq/nftables generation expects.
    toHostList =
      cat:
      lib.mapAttrsToList (name: d: { inherit name; } // d) (
        lib.filterAttrs (_: d: d.category == cat) devices
      );

    # Known devices in the fixed range (.200-254): used to generate both the
    # dnsmasq dhcp-host reservation and an nftables MAC+IP binding, so a
    # device can't just self-assign an unused fixed-range IP and inherit SSH
    # access without also spoofing the matching MAC.
    fixedHosts = [
      {
        mac = backup.offsite-backup.mac;
        ip = backup.offsite-backup.ip;
        name = backup.offsite-backup.hostname;
      }
    ]
    ++ toHostList "fixed";

    # IoT devices (.50-99): used to generate the dnsmasq dhcp-host
    # reservation. wan = true lets a device reach the public internet (see
    # iot_wan_allowed set in router.nix); everything else in this range is
    # blocked from WAN by default.
    iotHosts = toHostList "iot";

    # Services (.30-49): MAC is tagged via dhcp-host = "mac,set:services" (no
    # fixed IP) so it may take a lease from the tag:services dhcp-range;
    # unregistered MACs requesting that range are refused and fall through
    # to dynamic instead.
    servicesHosts = toHostList "services";
  };

  storage = {
    nas = {
      hostname = "nas";
      ip = "${lan.subnet}.20";
      mac = "34:64:a9:9a:44:bc";
      tailnet_ip = "100.109.231.109";
    };
  };

  backup = {
    offsite-backup = {
      hostname = "offsite-backup";
      ip = "${lan.subnet}.29"; # only obtained if actually on network
      mac = "6c:4b:90:78:b6:0a";
      tailnet_ip = "100.110.13.2";
    };
  };

  lxcs = {
    ahole = {
      hostname = "ahole";
      ip = "${lan.subnet}.2";
      mac = "bc:24:11:4e:81:b0";
      pveHost = "proxmox1";
      ctid = 109;

      # Not used by any lxc today - shown here as the pattern for future
      # per-lxc provisioning flags, consumed the same way as hosts.<name>.provision.
      provision = { };

      stateVersion = "26.05";

      modules = [
        ./modules/pihole.nix
        ./modules/tailscale.nix
      ];
    };

    bhole = {
      hostname = "bhole";
      ip = "${lan.subnet}.3";
      mac = "bc:24:11:7d:98:4a";
      pveHost = "proxmox2";
      ctid = 204;

      stateVersion = "26.05";

      modules = [
        ./modules/pihole.nix
        ./modules/tailscale.nix
      ];
    };

    chole = {
      hostname = "chole";
      ip = "${lan.subnet}.4";
      mac = "bc:24:11:f1:b2:39";
      pveHost = "proxmox3";
      ctid = 311;

      stateVersion = "26.05";

      modules = [
        ./modules/pihole.nix
        ./modules/tailscale.nix
      ];
    };

    cloudflared = {
      hostname = "cloudflared";
      ip = "${lan.subnet}.9";
      mac = "bc:24:11:2f:5f:8b";
      pveHost = "proxmox1";
      ctid = 115;

      stateVersion = "26.05";

      modules = [
        ./modules/cloudflared
      ];
    };

    subnet-router = {
      hostname = "subnet-router";
      ip = "${lan.subnet}.8";
      mac = "bc:24:11:d4:c8:f5";
      pveHost = "proxmox1";
      ctid = 113;

      stateVersion = "26.05";

      modules = [
        ./modules/subnet-router.nix
      ];
    };

    reporting = {
      hostname = "reporting";
      ip = "${lan.subnet}.30";
      mac = "bc:24:11:89:1c:f5";
      pveHost = "proxmox1";
      ctid = 110;

      stateVersion = "26.05";

      modules = [
        ./modules/reporting
      ];
    };

    telemetry = {
      hostname = "telemetry";
      ip = "${lan.subnet}.34";
      mac = "bc:24:11:d6:ef:b6";
      tailnet_ip = "100.106.52.64";
      pveHost = "proxmox1";
      ctid = 114;

      stateVersion = "26.05";

      modules = [
        # tailscale for offsite backup telemetry
        ./modules/tailscale.nix
        ./modules/telemetry/default.nix
      ];
    };

    # hosting random static files when needed
    # provision at
    #   /var/lib/static-site
    # only really useful if  I have something to host, so disabled for now
    # static-site = {
    #   hostname = "static-site";
    #   ip = "${lan.subnet}.32";
    #   mac = "bc:24:11:4f:c7:5f";
    #   tailnet_ip = "100.82.168.99";
    #   pveHost = "proxmox1";
    #   ctid = 103;

    #   stateVersion = "26.05";

    #   modules = [
    #     ./modules/static-site.nix
    #     ./modules/tailscale.nix
    #     ./modules/telemetry/alloy.nix
    #   ];
    # };

    gatus = {
      hostname = "gatus";
      aliases = [ "status" ];
      ip = "${lan.subnet}.35";
      mac = "bc:24:11:a5:a6:f0";
      pveHost = "proxmox1";
      ctid = 100;

      stateVersion = "26.05";

      modules = [
        ./modules/gatus/default.nix
      ];
    };

    immich = {
      hostname = "immich";
      ip = "${lan.subnet}.36";
      mac = "bc:24:11:a9:1a:9c";
      tailnet_ip = "100.100.52.120";
      pveHost = "proxmox3";
      ctid = 307;

      stateVersion = "26.05";

      modules = [
        ./modules/igpu.nix
        ./modules/immich
        ./modules/tailscale.nix
      ];
    };

    vaultwarden = {
      hostname = "vaultwarden";
      ip = "${lan.subnet}.37";
      mac = "bc:24:11:e1:2e:dd";
      tailnet_ip = "100.119.210.127";
      pveHost = "proxmox1";
      ctid = 116;

      stateVersion = "26.05";

      modules = [
        ./modules/vaultwarden.nix
        ./modules/tailscale.nix
      ];
    };

    cookbook = {
      hostname = "cookbook";
      ip = "${lan.subnet}.38";
      mac = "bc:24:11:57:fc:da";
      pveHost = "proxmox1";
      ctid = 105;

      stateVersion = "26.05";

      modules = [
        ./modules/cookbook/default.nix
      ];
    };

    blog = {
      hostname = "blog";
      ip = "${lan.subnet}.39";
      mac = "bc:24:11:34:1b:83";
      pveHost = "proxmox1";
      ctid = 101;

      stateVersion = "26.05";

      modules = [
        ./modules/blog.nix
      ];
    };

    nixflix = {
      hostname = "nixflix";
      aliases = [
        "jellyfin"
        "radarr"
        "sonarr"
        "prowlarr"
        "qbittorrent"
      ];
      ip = "${lan.subnet}.40";
      mac = "bc:24:11:0f:2d:1a";
      tailnet_ip = "100.84.251.29";
      pveHost = "proxmox3";
      ctid = 312;

      stateVersion = "26.05";

      modules = [
        ./modules/igpu.nix
        ./modules/nixflix/default.nix
      ];
    };

    dawarich = {
      hostname = "dawarich";
      ip = "${lan.subnet}.41";
      tailnet_ip = "100.90.160.73";
      mac = "bc:24:11:cc:e8:e7";
      pveHost = "proxmox1";
      ctid = 106;

      stateVersion = "26.05";

      modules = [
        ./modules/tailscale.nix
        ./modules/dawarich.nix
      ];
    };

    garage = {
      hostname = "garage";
      aliases = [ "garage-admin" ];
      ip = "${lan.subnet}.42";
      mac = "bc:24:11:27:a7:95";
      pveHost = "proxmox1";
      ctid = 108;

      stateVersion = "26.05";

      modules = [
        ./modules/garage
      ];
    };

    bentopdf = {
      hostname = "bentopdf";
      ip = "${lan.subnet}.43";
      mac = "bc:24:11:07:d8:d0";
      pveHost = "proxmox1";
      ctid = 102;

      stateVersion = "26.05";

      modules = [
        ./modules/bentopdf.nix
      ];
    };

    paperless = {
      hostname = "paperless";
      ip = "${lan.subnet}.44";
      mac = "bc:24:11:3f:e2:53";
      tailnet_ip = "100.110.234.20";
      pveHost = "proxmox3";
      ctid = 300;

      stateVersion = "26.05";

      modules = [
        ./modules/paperless.nix
        ./modules/tailscale.nix
      ];
    };
  };

  admin = {
    ssh_keys = [
      # master key
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPr33f0ptFpGkZbsMcUkAeON5m6aqOHcVg046jiy320N"
      # laptop
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq2MnvCGfq5BvLzpxEcITRpMaNZ+ERlKP6+ecbb6LWb git@dennishilhorst.nl"
      # work laptop
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1OABl55HC7R+kgK7mQJhckQc5lUjdRHZ/8KifNM8l8 nixos@nixos"
    ];
  };

  devices = import ./devices.nix { inherit lib lan; };
in
{
  inherit
    lan
    hosts
    router
    storage
    backup
    lxcs
    admin
    devices
    ;
}
