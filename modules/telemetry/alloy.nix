{
  lib,
  config,
  host,
  ...
}:

let
  cfg = config.homelab.alloy;

  alloyConfig = ''
    // Relabeling rules applied to journal entries before they're read.
    // This maps the internal journal field __journal__systemd_unit
    // to a proper label called "unit".
    discovery.relabel "journal" {
      targets = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
    }

    // Reads logs from the local systemd journal.
    loki.source.journal "read" {
      forward_to    = [loki.process.add_labels.receiver]
      relabel_rules = discovery.relabel.journal.rules
      labels = {
        job = "systemd-journal",
      }
    }

    // Adds a constant "host" label to every log line passing through, then
    // runs any host-specific stages set via homelab.alloy.extraLokiProcessConfig.
    loki.process "add_labels" {
      forward_to = [loki.write.default.receiver]

      stage.static_labels {
        values = {
          host = "${host.hostname}",
        }
      }

      ${cfg.extraLokiProcessConfig}
    }

    // Sends the final log stream to Loki.
    loki.write "default" {
      endpoint {
        url = "${cfg.lokiUrl}/loki/api/v1/push"
      }
    }
  '';
in
{
  options.homelab.alloy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run Grafana Alloy to ship this host's systemd-journal
        logs to the central Loki instance.
      '';
    };

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${lib.lxcs.telemetry.ip}:3100";
      description = ''
        Base URL of the Loki instance to push logs to. Defaults to the
        telemetry host's LAN IP; override per-host for hosts that can't
        reach it over the LAN (e.g. use lib.lxcs.telemetry.tailnet_ip for a
        host only reachable over Tailscale).
      '';
    };

    extraLokiProcessConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra Alloy (River) pipeline stages injected into the "add_labels"
        loki.process block defined by this module, after the static "host"
        label is added. Useful for host-specific log processing, e.g.
        forcing the detected level of a noisy-but-not-actually-erroring log
        line to "warning" instead of the "error" Loki would otherwise
        auto-detect from the raw log text, using a `stage.match` block such
        as:

        ```
        stage.match {
          selector = "{unit=\"someunit.service\"} |~ \"some regex\""

          stage.template {
            source   = "level"
            template = "warn"
          }

          stage.structured_metadata {
            values = {
              level = "",
            }
          }
        }
        ```
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      extraFlags = [
        "--disable-reporting"
      ];
    };

    environment.etc."alloy/config.alloy".text = alloyConfig;
  };
}
