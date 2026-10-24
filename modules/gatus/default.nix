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

  # No TLS: a read-only status page, fine over plain HTTP on the LAN (the
  # public status.dennishilhorst.nl domain is already TLS end-to-end via
  # Cloudflare - see modules/cloudflared).
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
