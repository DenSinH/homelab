{
  config,
  pkgs,
  lib,
  ...
}:

{
  sops.secrets = {
    "influxdb/tokens/nas" = {
      sopsFile = ../../secrets/telemetry.yaml;
      group = "telegraf";
      mode = "0440";
    };
  };

  # S.M.A.R.T values
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications = {
      mail.enable = false;
      wall.enable = true;
    };
    # default is every 30m; stretch it out so the HGST drives spend more
    # time idle/parked between checks
    extraOptions = [ "--interval=3600" ];
  };

  environment.systemPackages = with pkgs; [
    smartmontools # for smartctl
  ];

  # the HGST He8 drives tick every ~5s when idle unless we set a short
  # EPC Idle B timer, which parks the heads ~60s after the last access
  systemd.services.hdd-epc-idle-b = {
    description = "Set EPC Idle B timer to 60s on HGST He8 drives";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for d in \
        /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJN8RGZ \
        /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJKM0LZ; do
        ${pkgs.openseachest}/bin/openSeaChest_PowerControl -d "$(readlink -f "$d")" --idle_b 60000
      done
    '';
  };

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

        # ensure drives go to idle
        maxInterval = "1h";

        extraFlags = [
          # smartctl fails on usb-connected drive
          "--smartctl.scan-device-type=by-id"
          "--smartctl.device-exclude=^usb-Seagate_Expansion_HDD_00000000NT1AHEWJ-0:0$"
          # don't disturb drive idle mode
          "--smartctl.rescan=1h"
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
      INFLUX_TOKEN=${config.sops.placeholder."influxdb/tokens/nas"}
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
          "http://${lib.lxcs.telemetry.ip}:8086"
        ];

        token = "$INFLUX_TOKEN";

        organization = "nas";
        bucket = "nas";
      };
    };
  };

}
