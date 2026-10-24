{
  config,
  lib,
  pkgs,
  ...
}:
let
  envFile = config.sops.templates."email-report.env".path;

  # Where timestamped reports, latest.html and index.html live.
  # systemd's StateDirectory="reports" on the services creates /var/lib/reports
  # owned by reporting:reporting, mode 0750.
  reportsDir = "/var/lib/reports";

  # Standalone hosts: each has its own node_exporter + smartctl_exporter +
  # zfs_exporter feeding a dedicated InfluxDB org/bucket, and gets a ZFS/SMART/
  # filesystems/timers section in the report (report.py's host_section).
  #
  # To add one:
  #   1. add a { org = "..."; label = "..."; } entry below -- `org` must match
  #      its InfluxDB bucket name;
  #   2. add its influxdb/reporting/<org> key to secrets/telemetry.yaml (the
  #      telemetry LXC provisions the matching token in InfluxDB);
  #   3. that's it -- report.py has no host-specific code, it just iterates
  #      whatever's in `hosts` below.
  #
  # This does NOT cover Proxmox-managed guests/VMs/nodes -- those are already
  # fully dynamic, discovered straight from the `proxmox` InfluxDB org.
  standaloneHosts = [
    {
      org = "nas";
      label = "NAS";
    }
    {
      org = "offsite-backup";
      label = "Offsite backup host";
    }
  ];

  influxOrgs = [
    "proxmox"
    "homeassistant"
  ]
  ++ map (h: h.org) standaloneHosts;
  tokenSecret = org: "influxdb/reporting/${org}";
  tokenVar = org: "INFLUX_TOKEN_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] org);

  rootOnly = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  expectedLogHosts = lib.unique (
    let
      hostname = h: h.hostname;
      fromAttrs = attrs: map hostname (builtins.attrValues attrs);
    in
    [ (hostname lib.router) ]
    ++ fromAttrs lib.hosts
    ++ fromAttrs lib.storage
    ++ fromAttrs lib.backup
    ++ fromAttrs lib.lxcs
  );

  reportConfig = pkgs.writeText "report-config.json" (
    builtins.toJSON {
      influx_url = "http://${lib.lxcs.telemetry.ip}:8086";
      loki_url = "http://${lib.lxcs.telemetry.ip}:3100";
      grafana_url = "http://${lib.lxcs.telemetry.ip}:3000";
      # link to the report archive shown in the e-mail footer; adjust to taste
      report_url = "http://${config.networking.hostName}/";
      output_dir = reportsDir;
      hosts = standaloneHosts;
      # guests that are supposed to be stopped (anything else stopped is reported as critical)
      expected_stopped = [
        "actualbudget"
        "bazarr"
        "byparr"
        "pdm"
        "win-test"
        "nixos"
        "static-site-nixos"
      ];
      # guests removed on purpose (name as it appears in the Proxmox metrics)
      known_removed = [
        "firefly"
        "trek-nixos"
      ];
      # regexes matched against "host/unit latest-message"; matching log sources are hidden
      log_ignore = [ ];
      logs = {
        # every host in lib.router / lib.hosts / lib.storage / lib.backup / lib.lxcs
        expected_hosts = expectedLogHosts;
        # source_label = "job";   # uncomment if your Loki uses `job` instead of `unit`
      };
      # any other key of DEFAULTS in report.py can be overridden here, e.g.:
      # timers = { "syncoid-tank-drive.timer" = 30; };
      thresholds = {
        disk_warn = 90;
        disk_crit = 95;
      };
    }
  );

  # Python + Jinja2 for report.py
  reportPython = pkgs.python3.withPackages (ps: [ ps.jinja2 ]);

  # Runs one of our python scripts with the SMTP + token environment loaded.
  mkTool =
    {
      name,
      script,
      args ? [ ],
      path ? [ ],
      python ? pkgs.python3,
    }:
    pkgs.writeShellScriptBin name ''
      set -a
      . ${envFile}
      set +a
      ${lib.optionalString (path != [ ]) "export PATH=${lib.makeBinPath path}:$PATH"}
      exec ${python}/bin/python3 ${script} ${lib.escapeShellArgs args} "$@"
    '';

  sendMail = mkTool {
    name = "send-mail";
    script = ./send.py;
  };

  # sudo report-now             -> save + e-mail the report
  # sudo report-now --dry-run   -> save the report but skip the e-mail
  reportNow = mkTool {
    name = "report-now";
    script = ./report.py;
    args = [
      "--config"
      reportConfig
      "--template"
      "${./report.html.j2}"
      "--text-template"
      "${./report.txt.j2}"
      "--index-template"
      "${./index.html.j2}"
    ];
    path = [ sendMail ];
    python = reportPython;
  };

  # Regenerates only index.html (used at boot and after cleanup).
  reportIndex = mkTool {
    name = "report-index";
    script = ./report.py;
    args = [
      "--config"
      reportConfig
      "--template"
      "${./report.html.j2}"
      "--text-template"
      "${./report.txt.j2}"
      "--index-template"
      "${./index.html.j2}"
      "--index-only"
    ];
    python = reportPython;
  };

  # Hardened systemd services, built on lib.hardenedService. All three run as
  # the unprivileged `reporting` user and only touch /var/lib/reports.

  # report-now needs to reach InfluxDB, Loki, and the SMTP server.
  reportHardening = lib.hardenedService // {
    ReadWritePaths = [ reportsDir ];
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
  };

  # report-index/cleanup only read/write local files; no network needed at
  # all, so only AF_UNIX (for syslog) is allowed.
  indexHardening = lib.hardenedService // {
    ReadWritePaths = [ reportsDir ];
    RestrictAddressFamilies = [ "AF_UNIX" ];
  };
