{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./service.nix
    ./provision.nix
    ./network.nix
    ./webui.nix
  ];
}
