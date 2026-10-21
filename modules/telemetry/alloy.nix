{
  lib,
  config,
  host,
  ...
}:

let
  cfg = config.homelab.alloy;

  # True when extraLokiProcessConfig contains anything but whitespace.
  hasExtra = builtins.match "[[:space:]]*" cfg.extraLokiProcessConfig == null;

  # Where the journal source sends its entries.
  sourceTarget = if hasExtra then "loki.process.extra.receiver" else "loki.write.default.receiver";

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
      forward_to    = [${sourceTarget}]
      relabel_rules = discovery.relabel.journal.rules
      labels = {
        job = "systemd-journal",
      }
    }

    ${lib.optionalString hasExtra ''
      // Host-specific stages set via homelab.alloy.extraLokiProcessConfig.
      loki.process "extra" {
        forward_to = [loki.write.default.receiver]

        ${cfg.extraLokiProcessConfig}
      }
    ''}

    // Sends the final log stream to Loki. The constant "host" label is
    // attached here (once per batch) instead of in a per-line pipeline stage.
    loki.write "default" {
      endpoint {
        url        = "${cfg.lokiUrl}/loki/api/v1/push"
        batch_wait = "10s"
        batch_size = "2MiB"
      }

      external_labels = {
        host = "${host.hostname}",
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
        Extra Alloy (River) pipeline stages injected into a "loki.process"
        block that sits between the journal source and loki.write. The block
        is only generated when this option is non-empty, so hosts without
        extra stages skip the processing hop entirely.

        Note: the constant "host" label is attached by loki.write
        (external_labels), after these stages run, so selectors here cannot
        match on {host="..."}. Match on {unit="..."} instead.

        Useful for host-specific log processing, e.g. forcing the detected
        level of a noisy-but-not-actually-erroring log line to "warning"
        instead of the "error" Loki would otherwise auto-detect from the raw
        log text, using a `stage.match` block such as:

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

    systemd.services.alloy.environment = {
      # avoid spinning up multiple OS threads for GC/workers
      GOMAXPROCS = "1";
      # collect less often on a tiny heap; the limit keeps memory bounded
      GOGC = "200";
      GOMEMLIMIT = "128MiB";
    };

    environment.etc."alloy/config.alloy".text = alloyConfig;
  };
}
