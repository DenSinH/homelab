{
  pkgs,
  lib,
  config,
  ...
}:

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
  };

  # additional hardening on the cloudflare side:
  # https://github.com/buybitart/cloudflare-security-art
  services.fail2ban = {
    enable = true;

    ignoreIP = [
      "127.0.0.1/8"
      "::1"
      "192.168.50.0/24" # LAN
      "100.64.0.0/10" # VPN
    ];

    jails = {
      nginx-http-auth = {
        enabled = true;
      };

      nginx-botsearch = {
        enabled = true;
      };

      nginx-bad-request = {
        enabled = true;
      };

      nginx-probes = {
        enabled = true;

        settings = {
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
    failregex = ^<HOST> - .* "(GET|POST|HEAD) /(?:(?:wp-admin|wp-content|wp-includes|wordpress|\.git|\.svn|\.hg|\.bzr|phpmyadmin|phpMyAdmin|pma|cgi-bin|vendor/phpunit|(?:public/)?vendor/laravel-filemanager|\.aws|\.docker|\.ssh)(?=[/ ?]|$)|(?:wp-login\.php|xmlrpc\.php|adminer(?:\.php)?|docker-compose(?:\.ya?ml)?|Dockerfile|id_rsa|config\.php|configuration\.php|(?:db|database|dump|backup)\.(?:sql|sqlite|sqlite3|bak|old|zip|tar|gz)|(?:env-config|runtime-config|aws-exports|app\.config|config/config|env)\.js)(?=[ ?]|$)|\.env(?:\.[^ ?/]*)?(?=[/? ]|$)|backup(?=[/._\- ?]|$)).* HTTP/.*" (?:400|401|403|404|405|444) .*
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
    '')
  ];
}
