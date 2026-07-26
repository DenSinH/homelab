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

  # TEMPORARY TESTING SWITCH: flip to true to allow SSH from WAN (e.g. when
  # the WAN side is plugged into a network you don't have LAN access to
  # yet). Still key-only auth (PasswordAuthentication=false below), but
  # this is otherwise a real hole in the WAN default-drop - set back to
  # false once testing is done, don't leave it on.
  testAllowSshFromWan = false;

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
    # Dennis devices
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
      mac = "2c:7b:a0:11:f9:54";
      ip = "${lanSubnet}.202";
      name = "hvee113-work-laptop";
    }

    # Merel devices
    {
      mac = "28:49:e9:76:15:8d";
      ip = "${lanSubnet}.210";
      name = "iphone-merel";
    }

    # Multimedia
    {
      mac = "f4:4d:ad:04:1c:d4";
      ip = "${lanSubnet}.240";
      name = "chromecast-badkamer";
    }
    {
      mac = "64:c9:01:b7:41:9f";
      ip = "${lanSubnet}.241";
      name = "lenovo-tiny-gaming";
    }
  ];

  # IoT devices (.50-99): listed once here, used to generate the dnsmasq
  # dhcp-host reservation. Set wan = true to also let that device reach
  # the public internet (see iot_wan_allowed set); everything else in
  # this range is blocked from WAN by default.
  iotHosts = [
    # Automation
    {
      mac = "5c:2f:af:36:55:d8";
      ip = "${lanSubnet}.50"; # todo: reconfigure HA
      name = "p1-meter-homewizard";
    }
    {
      mac = "34:5f:45:19:d8:28";
      ip = "${lanSubnet}.51"; # todo: reconfigure HA
      name = "shellyplus2pm";
    }
    {
      mac = "fc:f5:c4:98:e3:ee";
      ip = "${lanSubnet}.52"; # todo: reconfigure HA
      name = "otgw";
    }
    {
      mac = "38:7a:cc:70:25:4a";
      ip = "${lanSubnet}.53"; # todo: reconfigure HA
      name = "eufy-vacuum";
      wan = true;
    }

    # Smart bulbs
    {
      mac = "d8:a0:11:49:43:c0";
      ip = "${lanSubnet}.60";
      name = "wiz-4943c0";
    }
    {
      mac = "6c:29:90:80:42:a8";
      ip = "${lanSubnet}.61";
      name = "wiz-8042a8";
    }
    {
      mac = "d8:a0:11:e2:30:53";
      ip = "${lanSubnet}.62";
      name = "wiz-e23053";
    }
    {
      mac = "d8:a0:11:e1:07:8b";
      ip = "${lanSubnet}.63";
      name = "wiz-e1078b";
    }
    {
      mac = "d8:a0:11:e1:07:9f";
      ip = "${lanSubnet}.64";
      name = "wiz-e1079f";
    }
    {
      mac = "d8:a0:11:b2:c4:3d";
      ip = "${lanSubnet}.65";
      name = "wiz-b2c43d";
    }

    # Sonos speakers
    {
      mac = "b8:e9:37:32:72:ec";
      ip = "${lanSubnet}.70";
      name = "sonos-zp";
      wan = true;
    }
    {
      mac = "b8:e9:37:82:35:18";
      ip = "${lanSubnet}.71";
      name = "sonos-1";
      wan = true;
    }
    {
      mac = "5c:aa:fd:46:b3:c6";
      ip = "${lanSubnet}.72";
      name = "sonos-2";
      wan = true;
    }
    {
      mac = "b8:e9:37:56:28:b4";
      ip = "${lanSubnet}.73";
      name = "sonos-3";
      wan = true;
    }
  ];
  iotWanAllowed = builtins.filter (h: h.wan or false) iotHosts;

  # Services (.30-49): MAC is tagged via dhcp-host = "mac,set:services" (no
  # fixed IP) so it may take a lease from the tag:services dhcp-range;
  # unregistered MACs requesting that range are refused and fall through
  # to dynamic instead.
  servicesHosts = [
    {
      mac = "bc:24:11:f4:1f:43";
      name = "home-assistant";
    }
  ];
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
    # Bucket count isn't derived automatically like the in-tree module
    # default (ram/16k, roughly) - size it explicitly against max so the
    # hash table doesn't get walked as long chains once IoT/guest devices
    # fill up conntrack.
    "net.netfilter.nf_conntrack_buckets" = 16384;
    "net.ipv4.tcp_syncookies" = true; # basic SYN-flood mitigation
    # Don't let a burst of tiny broadcast/multicast traffic from IoT gear
    # cause log spam or CPU spikes from the router talking back to itself.
    "net.ipv4.icmp_echo_ignore_broadcasts" = true;

    # Throughput tuning for NAT'ing a 2.5Gbit LAN through a 1Gbit WAN: raise
    # the socket buffer ceilings and the pre-softirq packet queue so bursts
    # don't get dropped/throttled before they even reach conntrack/nftables.
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.core.netdev_max_backlog" = 5000;

    # BBR generally outperforms cubic on the kind of consumer WAN link this
    # box sits behind; fq is the companion qdisc BBR expects.
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
  };

  # BBR isn't builtin on all kernels/configs - make sure the module is loaded.
  boot.kernelModules = [ "tcp_bbr" ];

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

  # The build-time `nft --check` sandbox (see networking.nftables.checkRuleset)
  # has no real NICs, so resolving the flowtable's physical device names
  # (enp1s0/enp1s0.300/enp2s0) fails there even though they exist fine at
  # actual boot. Swap in "lo" - which always exists - for the check copy only.
  # https://discourse.nixos.org/t/33031
  networking.nftables.preCheckRuleset = ''
    sed -E 's/devices = \{[^}]*\}/devices = { "lo" }/' -i ruleset.conf
  '';

  networking.nftables.ruleset = ''
    # both WAN paths (plain + Odido VLAN 300, see interfaces above) count as WAN
    define wan_ifs = { ${lib.concatMapStringsSep ", " (i: "\"${i}\"") wanIfs} }

    table ip filter {
      # Software flow offload: once a TCP/UDP flow has been accepted below,
      # hand it off here so its remaining packets bypass this whole chain
      # (and conntrack lookups) instead of being routed/filtered per-packet.
      # Big CPU win for NAT throughput on low-power hardware like the APU4D4.
      flowtable fastpath {
        hook ingress priority 0;
        devices = { ${lib.concatMapStringsSep ", " (i: "\"${i}\"") (wanIfs ++ [ lanIf ])} }
      }

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
        ${lib.optionalString testAllowSshFromWan ''
          iifname $wan_ifs tcp dport 22 accept comment "TEMPORARY: SSH from WAN for testing - see testAllowSshFromWan in router.nix"
        ''}
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

        iifname "${lanIf}" oifname $wan_ifs ip saddr ${iotLo}-${iotHi} ip saddr @iot_wan_allowed meta l4proto { tcp, udp } flow add @fastpath comment "offload explicit iot -> WAN exceptions to the fastpath"
        iifname "${lanIf}" oifname $wan_ifs ip saddr ${iotLo}-${iotHi} ip saddr @iot_wan_allowed accept comment "explicit iot -> WAN exceptions (see iotHosts wan=true in router.nix)"
        iifname "${lanIf}" oifname $wan_ifs ip saddr ${iotLo}-${iotHi} counter drop comment "iot blocked from WAN by default"

        iifname "${lanIf}" oifname $wan_ifs meta l4proto { tcp, udp } flow add @fastpath comment "offload LAN -> WAN TCP/UDP flows to the fastpath"
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
        ++ (map (h: "${h.mac},set:services # ${h.name}") servicesHosts);
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

  # Keep the CPU pinned at full clock instead of scaling with load - avoids
  # frequency-transition latency spikes on the packet-forwarding hot path.
  powerManagement.cpuFreqGovernor = "performance";

  # cpuFreqGovernor only controls clock speed, not idle depth. Without this,
  # the CPU can still drop into deep C-states when idle between packets, and
  # waking from one to service the first interrupt after a quiet period can
  # add tens of ms of one-off latency (the classic "first ping is slow"
  # symptom on an otherwise-idle router). Cap how deep it's allowed to sleep.
  boot.kernelParams = [
    "processor.max_cstate=1"
    "intel_idle.max_cstate=0"
  ];

  # Spread NIC interrupts across cores instead of pinning everything to CPU0.
  services.irqbalance.enable = true;

  # Enable NIC hardware offloads (checksum/TSO/GSO/GRO) on both physical
  # interfaces. NixOS' scripted networking has no first-class option for
  # this, so set it explicitly once the device exists.
  systemd.services."router-nic-offload" = {
    description = "Enable NIC hardware offloads on router interfaces";
    after = [
      "sys-subsystem-net-devices-${wanIf}.device"
      "sys-subsystem-net-devices-${lanIf}.device"
    ];
    bindsTo = [
      "sys-subsystem-net-devices-${wanIf}.device"
      "sys-subsystem-net-devices-${lanIf}.device"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for dev in ${wanIf} ${lanIf}; do
        ${pkgs.ethtool}/bin/ethtool -K "$dev" rx on tx on tso on gso on gro on || true
        # Disable Energy Efficient Ethernet - the link partner drops into a
        # low-power idle mode after inactivity, and waking it back up for the
        # first frame adds noticeable one-off latency (same symptom class as
        # CPU C-states above, just on the wire instead of on the CPU).
        ${pkgs.ethtool}/bin/ethtool --set-eee "$dev" eee off || true
      done
    '';
  };

  documentation.enable = false;
  documentation.nixos.enable = false;

  environment.systemPackages = with pkgs; [
    tcpdump
    ethtool
    conntrack-tools
    dnsutils
  ];
}
