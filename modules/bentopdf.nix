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
    domain = "bentopdf.home";

    nginx.enable = true;
  };

  # open firewall to nginx
  networking.firewall = {
    allowedTCPPorts = [ 80 ];
  };
}
