# Shared router network facts: topology + known-device lists, used by
# router.nix and other host-level files (e.g. health.nix) so things like
# interface names and the LAN subnet aren't duplicated/hardcoded in more
# than one place.
rec {
  wanIf = "enp1s0"; # 1Gbit
  lanIf = "enp2s0"; # 2.5Gbit

  # Odido (ISP) dual-mode WAN, see README "WAN / ISP replacement". Both
  # paths are brought up at once so either cabling works untouched; only
  # the one actually connected gets a lease.
  #   - behind Odido's own router: plain untagged DHCP.
  #   - replacing Odido's router (straight into their ONT): 802.1Q VLAN 300 + DHCP.
  # https://gathering.tweakers.net/forum/list_messages/2206944#eigenhardware
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
    # Networking equipment
    {
      mac = "60:cf:84:af:52:c8";
      ip = "${lanSubnet}.250";
      name = "asus-ax57";
    }
    {
      mac = "24:4b:fe:1d:34:50";
      ip = "${lanSubnet}.251";
      name = "asus-ax55";
    }

    # Dennis devices
    {
      mac = "7c:f0:e5:52:96:17";
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
    {
      mac = "64:c9:01:b7:41:9f";
      ip = "${lanSubnet}.203";
      name = "docking-station";
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
      mac = "20:15:de:91:96:68";
      ip = "${lanSubnet}.241";
      name = "samsung-tv";
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
      ip = "${lanSubnet}.50";
      name = "p1-meter-homewizard";
    }
    {
      mac = "34:5f:45:19:d8:28";
      ip = "${lanSubnet}.51";
      name = "shellyplus2pm";
    }
    {
      mac = "fc:f5:c4:98:e3:ee";
      # Had to be changed in /config/.storage/core.config_entries
      # https://community.home-assistant.io/t/594055
      ip = "${lanSubnet}.52";
      name = "otgw";
    }
    {
      mac = "38:7a:cc:70:25:4a";
      ip = "${lanSubnet}.53";
      name = "eufy-vacuum";
      wan = true;
    }

    # Smart bulbs
    {
      mac = "d8:a0:11:49:43:c0";
      ip = "${lanSubnet}.60";
      name = "wiz-4943c0"; # kitchen-middle-lamp
    }
    {
      mac = "6c:29:90:80:42:a8";
      ip = "${lanSubnet}.61";
      name = "wiz-8042a8"; # kitchen-storage-lamp
    }
    {
      mac = "d8:a0:11:e2:30:53";
      ip = "${lanSubnet}.62";
      name = "wiz-e23053"; # dining-lamp-painting
    }
    {
      mac = "d8:a0:11:e1:07:8b";
      ip = "${lanSubnet}.63";
      name = "wiz-e1078b"; # tv-lamp
    }
    {
      mac = "d8:a0:11:e1:07:9f";
      ip = "${lanSubnet}.64";
      name = "wiz-e1079f"; # dining-lamp-jim
    }
    {
      mac = "d8:a0:11:b2:c4:3d";
      ip = "${lanSubnet}.65";
      name = "wiz-b2c43d"; # kitchen-living-lamp
    }

    {
      mac = "50:8b:b9:8a:43:8c";
      ip = "${lanSubnet}.69";
      name = "tuya-light-string";
    }

    # Sonos speakers
    {
      mac = "b8:e9:37:32:72:ec";
      ip = "${lanSubnet}.70";
      name = "sonos-zp"; # Play:3 (living room)
      wan = true;
    }
    {
      mac = "b8:e9:37:82:35:18";
      ip = "${lanSubnet}.71";
      name = "sonos-1"; # Play:1 (kitchen)
      wan = true;
    }
    {
      mac = "5c:aa:fd:46:b3:c6";
      ip = "${lanSubnet}.72";
      name = "sonos-2"; # Play:1 (record player)
      wan = true;
    }
    {
      mac = "b8:e9:37:56:28:b4";
      ip = "${lanSubnet}.73";
      name = "sonos-3"; # Play:1 (dining table)
      wan = true;
    }

    # Printer
    {
      mac = "f8:25:51:2f:6b:aa";
      ip = "${lanSubnet}.99";
      name = "epson-xp-3200";
    }
  ];

  # Services (.30-49): MAC is tagged via dhcp-host = "mac,set:services" (no
  # fixed IP) so it may take a lease from the tag:services dhcp-range;
  # unregistered MACs requesting that range are refused and fall through
  # to dynamic instead.
  servicesHosts = [
    {
      mac = "bc:24:11:f4:1f:43";
      name = "home-assistant";
    }
    {
      mac = "bc:24:11:0c:5c:f4";
      name = "vps";
    }
  ];
}
