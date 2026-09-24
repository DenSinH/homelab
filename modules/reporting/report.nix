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

  influxOrgs = [
    "proxmox"
    "nas"
    "offsite-backup"
    "homeassistant"
  ];
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
      # guests that are supposed to be stopped (anything else stopped is reported as critical)
      expected_stopped = [
        "actualbudget"
        "bazarr"
        "byparr"
        "pdm"
        "win-test"
        "nixos"
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
      # thresholds = { temp_warn = 55; };
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

  # ---------------------------------------------------------------------------
  # Hardened systemd services
  # ---------------------------------------------------------------------------
  #
  # Common sandboxing for all three reporting services.  They all run as the
  # unprivileged `reporting` user and only ever touch /var/lib/reports.
  #
  # A quick way to check the result on a running system:
  #   systemd-analyze security daily-report.service
  #   systemd-analyze security reports-index.service
  #   systemd-analyze security reports-cleanup.service

  commonHardening = {
    # --- Privilege restrictions ------------------------------------------
    NoNewPrivileges = true; # cannot gain privileges via setuid/setgid
    RestrictSUIDSGID = true; # cannot create setuid/setgid files
    LockPersonality = true; # cannot change execution domain
    RestrictRealtime = true; # cannot use realtime scheduling
    RestrictNamespaces = true; # cannot unshare namespaces
    RemoveIPC = true; # no shared IPC objects after exit
    PrivateUsers = true; # own user namespace

    # --- Filesystem restrictions -----------------------------------------
    ProtectSystem = "strict"; # / is read-only except ReadWritePaths
    ProtectHome = true; # /home, /root, /run/user are invisible
    PrivateTmp = true; # own /tmp and /var/tmp
    PrivateDevices = true; # no access to physical devices
    ProtectProc = "invisible"; # /proc hides other users' processes
    ProcSubset = "pid"; # only own PIDs visible under /proc

    # --- Kernel / hardware restrictions ----------------------------------
    ProtectClock = true; # cannot set the system clock
    ProtectHostname = true; # cannot change hostname
    ProtectKernelLogs = true; # cannot read the kernel log
    ProtectKernelModules = true; # cannot load/unload modules
    ProtectKernelTunables = true; # cannot write sysctl/kernel tunables
    ProtectControlGroups = true; # cgroup hierarchy is read-only

    # --- Memory / syscall restrictions -----------------------------------
    MemoryDenyWriteExecute = true; # no W+X mappings (blocks many exploits)
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service" # a reasonable base for services
      "~@privileged" # deny privileged syscalls
      "~@resources" # deny resource-setting syscalls
      "~@obsolete" # deny obsolete syscalls
    ];
    CapabilityBoundingSet = [ "" ]; # drop all capabilities

    # --- Device / mount restrictions -------------------------------------
    DevicePolicy = "closed"; # no device access except /dev/null etc.
    PrivateMounts = true; # own mount namespace
  };

  # Networking differs per service, so it is not in commonHardening.
  reportNetwork = {
    # report-now needs to reach InfluxDB, Loki, and the SMTP server.
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
  };

  indexNetwork = {
    # report-index only reads local files and writes index.html.  It does not
    # talk to the network at all, so we allow only AF_UNIX (for syslog) and
    # explicitly deny everything else.
    RestrictAddressFamilies = [ "AF_UNIX" ];
  };
in
{
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
    serviceConfig =
      commonHardening
      // reportNetwork
      // {
        Type = "oneshot";
        User = "reporting";
        Group = "reporting";
        StateDirectory = "reports";
        StateDirectoryMode = "0750";
        UMask = "0027";
        ReadWritePaths = [ reportsDir ]; # the only writable path
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
    serviceConfig =
      commonHardening
      // indexNetwork
      // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "reporting";
        Group = "reporting";
        StateDirectory = "reports";
        StateDirectoryMode = "0750";
        UMask = "0027";
        ReadWritePaths = [ reportsDir ];
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
    serviceConfig =
      commonHardening
      // indexNetwork
      // {
        Type = "oneshot";
        User = "reporting";
        Group = "reporting";
        StateDirectory = "reports";
        StateDirectoryMode = "0750";
        UMask = "0027";
        ReadWritePaths = [ reportsDir ];
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

  # --- serve the reports over HTTP ----------------------------------------
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

  networking.firewall.allowedTCPPorts = [ 80 ];
}
