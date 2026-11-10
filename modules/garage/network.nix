{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = import ./common.nix { inherit pkgs; };

  publicBuckets = [
    "cookbook"
  ];

  adminNames = lib.filter (lib.hasPrefix "garage-admin.") config.homelab.https.domains;
  bucketNames = lib.subtractLists adminNames config.homelab.https.domains;
in
{
  homelab.https = {
    enable = true;
    tunnel = true;
  };

  # Reverse proxy / firewall config for the garage instance
  services.nginx = {
    enable = true;

    # Public buckets: cdn. via the tunnel, garage.* over HTTPS. Default, so stray names never reach the admin UI.
    virtualHosts.default = config.homelab.https.tunnelVhost // {
      default = true;
      serverAliases = bucketNames;

      locations."/" = {
        extraConfig = ''
          # /<bucket>/<object>
          if ($uri !~ ^/([^/]+)(/.*)$) {
            return 404;
          }

          set $garage_bucket $1;
          set $garage_object $2;

          # Only expose explicitly whitelisted buckets.
          if ($garage_bucket !~ ^(?:${lib.concatStringsSep "|" publicBuckets})$) {
            return 404;
          }

          proxy_set_header Host "$garage_bucket.${cfg.garageWebDomain}";
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

          rewrite ^/[^/]+/(.*)$ /$1 break;

          proxy_pass http://127.0.0.1:${builtins.toString cfg.s3_web_bind_port};
          proxy_buffering off;

          # only allow GET and HEAD requests to retrieve data from garage
          # through the web
          limit_except GET HEAD {
              deny all;
          }
        '';
      };
    };

    virtualHosts.${lib.head adminNames} = config.homelab.https.vhost // {
      serverAliases = lib.tail adminNames;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3909";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };
  };

  networking.nftables.enable = true;
  networking.firewall = {
    # Garage S3 API: only reachable by cookbook LXC
    extraInputRules = ''
      ip saddr ${lib.lxcs.cookbook.ip} tcp dport ${builtins.toString cfg.s3_api_bind_port} accept
    '';
  };
}
