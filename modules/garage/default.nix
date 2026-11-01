{
  config,
  pkgs,
  lib,
  ...
}:

{
  homelab.egress.enable = true;

  # S3 API is reached by cookbook (services range) directly, besides
  # cloudflared (net range, already trusted by default).
  homelab.ingress = {
    enable = true;
    allowed = [
      {
        host = lib.lxcs.cookbook.ip;
        comment = "cookbook S3 access";
      }
    ];
  };

  imports = [
    ./service.nix
    ./provision.nix
    ./network.nix
    ./webui.nix
  ];
}