in
{
  homelab.hardenedServices = [
    "daily-report"
    "reports-index"
    "reports-cleanup"
  ];

  environment.systemPackages = [
    sendMail
    reportNow
  ];

  # the report runs as an unprivileged user; only the rendered env file is readable by it
  users.groups.reporting = { };
  users.users.reporting = {
    isSystemUser = true;
    group = "reporting";
  };

  # nginx workers need read access to /var/lib/reports
  users.users.nginx.extraGroups = [ "reporting" ];

  sops.defaultSopsFile = ../../secrets/reporting.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets = {
    "smtp2go/username" = rootOnly;
    "smtp2go/password" = rootOnly;
    "mail/from" = rootOnly;
    "mail/to" = rootOnly;
  }
  # these tokens are shared with the telemetry LXC (which provisions them in InfluxDB)
  // lib.genAttrs (map tokenSecret influxOrgs) (
    _: rootOnly // { sopsFile = ../../secrets/telemetry.yaml; }
  );

  sops.templates."email-report.env" = {
    owner = "reporting";
    group = "reporting";
    mode = "0400";
    content = ''
      SMTP_USERNAME='${config.sops.placeholder."smtp2go/username"}'
      SMTP_PASSWORD='${config.sops.placeholder."smtp2go/password"}'
      MAIL_FROM='${config.sops.placeholder."mail/from"}'
      MAIL_TO='${config.sops.placeholder."mail/to"}'
    ''
    + lib.concatMapStrings (
      org: "${tokenVar org}='${config.sops.placeholder.${tokenSecret org}}'\n"
    ) influxOrgs;
  };

  # --- daily-report ---------------------------------------------------------
  systemd.services.daily-report = {
    description = "Daily homelab e-mail report";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = reportHardening // {
      Type = "oneshot";
      User = "reporting";
      Group = "reporting";
      StateDirectory = "reports";
      StateDirectoryMode = "0750";
      UMask = "0027";
      ExecStart = "${reportNow}/bin/report-now";
    };
  };

  systemd.timers.daily-report = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 07:30:00";
      Persistent = true;
    };
  };

  # --- reports-index --------------------------------------------------------
  # Bootstrap / refresh index.html at boot, before nginx needs to serve it.
  systemd.services.reports-index = {
    description = "Regenerate the homelab report index";
    serviceConfig = indexHardening // {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "reporting";
      Group = "reporting";
      StateDirectory = "reports";
      StateDirectoryMode = "0750";
      UMask = "0027";
      ExecStart = "${reportIndex}/bin/report-index";
    };
  };

  # nginx pulls in the index service, no sandbox fight, no ownership dance.
  systemd.services.nginx = {
    wants = [ "reports-index.service" ];
    after = [ "reports-index.service" ];
  };

  # --- reports-cleanup ------------------------------------------------------
  systemd.services.reports-cleanup = {
    description = "Prune homelab reports older than 30 days";
    after = [ "reports-index.service" ];
    serviceConfig = indexHardening // {
      Type = "oneshot";
      User = "reporting";
      Group = "reporting";
      StateDirectory = "reports";
      StateDirectoryMode = "0750";
      UMask = "0027";
      ExecStart = pkgs.writeShellScript "reports-cleanup" ''
        set -euo pipefail
        export PATH=${
          lib.makeBinPath [
            pkgs.findutils
            pkgs.coreutils
          ]
        }
        cd "$STATE_DIRECTORY"
        find . -maxdepth 1 -type f \( -name 'report-*.html' -o -name 'report-*.txt' \) -mtime +30 -delete
        newest=$(find . -maxdepth 1 -type f -name 'report-*.html' | sort | tail -n1)
        if [ -n "$newest" ]; then
          ln -sfn "$newest" latest.html
        else
          rm -f latest.html
        fi
      '';
      # refresh the index so it no longer lists the deleted reports
      ExecStartPost = "${reportIndex}/bin/report-index";
    };
  };

  systemd.timers.reports-cleanup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # No TLS: a read-only report archive, fine over plain HTTP on the LAN.
  # - /             -> index.html (list of all reports, newest first)
  # - /latest.html  -> newest report (updated after every run)
  # - /report-*.html -> individual reports
  services.nginx = {
    enable = true;

    virtualHosts."_" = {
      root = reportsDir;
      locations."/" = {
        index = "index.html";
        tryFiles = "$uri $uri/ =404";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
  ];
}
