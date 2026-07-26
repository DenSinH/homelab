########################################################################
# NixOS router — WAN + ONE FLAT LAN, split into IP ranges by convention:
#
#   .1   - .9   net      static  DNS (pihole), subnet router, cloudflared
#   .10  - .19  compute  static  proxmox nodes, PBS
#   .20  - .29  storage  static  NAS (both NICs, iLO)
#   .30  - .49  services dhcp    services, self-assigned IP, MAC-gated
#   .50  - .99  iot      dhcp    IoT, fixed IP by MAC, no WAN by default
#   .100 - .199 dynamic  dhcp    unrecognized MACs (guest-equivalent)
#   .200 - .254 fixed    dhcp    known devices, fixed IP by MAC
#
# NOT VLANs on the LAN side: the unmanaged switches + non-SDN Asus APs
# (AX57/AX55) can't honor 802.1Q tags, so ranges are enforced by dnsmasq
# (MAC -> IP/tag) + nftables (policy per source-IP range), not by real
# broadcast-domain separation. See README for what a ~$25 managed switch
# would additionally get you.
#
# WAN side does use a VLAN (802.1Q id 300), for Odido ISP replacement mode
# - see README "WAN / ISP replacement" for why and the AON/GPON caveats.
#
# Written for, and adapting patterns from:
#   - Solene Rapenne: https://dataswamp.org/~solene/2022-08-03-nixos-with-live-usb-router.html
#   - Johan (skogsbrus): https://skogsbrus.xyz/building-a-router-with-nixos/
#   - Francis Begyn: https://francis.begyn.be/blog/nixos-home-router
#   - Josh Pearce (jjpdev): https://www.jjpdev.com/posts/home-router-nixos/
########################################################################

{
  config,
  lib,
  pkgs,
  ...
}:

