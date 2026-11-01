{
  config,
  pkgs,
  lib,
  ...
}:

{
  # garage is a known LAN IP; the rest of the LAN stays blocked.
  homelab.egress = {
    enable = true;
    allowed = [
      {
        host = lib.lxcs.garage.ip;
        ports = [ 3900 ];
        protos = [ "tcp" ];
        comment = "S3 to garage";
      }
    ];
  };
  homelab.ingress.enable = true;

  imports = [
    ./cookbook.nix
    # TODO: try to get some local AI model to work well enough to run
    #       locally and ditch OpenAI
    # ./ollama.nix
    # ../igpu.nix
  ];
}
