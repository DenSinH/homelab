{
  pkgs,
  lib,
  ...
}:

let
  cfg = import ./common.nix;

  cookbookSrc = pkgs.fetchFromGitHub {
    owner = "DenSinH";
    repo = "master-chef";
    rev = "refs/heads/master";
    hash = "sha256-5MO5yL5qPKQQMzMIfZl1h6JVV6YK5Y7kQHHJgdm9f2c=";
  };

  # for testing
  # cookbookSrc = /home/dennis/projects/master-chef;

  # should be compatible with master-chef/pyproject.toml:requires-python
  python = pkgs.python314;
in
{
  users.users.cookbook = {
    isSystemUser = true;
    group = "cookbook";
  };

  users.groups.cookbook = { };

  systemd.services.cookbook = {
    description = "Cookbook webapp";
    wantedBy = [ "multi-user.target" ];

    # other dependencies are included if ./ollama.nix is included
    after = [
      "network.target"
    ];

    serviceConfig = {
      User = "cookbook";
      Group = "cookbook";

      StateDirectory = "cookbook";
      WorkingDirectory = "${cookbookSrc}";

      # manually provisioned
      EnvironmentFile = "/var/lib/cookbook/.env";
      Environment = [
        "HOME=/var/lib/cookbook"
        # put uv cache and venv in StateDir
        "UV_CACHE_DIR=/var/lib/cookbook/.cache/uv"
        "UV_PROJECT_ENVIRONMENT=/var/lib/cookbook/.venv"
        "UV_PYTHON=${python}/bin/python"
        "OPENAI_MODEL=${cfg.model}"
        "TEMPERATURE=${builtins.toString cfg.temperature}"
        # enable to enable local AI model with ollama
        # (requires ./ollama.nix to be included)
        # "OPENAI_URL=http://127.0.0.1:${builtins.toString cfg.litellm-port}"
      ];

      # bind port 80
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];

      # sync has been done in preStart
      ExecStart = "${pkgs.uv}/bin/uv run --no-sync master-chef";

      Restart = "on-failure";
      RestartSec = 5;
    };

    preStart = ''
      ${pkgs.uv}/bin/uv sync --no-dev --frozen --no-progress
    '';
  };

  # open firewall for cookbook service
  networking.firewall = {
    allowedTCPPorts = [
      80
    ];
  };
}
