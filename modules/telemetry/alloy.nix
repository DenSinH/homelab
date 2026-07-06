{
  config,
  pkgs,
  lib,
  host,
  ...
}:

let
  lokiUrl = "http://${lib.lxcs.telemetry.ip}:3100";

  alloyConfig = pkgs.writeText "alloy-config.alloy" ''
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

    // Adds a constant "host" label to every log line passing through.
    loki.process "add_labels" {
      forward_to = [loki.write.default.receiver]

      stage.static_labels {
        values = {
          host = "${host.hostname}",
        }
      }
    }

    // Sends the final log stream to Loki.
    loki.write "default" {
      endpoint {
        url = "${lokiUrl}/loki/api/v1/push"
      }
    }
  '';
in
{
  services.alloy = {
    enable = true;
  };

  environment.etc."alloy/config.alloy".source = alloyConfig;
}
