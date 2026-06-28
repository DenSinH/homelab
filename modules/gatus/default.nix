{
  config,
  pkgs,
  lib,
  ...
}:

{
  # allow binding port 80
  systemd.services.gatus.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
  };

  services.gatus = {
    enable = true;
    openFirewall = true;

    # web.port is configured in configFile
    configFile = ./config.yaml;
  };

  networking.firewall.allowedTCPPorts = [
    80
  ];
}
