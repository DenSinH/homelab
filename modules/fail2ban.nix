{
  pkgs,
  lib,
  config,
  ...
}:

let
  denyDir = "/var/lib/nginx-deny";

  # Every probe pattern below is wrapped as:  <pre><body><post>
  #  - fail2ban cuts the timestamp out of the line before matching, so we only
  #    anchor on <HOST> at the start and the quoted request line.
  #  - <body> starts right after the leading "/" of the request path.
  #  - the status must be an error, so a path that really exists (200) is never counted.
  pre = ''^<HOST> - .* "[A-Z]+ /'';
  post = ''[^"]* HTTP/[0-9.]+" (?:400|401|403|404|405|444) .*'';

  probeBodies = [
    # --- well-known scanner directories, only at the site root ---
    "(?:wp-admin|wp-content(?!/uploads/)|wp-includes|wordpress|phpmyadmin|phpMyAdmin|pma|myadmin|mysql|cgi-bin|vendor|actuator|icecoder|langflow|boaform|HNAP1|manager/html|jenkins|solr|_ignition|_profiler|telescope|server-status|server-info|owa|ecp|autodiscover|aspnet_client)(?=[/ ?])"

    # --- dotfiles and dot-directories, at any depth (/.git/config, /api/.env, /a/b/.aws/credentials) ---
    ''(?:[^ ?"]*/)?(?:\.git|\.svn|\.hg|\.bzr|\.aws|\.docker|\.ssh|\.kube|\.vscode|\.idea|\.npm|\.config|\.bash_history|\.bashrc|\.profile|\.zsh_history|\.mysql_history|\.DS_Store|\.htaccess|\.htpasswd|\.gitignore|\.gitlab-ci\.yml|\.travis\.yml|\.dockerignore|\.npmrc|\.pypirc|\.netrc|\.s3cfg)(?=[/ ?])''
    ''(?:[^ ?"]*/)?\.env(?:[._-][^ ?/"]*)?(?=[/ ?])''

    # --- sensitive files, at any depth ---
    ''(?:[^ ?"]*/)?(?:wp-login\.php|xmlrpc\.php|adminer(?:\.php)?|phpinfo\.php|info\.php|eval-stdin\.php|wp-config\.php[^ ?"]*|docker-compose(?:[.-][a-z.]+)?\.ya?ml|Dockerfile|id_rsa|id_ed25519|id_dsa|authorized_keys|known_hosts|credentials\.json|secrets?\.(?:json|ya?ml|txt)|web\.config|composer\.(?:json|lock)|package(?:-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile(?:\.lock)?|requirements\.txt|terraform\.tfstate|serviceAccountKey\.json|appsettings(?:\.[A-Za-z]+)?\.json|parameters\.ya?ml|local_settings\.py|settings\.py|configuration\.php|config\.(?:php|inc\.php|bak|old|ini|ya?ml)|(?:db|database|dump|backup|backups|site|www|public_html|html|web|wwwroot)\.(?:sql|sqlite3?|bak|old|zip|tar|tar\.gz|tgz|gz|rar|7z))(?=[ ?])''

    # --- generic server-side scripts a static blog / Nix service never serves (index.php is left alone: old WordPress URLs) ---
    ''(?:[^ ?"]*/)?(?!index\.php[ ?])[^ ?"/]+\.php(?=[ ?])''
    ''(?:[^ ?"]*/)?[^ ?"/]+\.(?:asp|aspx|ashx|jsp|jspx|cgi|cfm|action|do)(?=[ ?])''

    # --- JS config / bundle guessing (seen in your logs from 34.140.234.80), site root only ---
    ''(?:config|index|app|main|bundle|settings|constants|env|env-config|runtime-config|aws-exports|app\.config)\.js(?=[ ?])''
    ''config/config\.js(?=[ ?])''

    # --- app-specific exploit endpoints (seen in your logs from 136.110.28.221) ---
    "(?:(?:api|v1|v2)/)*graphql(?=[/ ?])"
    "(?:langflow/)?api/v1/(?:validate/code|build_public_tmp|node-custom-function|node-load-method)(?=[/ ?])"

    # --- path traversal / injection strings anywhere in the request ---
    # (a literal % must be written %% in fail2ban config files)
    ''[^"]*(?:\.\.(?:/|%%2[fF]|%%5[cC])|%%2[eE]%%2[eE](?:/|%%2[fF]|%%5[cC])|%%252[eE]|/etc/passwd|/proc/self|php://|data://|expect://|\$\{jndi:|%%24%%7[bB]jndi|[uU][nN][iI][oO][nN](?:\+|%%20| )[sS][eE][lL][eE][cC][tT]|<script|%%3[cC]script|base64_decode|allow_url_include|/bin/(?:ba)?sh)''
  ];

  probeRegexes = lib.concatMapStringsSep "\n    " (body: "${pre}${body}${post}") probeBodies;
in
{
  assertions = [
    {
      assertion = config.services.nginx.enable && config.services.nginx.virtualHosts ? default;
      message = ''
        The fail2ban/nginx hardening module requires
        services.nginx.virtualHosts.default to be configured for your service.
      '';
    }
  ];

  services.nginx = {
    # get actual IP from CF-Connecting-IP header
    # tail access logs with
    #   tail -f /var/log/nginx/access.log
    virtualHosts.default = {
      extraConfig = ''
        set_real_ip_from ${lib.lxcs.cloudflared.ip};
        real_ip_header CF-Connecting-IP;
      '';
    };

    # Bans written by fail2ban: one `deny <ip>;` file per jail and IP.
    # A glob include is fine when empty (and passes build-time validation).
    # It is evaluated after realip, so it matches the real client IP.
    commonHttpConfig = ''
      include ${denyDir}/*.conf;
    '';
  };

  # --- nginx-level bans ---------------------------------------------------
  # iptables bans are useless here: every connection comes from the
  # cloudflared LXC. fail2ban drops a `deny` file into denyDir instead, and a
  # path unit reloads nginx whenever the directory changes.
  # nginx runs as its own user, so denyDir must be world-readable (it cannot
  # live under /var/lib/fail2ban, which is 0750 root).
  systemd.tmpfiles.rules = [
    "d ${denyDir} 0755 root root -"
  ];

  # fail2ban runs with ProtectSystem=strict
  systemd.services.fail2ban.serviceConfig.ReadWritePaths = [ denyDir ];

  systemd.paths.nginx-deny-reload = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = denyDir;
  };

  systemd.services.nginx-deny-reload = {
    description = "Reload nginx after the fail2ban ban list changed";
    # scan bursts can ban many IPs quickly; don't trip the start limit
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemctl reload nginx.service";
    };
  };

  # Drop ban files that outlived their ban (e.g. fail2ban was down when it
  # expired). The longest ban is the 1 week recidive ban; fail2ban rewrites
  # the files of still-active bans when it restarts.
  systemd.services.nginx-deny-prune = {
    description = "Prune stale nginx deny files";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.findutils}/bin/find ${denyDir} -name '*.conf' -mtime +8 -delete";
    };
  };
  systemd.timers.nginx-deny-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # One file per jail AND ip, so unbanning an IP from one jail (e.g. nginx-probes
  # after 24h) doesn't lift its longer recidive ban.
  environment.etc."fail2ban/action.d/nginx-deny.conf".text = ''
    [Definition]
    actionstart =
    actionstop =
    actioncheck =
    # write to a temp name first so nginx never reads a half-written file
    actionban = ${pkgs.coreutils}/bin/echo "deny <ip>;" > ${denyDir}/<name>-<ip>.tmp && ${pkgs.coreutils}/bin/chmod 0644 ${denyDir}/<name>-<ip>.tmp && ${pkgs.coreutils}/bin/mv ${denyDir}/<name>-<ip>.tmp ${denyDir}/<name>-<ip>.conf
    actionunban = ${pkgs.coreutils}/bin/rm -f ${denyDir}/<name>-<ip>.conf

    [Init]
    name = default
  '';

  # additional hardening on the cloudflare side:
  # https://github.com/buybitart/cloudflare-security-art
  #
  # NOTE: the NixOS fail2ban module sets `backend = "systemd"` in the DEFAULT
  # section, which makes every jail ignore `logpath` and read the journal.
  # Jails that read nginx's access.log therefore need `backend = "auto"`.
  services.fail2ban = {
    enable = true;

    # use the nginx deny action for every jail (incl. recidive) instead of iptables
    banaction = "nginx-deny";
    banaction-allports = "nginx-deny";

    ignoreIP = [
      "127.0.0.1/8"
      "::1"
      "192.168.50.0/24" # LAN
      "100.64.0.0/10" # VPN
      # never ban the tunnel itself: if real_ip ever breaks, every client looks
      # like this address and a ban would take the whole site offline
      lib.lxcs.cloudflared.ip
    ];

    jails = {
      # reads the nginx *error* log, which NixOS sends to the journal (stderr)
      nginx-http-auth = {
        enabled = true;

        settings = {
          backend = "systemd";
          journalmatch = "_SYSTEMD_UNIT=nginx.service";
        };
      };

      nginx-botsearch = {
        enabled = true;

        settings = {
          backend = "auto";
          logpath = "/var/log/nginx/access.log";
        };
      };

      nginx-bad-request = {
        enabled = true;

        settings = {
          backend = "auto";
          logpath = "/var/log/nginx/access.log";
        };
      };

      # known scanner paths: see probeBodies above
      nginx-probes = {
        enabled = true;

        settings = {
          backend = "auto";
          filter = "nginx-probes";
          logpath = "/var/log/nginx/access.log";

          maxretry = 3;
          findtime = "10m";
          bantime = "24h";
        };
      };

      # POST that ends in an error. A static blog never gets legitimate ones;
      # scanners POST to /app, /graphql etc. If a service on this host has
      # legitimate POSTs that can 404/405, disable it there with:
      #   services.fail2ban.jails.nginx-post-probe.enabled = lib.mkForce false;
      nginx-post-probe = {
        enabled = lib.mkDefault true;

        settings = {
          backend = "auto";
          filter = "nginx-post-probe";
          logpath = "/var/log/nginx/access.log";

          maxretry = 3;
          findtime = "10m";
          bantime = "24h";
        };
      };

      nginx-404 = {
        enabled = true;

        settings = {
          backend = "auto";
          filter = "nginx-404";
          logpath = "/var/log/nginx/access.log";

          # actual scan bursts observed are ~10 requests/second
          maxretry = 20;
          findtime = "10m";
          bantime = "1h";
        };
      };

      recidive = {
        enabled = true;

        settings = {
          # fail2ban's own logtarget defaults to SYSLOG on NixOS (see
          # services.fail2ban.daemonSettings.Definition.logtarget), so
          # /var/log/fail2ban.log is never actually written
          # read its own ban notices from the journal instead.
          backend = "systemd";
          journalmatch = "_SYSTEMD_UNIT=fail2ban.service";

          findtime = "1d";
          maxretry = 5;
          bantime = "1w";
        };
      };
    };
  };

  environment.etc."fail2ban/filter.d/nginx-probes.conf".text = ''
    [Definition]
    failregex = ${probeRegexes}
    ignoreregex =
  '';

  environment.etc."fail2ban/filter.d/nginx-post-probe.conf".text = ''
    [Definition]
    failregex = ^<HOST> - .* "POST .* HTTP/[0-9.]+" (?:400|401|403|404|405|444) .*
    ignoreregex =
  '';

  environment.etc."fail2ban/filter.d/nginx-404.conf".text = ''
    [Definition]
    failregex = ^<HOST> - .* "(?:GET|POST|HEAD) .* HTTP/[0-9.]+" 404 .*
    # missing media/assets are normal (old blog images, favicon, crawlers)
    ignoreregex = ^<HOST> - .* "(?:GET|HEAD) \S+\.(?:jpe?g|png|gif|webp|avif|svg|ico|css|map|woff2?|ttf|txt|xml)(?:\?\S*)? HTTP/[0-9.]+" 404 .*
  '';

  # diagnostic script
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "fail2ban-status" ''
      set -e

      jails=$(
        sudo fail2ban-client status |
          sed -n 's/.*Jail list:[[:space:]]*//p' |
          tr ',' ' '
      )

      echo "=== Fail2Ban ==="
      for jail in $jails; do
        echo
        echo "[$jail]"
        sudo fail2ban-client status "$jail" |
          grep -E 'Currently failed|Currently banned|Total failed|Total banned|Banned IP list'
      done

      echo
      echo "=== All active bans ==="
      for jail in $jails; do
        banned=$(
          sudo fail2ban-client status "$jail" |
            sed -n 's/.*Banned IP list:[[:space:]]*//p'
        )

        if [ -n "$banned" ]; then
          echo "[$jail]"
          echo "$banned" | tr ' ' '\n' | sed 's/^/  /'
        fi
      done

      echo
      echo "=== nginx deny files ==="
      ls ${denyDir} 2>/dev/null || true
    '')
  ];
}
