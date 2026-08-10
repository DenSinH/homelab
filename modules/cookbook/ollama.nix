# CPU-only local LLM stack exposing a REAL OpenAI Responses API endpoint,
# for use with `client.responses.parse(...)`.
{ config, pkgs, ... }:

let
  cfg = import ./common.nix;

  # litellm's proxy extras (e.g. "backoff") aren't pulled in by the plain
  # nixpkgs derivation, so build a python env that includes them.
  litellmEnv = pkgs.python3.withPackages (
    ps: [ ps.litellm ] ++ ps.litellm.optional-dependencies.proxy
  );

  litellmConfig = pkgs.writeText "litellm-config.yaml" ''
    model_list:
      - model_name: ${cfg.model}
        litellm_params:
          model: ollama/${cfg.model}
          api_base: http://127.0.0.1:11434
          think: false

    litellm_settings:
      drop_params: true

    general_settings:
      master_key: sk-local-dev
  '';
in
{
  # Local model runtime
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    package = pkgs.ollama-cpu;

    # manually pull models to ensure they are available on first request
    # (to avoid timeouts)
    loadModels = [ ];
  };

  systemd.services.ollama-model = {
    description = "Download Ollama models";
    wantedBy = [ "multi-user.target" ];
    after = [ "ollama.service" ];
    requires = [ "ollama.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      echo "Waiting for Ollama..."
      until ${pkgs.curl}/bin/curl -sf \
        http://127.0.0.1:11434/api/tags >/dev/null
      do
        sleep 1
      done

      echo "Ensuring ${cfg.model} is installed..."
      ${pkgs.curl}/bin/curl -f \
        http://127.0.0.1:11434/api/pull \
        -H 'Content-Type: application/json' \
        -d '{"name":"${cfg.model}","stream":false}'

      echo "${cfg.model} is ready."
    '';
  };

  # litellm proxy: adds a real /v1/responses
  systemd.services.litellm-proxy = {
    description = "litellm proxy (OpenAI Responses API front for Ollama)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "ollama-model.service"
    ];

    requires = [
      "ollama-model.service"
    ];

    serviceConfig = {
      ExecStart = "${litellmEnv}/bin/litellm --config ${litellmConfig} --port ${builtins.toString cfg.litellm-port} --host 0.0.0.0";
      Restart = "on-failure";
      DynamicUser = true;
    };
  };

  # open this for testing
  # networking.firewall.allowedTCPPorts = [ cfg.litellm-port ];
}
