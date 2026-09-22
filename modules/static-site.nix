{ config, pkgs, ... }:

{
  services.nginx = {
    enable = true;

    virtualHosts."_" = {
      default = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
        {
          addr = "[::]";
          port = 80;
        }
      ];

      root = "/var/lib/static-site";

      locations."/" = {
        tryFiles = "$uri $uri/ =404";
      };
    };
  };

  # Create the mutable directory on boot
  systemd.tmpfiles.rules = [
    "d /var/lib/static-site 0755 nginx nginx -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
