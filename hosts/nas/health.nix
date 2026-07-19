{ config, pkgs, lib, ... }:

{
  imports = [
    # same alloy monitoring as LXCs
    (import ../../modules/telemetry/alloy.nix {
      inherit config pkgs lib;
      host = lib.storage.nas; 
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
      };
      zfs = {
        enable = true;
        port = 9134;
        listenAddress = "127.0.0.1";
        pools = [ "tank" ];
      };
    };

    globalConfig = {
      scrape_interval = "1m";
    };

    scrapeConfigs = [
      {
        job_name = "node";
        scrape_interval = "1s";
        static_configs = [ { targets = [ "localhost:9100" ]; } ];
      }
      {
        job_name = "smartctl";
        static_configs = [ { targets = [ "localhost:9633" ]; } ];
      }
      {
        job_name = "zfs";
        static_configs = [ { targets = [ "localhost:9134" ]; } ];
      }
    ];

    retentionTime = "7d";
  };

  networking.firewall.allowedTCPPorts = [
    9090 # prometheus
  ];
}