let
  wanIf = "enp1s0"; # 1Gbit
  lanIf = "enp2s0"; # 2.5Gbit

  # Odido (ISP) dual-mode WAN, see README "WAN / ISP replacement":
  #   - behind Odido's own router: wanIf gets a plain DHCP lease, untagged.
  #   - replacing Odido's router (straight into their ONT): needs 802.1Q
  #     VLAN 300 + DHCP. Both are brought up at once so either cabling
  #     works without editing config; only the one actually connected
  #     gets a lease.
  wanVlanId = 300;
  wanVlanIf = "${wanIf}.${toString wanVlanId}";
  wanIfs = [
    wanIf
    wanVlanIf
  ];

  # Same /24, just different address bands - keep ranges non-overlapping.
  lanSubnet = "192.168.50";
  lanGateway = "${lanSubnet}.1";

  netLo = "${lanSubnet}.1";
  netHi = "${lanSubnet}.9";
  computeLo = "${lanSubnet}.10";
  computeHi = "${lanSubnet}.19";
  storageLo = "${lanSubnet}.20";
  storageHi = "${lanSubnet}.29";
  servicesLo = "${lanSubnet}.30";
  servicesHi = "${lanSubnet}.49";
  iotLo = "${lanSubnet}.50";
  iotHi = "${lanSubnet}.99";
  dynamicLo = "${lanSubnet}.100";
  dynamicHi = "${lanSubnet}.199";
  fixedLo = "${lanSubnet}.200";
  fixedHi = "${lanSubnet}.254";

  # Known devices in the fixed range (.200-254): listed once here, used to
  # generate both the dnsmasq dhcp-host reservation and an nftables MAC+IP
  # binding, so a device can't just self-assign an unused fixed-range IP
  # and inherit SSH access without also spoofing the matching MAC.
  fixedHosts = [
    {
      mac = "1a:a3:ef:b4:53:46";
      ip = "${lanSubnet}.200";
      name = "dennis-telefoon";
    }
    {
      mac = "50:5a:65:34:0e:19";
      ip = "${lanSubnet}.201";
      name = "dennis-laptop";
    }
    {
      mac = "5c:2f:af:36:55:d8";
      ip = "${lanSubnet}.205";
      name = "p1-meter-homewizard";
    }
    {
      mac = "34:5f:45:19:d8:28";
      ip = "${lanSubnet}.206";
      name = "shellyplus2pm";
    }
    {
      mac = "fc:f5:c4:98:e3:ee";
      ip = "${lanSubnet}.207";
      name = "otgw";
    }
    {
      mac = "38:7a:cc:70:25:4a";
      ip = "${lanSubnet}.208";
      name = "eufy-vacuum";
    }
    {
      mac = "b8:e9:37:32:72:ec";
      ip = "${lanSubnet}.230";
      name = "sonos-zp";
    }

    # Not yet renumbered into the .200-254 band - kept at their old IPs for
    # now (still functions, just outside the intended range convention).
    {
      mac = "b8:e9:37:82:35:18";
      ip = "${lanSubnet}.109";
      name = "sonos-1";
    }
    {
      mac = "28:49:e9:76:15:8d";
      ip = "${lanSubnet}.124";
      name = "iphone-merel";
    }
    {
      mac = "2c:7b:a0:11:f9:54";
      ip = "${lanSubnet}.131";
      name = "hvee113-work-laptop";
    }
    {
      mac = "d8:a0:11:e1:07:8b";
      ip = "${lanSubnet}.132";
      name = "wiz-e1078b";
    }
    {
      mac = "f4:4d:ad:04:1c:d4";
      ip = "${lanSubnet}.140";
      name = "chromecast-badkamer";
    }
    {
      mac = "5c:aa:fd:46:b3:c6";
      ip = "${lanSubnet}.144";
      name = "sonos-2";
    }
    {
      mac = "d8:a0:11:e1:07:9f";
      ip = "${lanSubnet}.152";
      name = "wiz-e1079f";
    }
    {
      mac = "b8:e9:37:56:28:b4";
      ip = "${lanSubnet}.154";
      name = "sonos-3";
    }
    {
      mac = "d8:a0:11:b2:c4:3d";
      ip = "${lanSubnet}.180";
      name = "wiz-b2c43d";
    }
    {
      mac = "64:c9:01:b7:41:9f";
      ip = "${lanSubnet}.195";
      name = "msft-5-0";
    }
  ];

  # IoT devices (.50-99): listed once here, used to generate the dnsmasq
  # dhcp-host reservation. Set wan = true to also let that device reach
  # the public internet (see iot_wan_allowed set); everything else in
  # this range is blocked from WAN by default.
  iotHosts = [
    {
      mac = "d8:a0:11:49:43:c0";
      ip = "${lanSubnet}.65";
      name = "wiz-4943c0";
      wan = true;
    }
    {
      mac = "6c:29:90:80:42:a8";
      ip = "${lanSubnet}.79";
      name = "wiz-8042a8";
      wan = true;
    }
    {
      mac = "d8:a0:11:e2:30:53";
      ip = "${lanSubnet}.90";
      name = "wiz-e23053";
      wan = true;
    }
  ];
  iotWanAllowed = builtins.filter (h: h.wan) iotHosts;
