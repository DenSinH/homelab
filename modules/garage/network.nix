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
in
{
  homelab.selfSignedCerts.garage = {
    hostName = "garage.home";
    extraSANs = [ "DNS:cdn.dennishilhorst.nl" ];
  };

  # Reverse proxy / firewall config for the garage instance
  services.nginx = {
    enable = true;

    virtualHosts.default = {
      # explicit, so this stays the fallback for any Host header on 80/443
      # even if another vhost is ever added to this LXC.
      default = true;
      forceSSL = true;
      sslCertificate = config.homelab.selfSignedCerts.garage.certFile;
      sslCertificateKey = config.homelab.selfSignedCerts.garage.keyFile;

      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
          ssl = false;
        }
        {
          addr = "0.0.0.0";
          port = 443;
          ssl = true;
        }
      ];

      serverAliases = [
        "garage.home"
      ];

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
  };

  networking.nftables.enable = true;
  networking.firewall = {
    allowedTCPPorts = [
      80 # Public HTTP access to nginx
      443
    ];

    # Garage S3 API: only reachable by cookbook LXC
    extraInputRules = ''
      ip saddr ${lib.lxcs.cookbook.ip} tcp dport ${builtins.toString cfg.s3_api_bind_port} accept
    '';
  };
}
