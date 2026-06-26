{
  config,
  pkgs,
  lib,
  ...
}:

let
  proxies = {
    "link.dennishilhorst.nl" = {};
    "status.dennishilhorst.nl" = {};
    "blog.dennishilhorst.nl" = {};
    "cdn-console.dennishilhorst.nl" = {
      originRequest = {
        httpHostHeader = "cdn.console.dennishilhorst.nl";
        originServerName = "cdn.console.dennishilhorst.nl";
      };
    };
    "cdn.dennishilhorst.nl" = {};
    "chef.dennishilhorst.nl" = {};
    "hunt.dennishilhorst.nl" = {};
    "link-console.dennishilhorst.nl" = {
      originRequest = {
        httpHostHeader = "link.console.dennishilhorst.nl";
        originServerName = "link.console.dennishilhorst.nl";
      };
    };
    "nng.dennishilhorst.nl" = {};
    "pgadmin.dennishilhorst.nl" = {};
    "portainer.dennishilhorst.nl" = {};
    "traefik.dennishilhorst.nl" = {};
  };
in
  {
    # https://search.nixos.org/options?channel=26.05&query=cloudflared
    # For initialization:
    # https://wiki.nixos.org/wiki/Cloudflared
    # on the LXC, run
    #   nix-shell -p cloudflared
    # and then
    #   cloudflared tunnel login
    #   cloudflared tunnel create <tunnel-name-of-choice>
    # the credits file is created by default in
    #   ~/.cloudflared/<tunnel-id>.json
    #
    # These last 2 steps do NOT need to be done when setting up on a new host
    # though I have not copied over the cert.pem file
    sops.secrets = {
      # influxdb2 service runs as user `influxdb2` in group `influxdb2
      "cloudflared/tunnel-creds" = {
        # group = "cloudflared";
        mode = "0440";
      };
    };

    services.cloudflared = {
      enable = true;

      # 'dennishilhorst' tunnel
      tunnels."2520e8d8-cf93-4acf-a433-a3706133195f" = {
        credentialsFile = "${config.sops.secrets."cloudflared/tunnel-creds".path}";

        originRequest = {
          noTLSVerify = true;
        };

        ingress =
          lib.mapAttrs
            (host: proxy:
              {
                service = "https://192.168.50.30:443";

                # copy over request headers for traefik
                originRequest = {
                  httpHostHeader = host;
                  originServerName = host;
                };
              }
              // proxy
            )
            proxies;

        default = "http_status:404";
      };
    };
  }
