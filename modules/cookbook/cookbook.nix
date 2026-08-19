{
  config,
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
    hash = "sha256-twZKUKIdnTGfrPMCCMnpB/FsTE7xV0/2T7a8J7HHZ5Q=";
  };

  # for testing (needs --impure in the deploy script)
  # cookbookSrc = /home/dennis/projects/master-chef;

  # should be compatible with master-chef/pyproject.toml:requires-python
  python = pkgs.python314;

  port = 8000;
in
{
  imports = [
    ../fail2ban.nix
  ];

  sops.defaultSopsFile = ../../secrets/cookbook.yaml;
  sops.secrets = {
    # S3 secrets (shared with garage)
    "cookbook/masterchef-access-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/masterchef-secret-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
      group = "cookbook";
      mode = "0440";
    };

    "cookbook/github_pat" = {
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/openai_api_key" = {
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/secret" = {
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/instagram_user" = {
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/instagram_pass" = {
      group = "cookbook";
      mode = "0440";
    };
    "cookbook/admin_user" = {
      group = "cookbook";
      mode = "0440";
    };
  };

  sops.templates."cookbook-s3.env" = {
    group = "cookbook";
    content = ''
      S3_ENDPOINT=http://${lib.lxcs.garage.ip}:3900
      S3_ACCESS_KEY=${config.sops.placeholder."cookbook/masterchef-access-key"}
      S3_SECRET_KEY=${config.sops.placeholder."cookbook/masterchef-secret-key"}
      S3_BUCKET=cookbook
      S3_PUBLIC_URL=https://cdn.dennishilhorst.nl/
      S3_REGION=garage
    '';
  };

  sops.templates."cookbook.env" = {
    group = "cookbook";
    content = ''
      RECIPE_PAT=${config.sops.placeholder."cookbook/github_pat"}
      OPENAI_API_KEY=${config.sops.placeholder."cookbook/openai_api_key"}
      SECRET=${config.sops.placeholder."cookbook/secret"}
      INSTAGRAM_USER=${config.sops.placeholder."cookbook/instagram_user"}
      INSTAGRAM_PASS=${config.sops.placeholder."cookbook/instagram_pass"}
      ADMIN_USER=${config.sops.placeholder."cookbook/admin_user"}
    '';
  };

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

      EnvironmentFile = [
        config.sops.templates."cookbook-s3.env".path
        config.sops.templates."cookbook.env".path
      ];
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
        "RECIPE_REPO_USER=DenSinH"
        "RECIPE_REPO_NAME=master-chef-recipes"
        "PORT=${builtins.toString port}"
      ];

      # sync has been done in preStart
      ExecStart = "${pkgs.uv}/bin/uv run --no-sync master-chef";

      Restart = "on-failure";
      RestartSec = 5;
    };

    preStart = ''
      ${pkgs.uv}/bin/uv sync --no-dev --frozen --no-progress
    '';
  };

  services.nginx = {
    enable = true;

    virtualHosts.default = {
      locations."/" = {
        proxyPass = "http://127.0.0.1:${builtins.toString port}";
        proxyWebsockets = true;

        # needed to make fastapi render properly
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };
  };

  # open firewall for cookbook service
  networking.firewall = {
    allowedTCPPorts = [
      80
    ];
  };
}
