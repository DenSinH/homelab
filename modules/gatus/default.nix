{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Monitors other LAN devices by design, so needs allowLan.
  homelab.egress = {
    enable = true;
    allowLan = true;
  };
  homelab.ingress.enable = true;

  services.gatus = {
    enable = true;
    openFirewall = false;

    configFile = ./config.yaml;
  };

  # reduce logging of every single check
  systemd.services.gatus.serviceConfig = {
    LogLevelMax = "notice";
  };

  homelab.https = {
    enable = true;
    tunnel = true;
  };

  services.nginx = {
    enable = true;

    virtualHosts.default = config.homelab.https.tunnelVhost // {
      serverAliases = config.homelab.https.domains;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };
}
