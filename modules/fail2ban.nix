{
  pkgs,
  lib,
  config,
  ...
}:

let
  denyDir = "/var/lib/nginx-deny";
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

    # bans written by fail2ban (one `deny <ip>;` file per IP). A glob include
    # is fine when empty, so this also passes build-time config validation.
    # Evaluated after realip, so the real client IP is what gets matched.
    commonHttpConfig = ''
      include ${denyDir}/*.conf;
    '';
  };

  # --- nginx-level bans -------------------------------------------------
  # iptables bans are useless here: every connection comes from the
  # cloudflared LXC. Instead, fail2ban drops a `deny` file into denyDir and
  # a path unit reloads nginx whenever the directory changes.
  # (nginx runs as its own user, so the dir must be world-readable; it is
  # not under /var/lib/fail2ban, which is 0750 root.)
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
    description = "Reload nginx after fail2ban ban list changed";
    # scan bursts can ban many IPs quickly; don't trip the start limit
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemctl reload nginx.service";
    };
  };

  environment.etc."fail2ban/action.d/nginx-deny.conf".text = ''
    [Definition]
    actionstart =
    actionstop =
    actioncheck =
    # write to a temp name first so nginx never sees a half-written file
    actionban = ${pkgs.coreutils}/bin/echo "deny <ip>;" > ${denyDir}/<ip>.tmp && ${pkgs.coreutils}/bin/chmod 0644 ${denyDir}/<ip>.tmp && ${pkgs.coreutils}/bin/mv ${denyDir}/<ip>.tmp ${denyDir}/<ip>.conf
    actionunban = ${pkgs.coreutils}/bin/rm -f ${denyDir}/<ip>.conf
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
    # Each alternative only asserts a boundary (lookahead, not consumed) right
    # after the suspicious keyword, then the trailing ".*" before " HTTP/"
    # absorbs whatever deeper path/query follows - e.g. "/wp-admin/admin-ajax.php"
    # or "/wp-login.php?action=register", not just the bare "/wp-admin/" path.
    #
    # "wp-content(?!/uploads/)" skips missing media under /wp-content/uploads/:
    # the old WordPress blog images are still hotlinked/crawled, and normal
    # readers can trigger several of those 404s per page view.
    failregex = ^<HOST> - .* "(GET|POST|HEAD) /(?:(?:wp-admin|wp-content(?!/uploads/)|wp-includes|wordpress|\.git|\.svn|\.hg|\.bzr|phpmyadmin|phpMyAdmin|pma|cgi-bin|vendor/phpunit|(?:public/)?vendor/laravel-filemanager|\.aws|\.docker|\.ssh)(?=[/ ?]|$)|(?:wp-login\.php|xmlrpc\.php|adminer(?:\.php)?|docker-compose(?:\.ya?ml)?|Dockerfile|id_rsa|config\.php|configuration\.php|(?:db|database|dump|backup)\.(?:sql|sqlite|sqlite3|bak|old|zip|tar|gz)|(?:env-config|runtime-config|aws-exports|app\.config|config/config|env)\.js)(?=[ ?]|$)|\.env(?:\.[^ ?/]*)?(?=[/? ]|$)|backup(?=[/._\- ?]|$)).* HTTP/.*" (?:400|401|403|404|405|444) .*
    ignoreregex =
  '';

  environment.etc."fail2ban/filter.d/nginx-404.conf".text = ''
    [Definition]
    failregex = ^<HOST> - .* "(GET|POST|HEAD) .* HTTP/.*" 404 .*
    ignoreregex =
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
