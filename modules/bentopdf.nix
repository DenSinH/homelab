{
  config,
  pkgs,
  lib,
  ...
}:

{
  homelab.egress.enable = true;
  homelab.ingress.enable = true;
  homelab.https.enable = true;

  services.bentopdf = {
    enable = true;
    domain = config.homelab.https.domain;

    nginx.enable = true;
    nginx.virtualHost = config.homelab.https.vhost;
  };
}