in
{
  ###########################################################################
  # Core routing
  ###########################################################################

  boot.kernel.sysctl = {
    # Turn this box into an actual router. Without this, the kernel drops
    # any packet not addressed to itself.
    # https://serverfault.com/questions/248841/ip-forwarding-when-and-why-is-this-required
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = false; # IPv6 intentionally out of scope, see README

    # A few conservative tweaks that help a low-power router stay stable
    # under load without needing much RAM (APU4D4 usually has 2/4 GB):
    "net.netfilter.nf_conntrack_max" = 65536;
    "net.ipv4.tcp_syncookies" = true; # basic SYN-flood mitigation
    # Don't let a burst of tiny broadcast/multicast traffic from IoT gear
    # cause log spam or CPU spikes from the router talking back to itself.
    "net.ipv4.icmp_echo_ignore_broadcasts" = true;
  };

  ###########################################################################
  # Interfaces: physical WAN (+ tagged VLAN 300 for Odido, see above),
  # physical flat LAN (no VLAN sub-interfaces on that side)
  ###########################################################################

  networking = {
    hostName = "router";
    useDHCP = false; # we set DHCP per-interface explicitly below
    nameservers = [ "127.0.0.1" ]; # the router itself resolves via dnsmasq (see below)

    vlans."${wanVlanIf}" = {
      id = wanVlanId;
      interface = wanIf;
    };

    interfaces = {
      "${wanIf}" = {
        useDHCP = true; # behind Odido's router: plain DHCP lease
      };
      "${wanVlanIf}" = {
        useDHCP = true; # replacing Odido's router: tagged DHCP straight to their ONT
      };
      "${lanIf}" = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = lanGateway;
            prefixLength = 24;
          }
        ];
      };
    };
  };

  ###########################################################################
  # Firewall (nftables directly, not the networking.firewall wrapper)
  #
  # LIMITATION: on this flat LAN, rules only govern (a) traffic reaching
  # the router itself (input) and (b) LAN<->WAN traffic (forward) - not
  # device-to-device traffic on the same wire (switched, never hits the
  # router). See top-of-file comment / README.
  ###########################################################################

  networking.nftables.enable = true;
  networking.firewall.enable = false; # fully replaced by nftables.ruleset below

  networking.nftables.ruleset = ''
    # both WAN paths (plain + Odido VLAN 300, see interfaces above) count as WAN
    define wan_ifs = { ${lib.concatMapStringsSep ", " (i: "\"${i}\"") wanIfs} }

    table ip filter {
      # iot is blocked from WAN by default (see forward chain)
      set iot_wan_allowed {
        type ipv4_addr
        flags interval
        ${lib.optionalString (iotWanAllowed != [ ])
          "elements = { ${lib.concatMapStringsSep ", " (h: h.ip) iotWanAllowed} }"
        }
      }

      # fixed-range devices only get SSH if their MAC also matches - stops
      # a device from just claiming an unused fixed-range IP for access
      set fixed_hosts {
        type ether_addr . ipv4_addr
        ${lib.optionalString (fixedHosts != [ ])
          "elements = { ${lib.concatMapStringsSep ", " (h: "${h.mac} . ${h.ip}") fixedHosts} }"
        }
      }

      chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept comment "loopback"
        ct state { established, related } accept comment "return traffic for existing connections"

        # WAN: only reply to a few diagnostic ICMP types, nothing else unsolicited
        iifname $wan_ifs icmp type { echo-request, destination-unreachable, time-exceeded } accept comment "allow diagnostic ICMP"
        iifname $wan_ifs counter drop comment "drop all other unsolicited WAN traffic"

        # SSH: allowed from everywhere except net/services/iot ranges (key-only
        # auth via PasswordAuthentication=false below). dynamic is included so a
        # brand-new/unrecognized device can still get in. fixed additionally
        # requires the MAC to match (see fixed_hosts set above).
        iifname "${lanIf}" ip saddr { ${computeLo}-${computeHi}, ${storageLo}-${storageHi}, ${dynamicLo}-${dynamicHi} } tcp dport 22 accept comment "SSH from compute/storage/dynamic"
        iifname "${lanIf}" ip saddr ${fixedLo}-${fixedHi} ether saddr . ip saddr @fixed_hosts tcp dport 22 accept comment "SSH from fixed range, MAC-bound"

        # DNS/DHCP must reach every range or nothing gets an address/can resolve names
        iifname "${lanIf}" udp dport { 53, 67 } accept comment "DNS+DHCP for all LAN clients"
        iifname "${lanIf}" tcp dport 53 accept comment "DNS (TCP fallback) for all LAN clients"

        counter drop comment "default-deny anything else destined for the router itself"
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        ct state { established, related } accept comment "return traffic for existing connections"

        iifname "${lanIf}" oifname $wan_ifs ip saddr ${iotLo}-${iotHi} ip saddr @iot_wan_allowed accept comment "explicit iot -> WAN exceptions (see iotHosts wan=true in router.nix)"
        iifname "${lanIf}" oifname $wan_ifs ip saddr ${iotLo}-${iotHi} counter drop comment "iot blocked from WAN by default"

        iifname "${lanIf}" oifname $wan_ifs accept comment "LAN -> WAN for all other clients"

        counter drop comment "default-deny anything not explicitly allowed above"
      }
    }

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname $wan_ifs masquerade comment "NAT all outbound LAN traffic to the WAN IP"
      }
    }

    # IPv6 out of scope for now (see README); default-deny both hooks.
    table ip6 filter {
      chain input {
        type filter hook input priority 0; policy drop;
      }
      chain forward {
        type filter hook forward priority 0; policy drop;
      }
    }
  '';

  ###########################################################################
  # DHCP + DNS via dnsmasq: MAC -> range assignment lives entirely here.
  #
  #   - iot / fixed: plain dhcp-host = "mac,ip,name" pins a fixed IP.
  #   - services: hosts request/keep their own IP; the .30-49 dhcp-range is
  #     gated with tag:services, so only MACs tagged via
  #     dhcp-host = "mac,set:services" (no fixed IP) can get a lease there -
  #     an unregistered MAC requesting .30-49 is refused and falls through
  #     to dynamic instead.
  #   - dynamic: unlisted MACs land here automatically.
  #   - net / compute / storage: static, never touch DHCP.
  ###########################################################################

  services.dnsmasq = {
    enable = true;
    settings = {
      # Upstream resolvers: the Pi-holes.
      server = [
        lib.lxcs.ahole.ip
        lib.lxcs.bhole.ip
        lib.lxcs.chole.ip
      ];

      # cuts down on noise from malformed/broadcast-y IoT DNS queries
      domain-needed = true;
      bogus-priv = true;

      # listen on LAN + loopback only, never WAN
      interface = [
        lanIf
        "lo"
      ];
      bind-interfaces = true;
      except-interface = wanIf;

      # services is gated to tag:services (see dhcp-host below); dynamic is
      # the untagged catch-all for everything else
      dhcp-range = [
        "tag:services,${servicesLo},${servicesHi},1h"
        "${dynamicLo},${dynamicHi},12h"
      ];

      dhcp-option = [
        "6,${lib.lxcs.ahole.ip},${lib.lxcs.bhole.ip},${lib.lxcs.bhole.ip}"
      ];

      # fill in real MACs; unlisted MACs land in dynamic automatically
      dhcp-host =
        (map (h: "${h.mac},${h.ip},${h.name}") fixedHosts)
        ++ (map (h: "${h.mac},${h.ip},${h.name}") iotHosts)
        ++ [
          # services: tag only, no fixed IP - proves the MAC may use .30-49
          "bc:24:11:f4:1f:43,set:services" # home-assistant
        ];
    };
  };

  # openFirewall=false: nftables above already governs SSH access; the ssh
  # module must not punch its own hole in the firewall
  # https://skogsbrus.xyz/building-a-router-with-nixos/#ssh-port-22

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "yes";
    };
  };

  # Stability/performance tweaks for low-end hardware running headless
  nix.settings.auto-optimise-store = true; # keep the store lean; storage is small
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.timeout = lib.mkDefault 3; # don't sit at a GRUB menu with no monitor attached

  documentation.enable = false;
  documentation.nixos.enable = false;

  environment.systemPackages = with pkgs; [
    tcpdump
    ethtool
    conntrack-tools
    dnsutils
  ];
}
