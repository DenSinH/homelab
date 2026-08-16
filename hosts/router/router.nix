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
# https://gathering.tweakers.net/forum/list_messages/2206944#eigenhardware
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
  # Network topology + known-device lists shared with other files (e.g.
  # health.nix) - see network.nix.
  network = import ./network.nix;
  inherit (network)
    wanIf
    lanIf
    wanVlanId
    wanVlanIf
    wanIfs
    lanSubnet
    lanGateway
    netLo
    netHi
    computeLo
    computeHi
    storageLo
    storageHi
    servicesLo
    servicesHi
    iotLo
    iotHi
    dynamicLo
    dynamicHi
    fixedLo
    fixedHi
    fixedHosts
    iotHosts
    servicesHosts
    ;

  # TEMPORARY TESTING SWITCH: flip to true to allow SSH from WAN (e.g. when
  # the WAN side is plugged into a network you don't have LAN access to
  # yet). Still key-only auth (PasswordAuthentication=false below), but
  # this is otherwise a real hole in the WAN default-drop - set back to
  # false once testing is done, don't leave it on.
  testAllowSshFromWan = false;

  # Static rate cap for cake (see router-qos-cake below), a bit below the
  # real measured rate (~150mbit).
  qosBandwidth = "150mbit";

  iotWanAllowed = builtins.filter (h: h.wan or false) iotHosts;

  # home-assistant has no fixed IP (services range is a dynamic-tag pool, see
  # network.nix), so the usbip nftables rule below binds on this MAC instead.
  usbipAllowedMac =
    (lib.findFirst (
      h: h.name == "home-assistant"
    ) (throw "home-assistant missing from servicesHosts") servicesHosts).mac;

  # QoS priority tiers for the WAN link - cake diffserv4 tins, see below.
  # Voice > Video > Best Effort (default) > Bulk.
  qosVoiceHosts = map (h: h.ip) fixedHosts; # family devices
  qosVideoHosts = [
    lib.lxcs.immich.ip
    lib.lxcs.cloudflared.ip
  ];
  qosBulkHosts = [
    lib.lxcs.nixflix.ip
  ];
