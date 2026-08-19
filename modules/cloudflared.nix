{
  config,
  pkgs,
  lib,
  ...
}:

let
  proxies = {
    "status.dennishilhorst.nl" = {
      service = "http://${lib.lxcs.gatus.ip}";
    };
    "blog.dennishilhorst.nl" = {
      service = "http://${lib.lxcs.blog.ip}";
    };
    "cdn.dennishilhorst.nl" = {
      service = "http://${lib.lxcs.garage.ip}";
    };
    "chef.dennishilhorst.nl" = {
      service = "http://${lib.lxcs.cookbook.ip}";
    };
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
  sops.defaultSopsFile = ../secrets/cloudflared.yaml;
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

      ingress = lib.mapAttrs (
        host: proxy:
        {
          # copy over request headers by default
          originRequest = {
            httpHostHeader = host;
            originServerName = host;
          };
        }
        // proxy
      ) proxies;

      default = "http_status:404";
    };
  };
}
