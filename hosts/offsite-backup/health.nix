{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Largely copied from NAS health.nix
  sops.defaultSopsFile = ../../secrets/telemetry.yaml;
  sops.secrets = {
    "influxdb/tokens/offsite-backup" = {
      group = "telegraf";
      mode = "0440";
    };
  };

  imports = [
    # same alloy monitoring as LXCs
    (import ../../modules/telemetry/alloy.nix {
      inherit pkgs lib;
      host = lib.backup.offsite-backup;
    })
  ];

  # S.M.A.R.T values
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      mail.enable = false;
      wall.enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    smartmontools # for smartctl
  ];

  services.prometheus = {
    enable = true;
    port = 9090;
    listenAddress = "0.0.0.0";

    exporters = {
      node = {
        enable = true;
        enabledCollectors = [
          "systemd"
          "zfs"
        ];
        port = 9100;
        listenAddress = "127.0.0.1";
      };
      smartctl = {
        enable = true;
        port = 9633;
        listenAddress = "127.0.0.1";

        # smartctl fails on usb-connected drive
        extraFlags = [
          "--smartctl.scan-device-type=by-id"
          "--smartctl.device-exclude=^usb-Seagate_Expansion_HDD_00000000NT1AHEWJ-0:0$"
        ];
      };
      zfs = {
        enable = true;
        port = 9134;
        listenAddress = "127.0.0.1";
        pools = [ "tank" ];
      };
    };
  };

  sops.templates."telegraf.env" = {
    content = ''
      INFLUX_TOKEN=${config.sops.placeholder."influxdb/tokens/offsite-backup"}
    '';
  };

  services.telegraf = {
    enable = true;

    environmentFiles = [
      config.sops.templates."telegraf.env".path
    ];

    extraConfig = {
      agent = {
        interval = "30s";
      };

      inputs.prometheus = {
        urls = [
          "http://localhost:9100/metrics"
          "http://localhost:9134/metrics"
          "http://localhost:9633/metrics"
        ];
      };

      outputs.influxdb_v2 = {
        urls = [
          # must connect over VPN
          "http://${lib.lxcs.telemetry.tailnet_ip}:8086"
        ];

        token = "$INFLUX_TOKEN";

        organization = "offsite-backup";
        bucket = "offsite-backup";
      };
    };
  };
}
