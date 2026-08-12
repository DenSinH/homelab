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

  # no master_key as the service is behind the firewall anyway
  litellmConfig = pkgs.writeText "litellm-config.yaml" ''
    model_list:
      - model_name: ${cfg.model}
        litellm_params:
          model: ollama/${cfg.model}
          api_base: http://127.0.0.1:11434
          think: false
          max_tokens: 4096

    litellm_settings:
      drop_params: true
  '';
in
{
  # Local model runtime
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    package = pkgs.ollama;

    user = "ollama";

    environmentVariables = {
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_CONTEXT_LENGTH = "4096";
      OLLAMA_MAX_LOADED_MODELS = "1";
      # Release the model from RAM 1 minute after the last request,
      # instead of the 5-minute default, since Jellyfin/Immich may
      # want that memory back in between conversions.
      OLLAMA_KEEP_ALIVE = "1m";
      # Can speed up context/attention processing on CPU too, not just GPU.
      # Benchmark before/after - not guaranteed on every model architecture.
      OLLAMA_FLASH_ATTENTION = "1";
      # Quantizes the KV cache, reducing memory-bandwidth cost during
      # attention. This box is confirmed bandwidth-bound, so this is a
      # more plausible win here than on a compute-bound GPU setup.
      OLLAMA_KV_CACHE_TYPE = "q8_0";
    };

    # manually pull models to ensure they are available on first request
    # (to avoid timeouts)
    loadModels = [ ];
  };

  # Ollama's systemd service needs access to /dev/dri
  users.users.ollama.extraGroups = [
    "video"
    "render"
  ];

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

  # inject dependencies into cookbook service
  systemd.services.cookbook = {
    # needs LLM to be loaded and available
    after = [
      "litellm-proxy.service"
    ];

    requires = [
      "litellm-proxy.service"
    ];
  }

  # open this for testing
  # networking.firewall.allowedTCPPorts = [ cfg.litellm-port ];
}
