{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./cookbook.nix
    ./ollama.nix
  ];
}
