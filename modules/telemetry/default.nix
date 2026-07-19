{
  config,
  pkgs,
  lib,
  ...
}:

let
  retention = 7 * 24 * 60 * 60; # 7 days
  username = "admin";

  grafanaSecretFile =
    secretName:
    let
      secret = config.sops.secrets.${secretName};
    in
    "$__file{${secret.path}}";
in
{
  imports = [
    ./alloy.nix # gather own logs
  ];

  # secret access management
  users.groups.metrics = { };
  users.users.grafana.extraGroups = [ "metrics" ];
  users.users.influxdb2.extraGroups = [ "metrics" ];

  # configure secrets used on telemetry hosts
  sops.defaultSopsFile = ../../secrets/telemetry.yaml;
  sops.secrets = {
    # influxdb2 service runs as user `influxdb2` in group `influxdb2
    "influxdb/admin_pass" = {
      group = "influxdb2";
      mode = "0440";
    };
    "influxdb/admin_token" = {
      group = "influxdb2";
      mode = "0440";
    };

    # shared tokens for grafana / influxdb
    "influxdb/tokens/proxmox" = {
      group = "metrics";
      mode = "0440";
    };
    "influxdb/tokens/homeassistant" = {
      group = "metrics";
      mode = "0440";
    };

    "grafana/secret_key" = {
      group = "grafana";
      mode = "0440";
    };
    "grafana/admin_pass" = {
      group = "grafana";
      mode = "0440";
    };
  };

  services.influxdb2 = {
    enable = true;
    provision = {
      enable = true;

      initialSetup = {
        username = username;
        passwordFile = config.sops.secrets."influxdb/admin_pass".path;

        # these defaults will not be used
        organization = "main";
        bucket = "main";
        retention = retention;
        tokenFile = config.sops.secrets."influxdb/admin_token".path;
      };

      organizations = {
        proxmox = {
          description = "Organization for Proxmox data";

          buckets.proxmox = {
            description = "Bucket for Proxmox data";
            retention = retention;
          };

          auths."Host" = {
            description = "Token used by all Proxmox hosts and PBS";
            tokenFile = config.sops.secrets."influxdb/tokens/proxmox".path;
            readBuckets = [
              "proxmox"
            ];
            readPermissions = [
              "buckets"
            ];
            writeBuckets = [
              "proxmox"
            ];
            writePermissions = [
              "buckets"
            ];
          };
        };

        homeassistant = {
          description = "Organization for Home Assistant data";

          buckets."homeassistant" = {
            description = "Bucket for Home Assistant data";
            retention = retention;
          };

          auths."Host" = {
            description = "Token used by Home Assistant host";
            tokenFile = config.sops.secrets."influxdb/tokens/homeassistant".path;

            readBuckets = [
              "homeassistant"
            ];
            readPermissions = [
              "buckets"
            ];
            writeBuckets = [
              "homeassistant"
            ];
            writePermissions = [
              "buckets"
            ];
          };
        };
      };
    };
  };

  services.grafana = {
    enable = true;

    settings = {
      # https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
      server.http_addr = "0.0.0.0";

      security.admin_password = grafanaSecretFile "grafana/admin_pass";
      security.secret_key = grafanaSecretFile "grafana/secret_key";

      # needed for CSS injection
      panels.disable_sanitize_html = true;

      # anonymous viewer-mode dashboard access without manual interaction
      # this is needed for accessing the kiosk dashboard on my homelab display
      "auth.anonymous".enabled = true;
      "auth.anonymous".org_role = "Viewer";
    };

    provision = {
      enable = true;

      dashboards.settings.providers = [
        {
          name = "default";
          folder = "";
          type = "file";

          updateIntervalSeconds = 30;
          allowUiUpdates = false;

          options = {
            path = "/var/lib/grafana/dashboards";
          };
        }
      ];

      # influxdb2 is running on the same LXC, so anything can be accessed
      # through localhost
      datasources.settings.datasources = [
        {
          name = "InfluxDB - Proxmox";
          type = "influxdb";
          url = "http://localhost:8086";
          isDefault = true;

          jsonData = {
            version = "Flux";
            organization = "proxmox";
            defaultBucket = "proxmox";
            tlsSkipVerify = true;
          };

          secureJsonData = {
            token = grafanaSecretFile "influxdb/tokens/proxmox";
          };
        }

        {
          name = "InfluxDB - Home Assistant";
          type = "influxdb";
          url = "http://localhost:8086";
          isDefault = false;

          jsonData = {
            version = "Flux";
            organization = "homeassistant";
            defaultBucket = "homeassistant";
            tlsSkipVerify = true;
          };

          secureJsonData = {
            token = grafanaSecretFile "influxdb/tokens/homeassistant";
          };
        }

        {
          name = "Prometheus - NAS";
          type = "prometheus";
          url = "http://${lib.storage.nas.ip}:9090";
          isDefault = false;
        }

        {
          name = "Loki";
          type = "loki";
          url = "http://localhost:3100";
          isDefault = false;
        }
      ];
    };
  };

  services.loki = {
    enable = true;
    configFile = ./loki.yaml;
  };

  # Inspired by:
  # https://github.com/kartoza/bims-nixos/blob/77175170464f17afe83588aeba8e75ceae48ae9e/grafana-dashboards.nix
  # Place dashboard json files in /etc/grafana/dashboards/
  environment.etc = {
    "grafana/dashboards/kiosk.json" = {
      source = ./kiosk.json;
      mode = "0644";
    };
  };

  # Create symlinks from Grafana's dashboard directory to our files
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana/dashboards 0755 grafana grafana -"
    "L+ /var/lib/grafana/dashboards/kiosk.json - - - - /etc/grafana/dashboards/kiosk.json"
  ];

  networking.firewall = {
    allowedTCPPorts = [
      8086 # influxdb2
      3000 # grafana
      3100 # loki
    ];
  };
}
