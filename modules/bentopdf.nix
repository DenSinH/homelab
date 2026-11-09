{
  config,
  pkgs,
  lib,
  ...
}:

{
  homelab.egress.enable = true;
  homelab.ingress.enable = true;

  services.bentopdf = {
    enable = true;
    domain = config.homelab.https.domain;

    nginx.enable = true;
    nginx.virtualHost = config.homelab.https.vhost // {
      serverAliases = config.homelab.https.vhost.serverAliases ++ [ "bentopdf.home" ];
    };
  };

  # open firewall to nginx
  networking.firewall = {
    allowedTCPPorts = [ 80 ];
  };
}
