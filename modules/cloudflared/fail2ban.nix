{ pkgs, lib, ... }:

let
  # Every probe pattern is wrapped as <pre><body><post>, matched directly
  # against Caddy's default JSON access log line (read straight from the
  # journal below - no second logger/log format needed).
  pre = ''"client_ip":"<HOST>".*"method":"[A-Z]+".*"uri":"/'';
  post = ''[^"]*".*"status":(?:400|401|403|404|405|444)'';

  probeBodies = [
    # --- well-known scanner directories, only at the site root ---
    "(?:wp-admin|wp-content(?!/uploads/)|wp-includes|wordpress|phpmyadmin|phpMyAdmin|pma|myadmin|mysql|cgi-bin|vendor|actuator|icecoder|langflow|boaform|HNAP1|manager/html|jenkins|solr|_ignition|_profiler|telescope|server-status|server-info|owa|ecp|autodiscover|aspnet_client)(?=[/\"? ])"

    # --- dotfiles and dot-directories, at any depth (/.git/config, /api/.env, /a/b/.aws/credentials) ---
    ''(?:[^ ?"]*/)?(?:\.git|\.svn|\.hg|\.bzr|\.aws|\.docker|\.ssh|\.kube|\.vscode|\.idea|\.npm|\.config|\.bash_history|\.bashrc|\.profile|\.zsh_history|\.mysql_history|\.DS_Store|\.htaccess|\.htpasswd|\.gitignore|\.gitlab-ci\.yml|\.travis\.yml|\.dockerignore|\.npmrc|\.pypirc|\.netrc|\.s3cfg)(?=[/"? ])''
    ''(?:[^ ?"]*/)?\.env(?:[._-][^ ?/"]*)?(?=[/"? ])''

    # --- sensitive files, at any depth ---
    ''(?:[^ ?"]*/)?(?:wp-login\.php|xmlrpc\.php|adminer(?:\.php)?|phpinfo\.php|info\.php|eval-stdin\.php|wp-config\.php[^ ?"]*|docker-compose(?:[.-][a-z.]+)?\.ya?ml|Dockerfile|id_rsa|id_ed25519|id_dsa|authorized_keys|known_hosts|credentials\.json|secrets?\.(?:json|ya?ml|txt)|web\.config|composer\.(?:json|lock)|package(?:-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile(?:\.lock)?|requirements\.txt|terraform\.tfstate|serviceAccountKey\.json|appsettings(?:\.[A-Za-z]+)?\.json|parameters\.ya?ml|local_settings\.py|settings\.py|configuration\.php|config\.(?:php|inc\.php|bak|old|ini|ya?ml)|(?:db|database|dump|backup|backups|site|www|public_html|html|web|wwwroot)\.(?:sql|sqlite3?|bak|old|zip|tar|tar\.gz|tgz|gz|rar|7z))(?=["? ])''

    # --- generic server-side scripts a static blog / Nix service never serves (index.php is left alone: old WordPress URLs) ---
    ''(?:[^ ?"]*/)?(?!index\.php["? ])[^ ?"/]+\.php(?=["? ])''
    ''(?:[^ ?"]*/)?[^ ?"/]+\.(?:asp|aspx|ashx|jsp|jspx|cgi|cfm|action|do)(?=["? ])''

    # --- JS config / bundle guessing (seen in your logs from 34.140.234.80), site root only ---
    ''(?:config|index|app|main|bundle|settings|constants|env|env-config|runtime-config|aws-exports|app\.config)\.js(?=["? ])''
    ''config/config\.js(?=["? ])''

    # --- app-specific exploit endpoints (seen in your logs from 136.110.28.221) ---
    "(?:(?:api|v1|v2)/)*graphql(?=[/\"? ])"
    "(?:langflow/)?api/v1/(?:validate/code|build_public_tmp|node-custom-function|node-load-method)(?=[/\"? ])"

    # --- path traversal / injection strings anywhere in the request ---
    # (a literal % must be written %% in fail2ban config files)
    ''[^"]*(?:\.\.(?:/|%%2[fF]|%%5[cC])|%%2[eE]%%2[eE](?:/|%%2[fF]|%%5[cC])|%%252[eE]|/etc/passwd|/proc/self|php://|data://|expect://|\$\{jndi:|%%24%%7[bB]jndi|[uU][nN][iI][oO][nN](?:\+|%%20| )[sS][eE][lL][eE][cC][tT]|<script|%%3[cC]script|base64_decode|allow_url_include|/bin/(?:ba)?sh)''
  ];

  probeRegexes = lib.concatMapStringsSep "\n    " (body: "${pre}${body}${post}") probeBodies;
in
{
  # Bans feed straight into CrowdSec's decision engine (already enforced by
  # the `crowdsec` directive on every Caddy vhost), so a ban from any jail
  # here or from CrowdSec's own scenarios is immediately shared everywhere.
  environment.etc."fail2ban/action.d/cscli-ban.conf".text = ''
    [Definition]
    actionstart =
    actionstop =
    actioncheck =
    actionban = /run/current-system/sw/bin/cscli decisions add -i <ip> -d <bantime>s -r "fail2ban/<name>"
    actionunban = /run/current-system/sw/bin/cscli decisions delete -i <ip>

    [Init]
    name = default
  '';

  services.fail2ban = {
    enable = true;

    banaction = "cscli-ban";
    banaction-allports = "cscli-ban";

    ignoreIP = [
      "127.0.0.1/8"
      "::1"
      "192.168.50.0/24" # LAN
      "100.64.0.0/10" # VPN
    ];

    jails = {
      # known scanner paths: see probeBodies above
      caddy-probes = {
        enabled = true;
        settings = {
          backend = "systemd";
          filter = "caddy-probes";
          journalmatch = "_SYSTEMD_UNIT=caddy.service";

          maxretry = 3;
          findtime = "10m";
          bantime = "24h";
        };
      };

      # POST that ends in an error. None of the proxied vhosts have
      # legitimate error-returning POSTs today; revisit if one grows some.
      caddy-post-probe = {
        enabled = true;
        settings = {
          backend = "systemd";
          filter = "caddy-post-probe";
          journalmatch = "_SYSTEMD_UNIT=caddy.service";

          maxretry = 3;
          findtime = "10m";
          bantime = "24h";
        };
      };

      caddy-404 = {
        enabled = true;
        settings = {
          backend = "systemd";
          filter = "caddy-404";
          journalmatch = "_SYSTEMD_UNIT=caddy.service";

          # actual scan bursts observed are ~10 requests/second
          maxretry = 20;
          findtime = "10m";
          bantime = "1h";
        };
      };

      recidive = {
        enabled = true;
        settings = {
          # fail2ban's own logtarget defaults to SYSLOG on NixOS, so
          # /var/log/fail2ban.log is never actually written; read its own
          # ban notices from the journal instead.
          backend = "systemd";
          journalmatch = "_SYSTEMD_UNIT=fail2ban.service";

          findtime = "1d";
          maxretry = 5;
          bantime = "1w";
        };
      };
    };
  };

  environment.etc."fail2ban/filter.d/caddy-probes.conf".text = ''
    [Definition]
    failregex = ${probeRegexes}
    ignoreregex =
  '';

  environment.etc."fail2ban/filter.d/caddy-post-probe.conf".text = ''
    [Definition]
    failregex = "client_ip":"<HOST>".*"method":"POST".*"status":(?:400|401|403|404|405|444)
    ignoreregex =
  '';

  environment.etc."fail2ban/filter.d/caddy-404.conf".text = ''
    [Definition]
    failregex = "client_ip":"<HOST>".*"method":"(?:GET|POST|HEAD)".*"status":404
    # missing media/assets are normal (old blog images, favicon, crawlers)
    ignoreregex = "client_ip":"<HOST>".*"method":"(?:GET|HEAD)".*"uri":"[^"]*\.(?:jpe?g|png|gif|webp|avif|svg|ico|css|map|woff2?|ttf|txt|xml)(?:\?[^"]*)?".*"status":404
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
      echo "=== CrowdSec decisions (incl. fail2ban bans) ==="
      sudo cscli decisions list
    '')
  ];
}
