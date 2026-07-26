########################################################################
# NixOS router — WAN + ONE FLAT LAN, with MAC-based static IP "profiles"
# (trusted / iot) and a dynamic fallback pool for anything unrecognized.
#
# !!! This is deliberately NOT VLANs. !!!
# The original design used 802.1Q VLAN trunking, but that requires a
# VLAN-aware ("managed") switch to split the trunk into separate
# broadcast domains downstream. With only unmanaged switches and
# non-SDN-capable Asus APs (AX57/AX55) in the loop, there's nothing
# downstream that can honor VLAN tags, so trunking would just be
# tags nothing understands.
#
# What this file gives you instead:
#   - Devices with a known MAC get a fixed IP in either the "trusted" or
#     "iot" range via dnsmasq's dhcp-host, decided purely by MAC address.
#   - Anything with an unrecognized MAC falls through to a general
#     dynamic pool (the guest-equivalent fallback) automatically -
#     that's just how dnsmasq behaves when a MAC has no dhcp-host entry.
#   - The router's firewall enforces different WAN/admin-access policy
#     per range (e.g. only "trusted" can SSH in).
#
# What this file CANNOT give you, and no nftables config can fix without
# a VLAN-capable switch: isolation *between* devices on the same wire.
# Traffic between two hosts on the same flat LAN is switched directly at
# layer 2 and never reaches the router's forward chain, so e.g. an IoT
# device can still directly probe a laptop sitting on the same switch.
# See the README for what would close this gap (a ~$25 managed switch).
#
# Written for, and adapting patterns from:
#   - Solene Rapenne, "NixOS with a live-usb router"
#     https://dataswamp.org/~solene/2022-08-03-nixos-with-live-usb-router.html
#   - Johan (skogsbrus), "Building a Router with NixOS"
#     https://skogsbrus.xyz/building-a-router-with-nixos/
#     (dnsmasq static leases, per-interface firewall ports,
#      services.openssh.openFirewall = false)
#   - Francis Begyn, "Setting up my own router with NixOS"
#     https://francis.begyn.be/blog/nixos-home-router
#     (APU install-over-serial, GRUB w/ serial console)
#   - Josh Pearce (jjpdev), "DIY Home Router with NixOS"
#     https://www.jjpdev.com/posts/home-router-nixos/
#     (nftables input/forward chain layout, DHCP-bypasses-firewall gotcha)
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

  # One flat LAN, carved into ranges by convention (not by VLAN/subnet -
  # they're all the same /24, just different address bands). Adjust to
  # taste, just keep them non-overlapping and inside lanSubnet.
  lanSubnet = "192.168.27";
  lanGateway = "${lanSubnet}.1";
  trustedLo = "${lanSubnet}.10";
  trustedHi = "${lanSubnet}.99";
  iotLo = "${lanSubnet}.100";
  iotHi = "${lanSubnet}.149";
  fallbackLo = "${lanSubnet}.150"; # unrecognized MACs land here (guest-equivalent)
  fallbackHi = "${lanSubnet}.250";
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
  # Interfaces: physical WAN, physical flat LAN (no VLAN sub-interfaces)
  ###########################################################################

  networking = {
    hostName = "router";
    useDHCP = false; # we set DHCP per-interface explicitly below
    nameservers = [ "127.0.0.1" ]; # the router itself resolves via dnsmasq (see below)

    interfaces = {
      "${wanIf}" = {
        useDHCP = true; # get a public/CGNAT IP + gateway from the ISP
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
  # IMPORTANT LIMITATION: since lanIf is one flat LAN (see the big comment
  # at the top of this file for why), these rules can only govern:
  #   (a) what reaches the router itself (input chain), and
  #   (b) what crosses from LAN to WAN, or would cross between two
  #       *routed* subnets if you ever add one (forward chain).
  # They cannot stop two devices on the same LAN from talking directly to
  # each other - that traffic is switched, not routed, and never reaches
  # this ruleset. The forward-chain rules below are still worth having
  # (they're correct, and become fully meaningful again the day you add a
  # managed switch and turn these ranges into real VLANs), just don't
  # mistake them for device-to-device isolation today.
  ###########################################################################

  networking.nftables.enable = true;
  networking.firewall.enable = false; # fully replaced by nftables.ruleset below

  networking.nftables.ruleset = ''
    table ip filter {
      chain input {
        type filter hook input priority 0; policy drop;

        # Always allow loopback and already-established/related traffic.
        iifname "lo" accept comment "loopback"
        ct state { established, related } accept comment "return traffic for existing connections"

        # --- WAN (untrusted) ---
        # Only reply to a small set of ICMP types; drop everything else
        # unsolicited from the internet. https://shouldiblockicmp.com/
        iifname "${wanIf}" icmp type { echo-request, destination-unreachable, time-exceeded } accept comment "allow diagnostic ICMP"
        iifname "${wanIf}" counter drop comment "drop all other unsolicited WAN traffic"

        # --- LAN, admin services gated by IP range ---
        # Only the trusted range may SSH into the router. Since this
        # traffic terminates at the router itself, this restriction is
        # fully enforced regardless of the flat-LAN limitation above.
        iifname "${lanIf}" ip saddr ${trustedLo}-${trustedHi} tcp dport 22 accept comment "SSH from trusted range only"

        # DNS/DHCP must be reachable by every device on the LAN
        # (trusted, iot, and the dynamic/guest-equivalent fallback alike),
        # or nothing gets an address or can resolve names. Per jjpdev,
        # DHCP broadcast/ARP traffic bypasses some of this anyway, but we
        # keep it explicit: https://www.jjpdev.com/posts/home-router-nixos/#debugging-with-nftrace
        iifname "${lanIf}" udp dport { 53, 67 } accept comment "DNS+DHCP for all LAN clients"
        iifname "${lanIf}" tcp dport 53 accept comment "DNS (TCP fallback) for all LAN clients"

        counter drop comment "default-deny anything else destined for the router itself"
      }

      chain forward {
        type filter hook forward priority 0; policy drop;

        ct state { established, related } accept comment "return traffic for existing connections"

        # Every device on the LAN gets outbound internet access,
        # regardless of range.
        iifname "${lanIf}" oifname "${wanIf}" accept comment "LAN -> WAN for all clients"

        # Kept for clarity and for when this becomes a real routed
        # boundary later (e.g. after adding a managed switch): trusted
        # devices may initiate connections toward the iot range.
        # On today's flat LAN this rule is largely inert, since
        # same-subnet traffic never reaches the forward chain - see the
        # limitation notice above.
        iifname "${lanIf}" oifname "${lanIf}" ip saddr ${trustedLo}-${trustedHi} ip daddr ${iotLo}-${iotHi} accept comment "trusted -> iot management (only affects routed hops, see README)"

        counter drop comment "default-deny anything not explicitly allowed above"
      }
    }

    table ip nat {
      chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "${wanIf}" masquerade comment "NAT all outbound LAN traffic to the WAN IP"
      }
    }

    # IPv6 is not configured on this router (see README for why + how to add
    # it later). Default-deny both hooks so nothing leaks out unfiltered if
    # the ISP link happens to hand out SLAAC/DHCPv6 addresses anyway.
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
  # DHCP + DNS via dnsmasq: MAC -> profile assignment lives entirely here.
  #
  # How the "assign by MAC, fallback to guest" behaviour works:
  #   - Every dhcp-host line below pins one known MAC to a fixed IP inside
  #     either the trusted or iot range.
  #   - Any device whose MAC is NOT listed gets an address from the
  #     `dhcp-range` pool instead (the fallback/guest-equivalent range) -
  #     this is standard dnsmasq behaviour, nothing extra to configure.
  #   - The firewall rules in the ruleset above then key off which range
  #     an IP falls in.
  #
  # dnsmasq is preferred here over isc-dhcpd for one simple combined
  # DNS+DHCP+static-lease config, matching skogsbrus's setup:
  # https://skogsbrus.xyz/building-a-router-with-nixos/#dnsmasq
  ###########################################################################

  services.dnsmasq = {
    enable = true;
    settings = {
      # Upstream resolvers the router itself queries on behalf of clients.
      # Let's just use the Pi-holes for this.
      server = [
        lib.lxcs.ahole.ip
        lib.lxcs.bhole.ip
        lib.lxcs.chole.ip
      ];

      # Ignore DNS queries with no dots that aren't in /etc/hosts - cuts
      # down on noise from malformed/broadcast-y IoT queries.
      domain-needed = true;
      bogus-priv = true;

      # Only listen on the LAN interface + loopback, never on WAN.
      interface = [
        lanIf
        "lo"
      ];
      bind-interfaces = true;
      except-interface = wanIf;

      # Only the fallback/guest-equivalent band needs a dhcp-range - the
      # trusted/iot bands are populated entirely by the dhcp-host static
      # reservations below. dnsmasq still requires at least one dhcp-range
      # to enable DHCP service on this interface at all.
      dhcp-range = "${fallbackLo},${fallbackHi},12h"; # shorter lease: unknown/guest devices churn more

      # Point DHCP clients at Pi-hole for DNS
      dhcp-option = [
        "6,${lib.lxcs.ahole.ip},${lib.lxcs.bhole.ip},${lib.lxcs.bhole.ip}"
      ];

      # !!! Fill these in with your actual devices' MAC addresses !!!
      # Format: "mac,ip,hostname". Anything not listed here lands in the
      # fallback range above automatically.
      dhcp-host = [
        # --- trusted (10.10.0.10-10.10.0.99) ---
        # "aa:bb:cc:dd:ee:01,10.10.0.20,alices-laptop"
        # "aa:bb:cc:dd:ee:02,10.10.0.21,bobs-phone"

        # --- iot (10.10.0.100-10.10.0.149) ---
        # "aa:bb:cc:dd:ee:10,10.10.0.100,smart-plug"
        # "aa:bb:cc:dd:ee:11,10.10.0.101,robot-vacuum"
      ];
    };
  };

  ###########################################################################
  # SSH: enabled, but NOT auto-opened in the firewall (nftables input chain
  # above explicitly only allows it from the trusted IP range, and never
  # from WAN). Without openFirewall = false, NixOS's ssh module would
  # punch its own hole in the firewall regardless of our rules.
  # https://skogsbrus.xyz/building-a-router-with-nixos/#ssh-port-22
  ###########################################################################

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "yes";
    };
  };

  ###########################################################################
  # Stability/performance tweaks for low-end hardware running headless
  ###########################################################################

  # Keep the store lean; low-end mSATA/SD storage fills up fast otherwise.
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  boot.loader.timeout = lib.mkDefault 3; # don't sit at a GRUB menu with no monitor attached

  # A router doesn't need the local manual/docs build eating CPU/disk on
  # every rebuild.
  documentation.enable = false;
  documentation.nixos.enable = false;

  environment.systemPackages = with pkgs; [
    tcpdump
    ethtool
    conntrack-tools
    dnsutils
  ];
}