in
{
  assertions = [
    {
      assertion = !testAllowSshFromWan;
      message = ''
        testAllowSshFromWan is true in router.nix - this opens SSH to the WAN. 
        Set it back to false unless you're actively testing.
      '';
    }
  ];

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
    # Size the hash table explicitly against max instead of the in-tree
    # ram/16k default, so it doesn't turn into long chains under load.
    # https://docs.kernel.org/networking/nf_conntrack-sysctl.html
    "net.netfilter.nf_conntrack_buckets" = 16384;
    # Basic SYN-flood mitigation.
    # https://docs.kernel.org/networking/ip-sysctl.html#tcp-syncookies
    "net.ipv4.tcp_syncookies" = true;
    # Don't respond to broadcast/multicast pings - classic Smurf mitigation.
    # https://en.wikipedia.org/wiki/Smurf_attack
    "net.ipv4.icmp_echo_ignore_broadcasts" = true;

    # Raise socket buffer ceilings + pre-softirq queue for NAT'ing a 2.5Gbit
    # LAN through a 1Gbit WAN, so bursts don't drop before conntrack/nftables.
    # https://docs.kernel.org/admin-guide/sysctl/net.html
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.core.netdev_max_backlog" = 5000;

    # BBR outperforms cubic on typical consumer WAN links; fq is its companion qdisc.
    # https://github.com/google/bbr
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
  };

  # BBR isn't builtin on all kernels/configs - make sure the module is loaded.
  # sch_cake backs the QoS cake qdisc set up below.
  boot.kernelModules = [
    "tcp_bbr"
    "sch_cake"
  ];

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
      # Software flow offload: accepted flows get handed off here so their
      # remaining packets skip this whole chain instead of being
      # routed/filtered per-packet. Big CPU win on low-power hardware.
      # https://wiki.nftables.org/wiki-nftables/index.php/Flowtables
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

      # QoS priority tiers, see qosVoiceHosts/qosVideoHosts/qosBulkHosts.
      # DSCP tin mapping is cake's diffserv4:
      # https://man7.org/linux/man-pages/man8/tc-cake.8.html
      set qos_voice {
        type ipv4_addr
        flags interval
        ${lib.optionalString (
          qosVoiceHosts != [ ]
        ) "elements = { ${lib.concatStringsSep ", " qosVoiceHosts} }"}
      }
      set qos_video {
        type ipv4_addr
        flags interval
        ${lib.optionalString (
          qosVideoHosts != [ ]
        ) "elements = { ${lib.concatStringsSep ", " qosVideoHosts} }"}
      }
      set qos_bulk {
        type ipv4_addr
        flags interval
        ${lib.optionalString (
          qosBulkHosts != [ ]
        ) "elements = { ${lib.concatStringsSep ", " qosBulkHosts} }"}
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

        # darkstat web dashboard (see hosts/router/health.nix) - LAN only, keep port in sync
        iifname "${lanIf}" tcp dport 80 accept comment "darkstat dashboard for LAN clients"

        # usbip (see hosts/router/usbip.nix) - zigbee dongle export. No auth
        # of its own, so restrict to home-assistant's MAC (see
        # usbipAllowedMac above), not just LAN-wide like the other rules.
        iifname "${lanIf}" ether saddr ${usbipAllowedMac} tcp dport 3240 accept comment "usbip for zigbee dongle - home-assistant only"

        counter drop comment "default-deny anything else destined for the router itself"
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        # QoS: tag DSCP by tier - must run before the established/related
        # accept below (dscp set doesn't terminate, but accept does). saddr
        # = this host's own upload; daddr = its download (already un-NATed
        # by conntrack here). Read by the cake qdisc (router-qos-cake).
        ip saddr @qos_voice ip dscp set cs5 comment "QoS: family devices -> Voice tin"
        ip daddr @qos_voice ip dscp set cs5 comment "QoS: family devices -> Voice tin"
        ip saddr @qos_video ip dscp set cs3 comment "QoS: immich/cloudflared -> Video tin"
        ip daddr @qos_video ip dscp set cs3 comment "QoS: immich/cloudflared -> Video tin"
        ip saddr @qos_bulk ip dscp set cs1 comment "QoS: nixflix etc -> Bulk tin"
        ip daddr @qos_bulk ip dscp set cs1 comment "QoS: nixflix etc -> Bulk tin"

        ct state { established, related } accept comment "return traffic for existing connections"

        # Keep QoS-tagged hosts off the fastpath below: offloaded flows skip
        # this chain (and the dscp set rules above) for the rest of the
        # connection, which would un-prioritize long flows like nixflix.
        ip saddr @qos_voice accept comment "QoS: keep family devices off fastpath so shaping stays effective"
        ip daddr @qos_voice accept comment "QoS: keep family devices off fastpath so shaping stays effective"
        ip saddr @qos_video accept comment "QoS: keep immich/cloudflared off fastpath so shaping stays effective"
        ip daddr @qos_video accept comment "QoS: keep immich/cloudflared off fastpath so shaping stays effective"
        ip saddr @qos_bulk accept comment "QoS: keep nixflix etc off fastpath so shaping stays effective"
        ip daddr @qos_bulk accept comment "QoS: keep nixflix etc off fastpath so shaping stays effective"

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

      # net/compute/storage hosts (proxmoxes, nas, piholes, subnet-router,
      # cloudflared, etc.) are statically configured and never touch DHCP
      # (see comment above dhcp-range), so dnsmasq has no lease to derive a
      # hostname/PTR record from otherwise - darkstat (and anything else
      # doing reverse DNS) would just see "(none)" for them.
      host-record = [
        "router,${lanGateway}"
      ]
      ++ (map (h: "${h.hostname},${h.ip}") (builtins.attrValues lib.hosts))
      ++ (map (h: "${h.hostname},${h.ip}") (builtins.attrValues lib.storage))
      ++ (map (h: "${h.hostname},${h.ip}") (builtins.attrValues lib.lxcs));
    };
  };

  # openFirewall=false: nftables above already governs SSH access; the ssh
  # module must not punch its own hole in the firewall
  # https://skogsbrus.xyz/building-a-router-with-nixos/#ssh-port-22
  services.openssh = {
    openFirewall = lib.mkForce false;
  };

  # Stability/performance tweaks for low-end hardware running headless
  nix.settings.auto-optimise-store = true; # keep the store lean; storage is small
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.timeout = lib.mkDefault 3; # don't sit at a GRUB menu with no monitor attached

  # CPU / power saving settings
  powerManagement.cpuFreqGovernor = "schedutil";
  boot.kernelParams = [
    "pcie_aspm.policy=powersave"
  ];

  systemd.services.enable-eee = {
    description = "Enable Ethernet EEE";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-pre.target" ];
    before = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      ${pkgs.ethtool}/bin/ethtool --set-eee enp1s0 eee on
      ${pkgs.ethtool}/bin/ethtool --set-eee enp2s0 eee on
    '';
  };

  # Spread NIC interrupts across cores instead of pinning everything to CPU0.
  # https://linux.die.net/man/1/irqbalance
  services.irqbalance.enable = true;

  # Enable NIC hardware offloads (checksum/TSO/GSO/GRO) on both physical
  # interfaces. NixOS' scripted networking has no first-class option for
  # this, so set it explicitly once the device exists.
  # https://man7.org/linux/man-pages/man8/ethtool.8.html
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

  # QoS: cake qdisc, shapes download on lanIf and upload on wanIf/wanVlanIf.
  # Static bandwidth (plan says 100Mbit, actual is closer to 140Mbit - see
  # qosBandwidth above) rather than autorate-ingress: autorate-ingress has
  # to re-estimate from near-zero after every idle period and ramps back
  # up over several seconds, which was very noticeable as a slow-start on
  # otherwise-idle devices (phone, laptop) right after they resumed
  # transfers. A fixed rate has no such ramp, at the cost of not adapting
  # if the real line rate changes later.
  # diffserv4 sorts by the DSCP marks set in the forward chain above.
  # https://man7.org/linux/man-pages/man8/tc-cake.8.html
  systemd.services."router-qos-cake" = {
    description = "Apply CAKE QoS qdisc on router interfaces";
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
      ${pkgs.iproute2}/bin/tc qdisc replace dev ${lanIf} root cake bandwidth ${qosBandwidth} diffserv4

      for dev in ${lib.concatStringsSep " " wanIfs}; do
        ${pkgs.iproute2}/bin/tc qdisc replace dev "$dev" root cake bandwidth ${qosBandwidth} diffserv4 || true
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
    iproute2
  ];
}
