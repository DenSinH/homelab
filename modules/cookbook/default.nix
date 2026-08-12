{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./cookbook.nix
    # TODO: try to get some local AI model to work well enough to run
    #       locally and ditch OpenAI
    # ./ollama.nix
    # ../igpu.nix
  ];
}
