{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../fail2ban.nix
  ];

  services.gatus = {
    enable = true;
    openFirewall = false;

    configFile = ./config.yaml;
  };

  services.nginx = {
    enable = true;

    virtualHosts.default = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
  ];
}
