# Known non-flake LAN devices (routers, phones, IoT, etc.), keyed by name so
# they can be referenced elsewhere (e.g. usbip.nix). Used by homelab.nix's
# `router` to build dnsmasq/nftables host lists.
{
  lib,
  lan,
}:

let
  # Every device with an `ip` must have a `category` matching one of
  # lan.ranges, and that ip must actually fall inside that range.
  validate =
    name: device:
    if !(device ? ip) then
      device
    else
      let
        octets = lib.splitString "." device.ip;
        prefix = lib.concatStringsSep "." (lib.lists.init octets);
        last = lib.toInt (lib.lists.last octets);
        range =
          lan.ranges.${device.category}
            or (throw "devices.nix: ${name} has unknown category '${device.category}'");
      in
      assert
        prefix == lan.subnet
        || throw "devices.nix: ${name}'s ip ${device.ip} is not on ${lan.subnet}.0/${toString lan.prefixLength}";
      assert
        (last >= range.lo && last <= range.hi)
        || throw "devices.nix: ${name}'s ip ${device.ip} is outside the '${device.category}' range (.${toString range.lo}-.${toString range.hi})";
      device;

  devices = {
    # Networking equipment
    asus-ax57 = {
      category = "fixed";
      mac = "60:cf:84:af:52:c8";
      ip = "${lan.subnet}.250";
    };
    asus-ax55 = {
      category = "fixed";
      mac = "24:4b:fe:1d:34:50";
      ip = "${lan.subnet}.251";
    };

    # Dennis devices
    dennis-telefoon = {
      category = "fixed";
      mac = "7c:f0:e5:52:96:17";
      ip = "${lan.subnet}.200";
    };
    dennis-laptop = {
      category = "fixed";
      mac = "50:5a:65:34:0e:19";
      ip = "${lan.subnet}.201";
    };
    hvee113-work-laptop = {
      category = "fixed";
      mac = "2c:7b:a0:11:f9:54";
      ip = "${lan.subnet}.202";
    };
    docking-station = {
      category = "fixed";
      mac = "64:c9:01:b7:41:9f";
      ip = "${lan.subnet}.203";
    };

    # Merel devices
    iphone-merel = {
      category = "fixed";
      mac = "28:49:e9:76:15:8d";
      ip = "${lan.subnet}.210";
    };

    # Multimedia
    chromecast-badkamer = {
      category = "fixed";
      mac = "f4:4d:ad:04:1c:d4";
      ip = "${lan.subnet}.240";
    };
    samsung-tv = {
      category = "fixed";
      mac = "20:15:de:91:96:68";
      ip = "${lan.subnet}.241";
    };

    # IoT: automation. `wan` required on every entry; false = LAN-only.
    p1-meter-homewizard = {
      category = "iot";
      mac = "5c:2f:af:36:55:d8";
      ip = "${lan.subnet}.50";
      wan = false;
    };
    shellyplus2pm = {
      category = "iot";
      mac = "34:5f:45:19:d8:28";
      ip = "${lan.subnet}.51";
      wan = false;
    };
    otgw = {
      category = "iot";
      mac = "fc:f5:c4:98:e3:ee";
      # Had to be changed in /config/.storage/core.config_entries
      # https://community.home-assistant.io/t/594055
      ip = "${lan.subnet}.52";
      wan = false;
    };
    eufy-vacuum = {
      category = "iot";
      mac = "38:7a:cc:70:25:4a";
      ip = "${lan.subnet}.53";
      wan = true;
    };

    # IoT: smart bulbs
    wiz-4943c0 = {
      category = "iot";
      mac = "d8:a0:11:49:43:c0";
      ip = "${lan.subnet}.60";
      wan = false;
    }; # kitchen-middle-lamp
    wiz-8042a8 = {
      category = "iot";
      mac = "6c:29:90:80:42:a8";
      ip = "${lan.subnet}.61";
      wan = false;
    }; # kitchen-storage-lamp
    wiz-e23053 = {
      category = "iot";
      mac = "d8:a0:11:e2:30:53";
      ip = "${lan.subnet}.62";
      wan = false;
    }; # dining-lamp-painting
    wiz-e1078b = {
      category = "iot";
      mac = "d8:a0:11:e1:07:8b";
      ip = "${lan.subnet}.63";
      wan = false;
    }; # tv-lamp
    wiz-e1079f = {
      category = "iot";
      mac = "d8:a0:11:e1:07:9f";
      ip = "${lan.subnet}.64";
      wan = false;
    }; # dining-lamp-jim
    wiz-b2c43d = {
      category = "iot";
      mac = "d8:a0:11:b2:c4:3d";
      ip = "${lan.subnet}.65";
      wan = false;
    }; # kitchen-living-lamp

    tuya-light-string = {
      category = "iot";
      mac = "50:8b:b9:8a:43:8c";
      ip = "${lan.subnet}.69";
      wan = false;
    };

    # IoT: Sonos speakers
    sonos-zp = {
      category = "iot";
      mac = "b8:e9:37:32:72:ec";
      ip = "${lan.subnet}.70";
      wan = true;
    }; # Play:3 (living room)
    sonos-1 = {
      category = "iot";
      mac = "b8:e9:37:82:35:18";
      ip = "${lan.subnet}.71";
      wan = true;
    }; # Play:1 (kitchen)
    sonos-2 = {
      category = "iot";
      mac = "5c:aa:fd:46:b3:c6";
      ip = "${lan.subnet}.72";
      wan = true;
    }; # Play:1 (record player)
    sonos-3 = {
      category = "iot";
      mac = "b8:e9:37:56:28:b4";
      ip = "${lan.subnet}.73";
      wan = true;
    }; # Play:1 (dining table)

    # IoT: printer
    epson-xp-3200 = {
      category = "iot";
      mac = "f8:25:51:2f:6b:aa";
      ip = "${lan.subnet}.99";
      wan = false;
    };

    # Services: tag-gated, self-requested IP - not dnsmasq-enforced.
    home-assistant = {
      category = "services";
      mac = "bc:24:11:f4:1f:43";
      ip = "${lan.subnet}.31";
    };
  };
in
lib.mapAttrs validate devices
