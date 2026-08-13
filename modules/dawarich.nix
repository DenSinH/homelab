{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.dawarich = {
    enable = true;
    localDomain = "dawarich.home";

    # expose over VPN hostname as well
    environment = {
      APPLICATION_HOSTS = "127.0.0.1,::1,dawarich.home,dawarich.vpn";
    };
  };

  # expose on vpn as well
  services.nginx.virtualHosts."dawarich.home" = {
    serverAliases = [
      "dawarich.vpn"
    ];
  };

  # open firewall to nginx
  networking.firewall = {
    allowedTCPPorts = [ 80 ];
  };
}
