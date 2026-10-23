{ pkgs, ... }:

{
  services.gatus = {
    enable = true;
    openFirewall = false;

    configFile = ./config.yaml;
  };

  # reduce logging of every single check
  systemd.services.gatus.serviceConfig = {
    LogLevelMax = "notice";
  };

  homelab.selfSignedCerts.gatus = {
    hostName = "gatus.home";
    extraSANs = [
      "DNS:status.home"
      "DNS:status.dennishilhorst.nl"
    ];
    vhosts = [ "default" ];
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
    443
  ];
}
