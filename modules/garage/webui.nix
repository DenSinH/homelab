{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = import ./common.nix { inherit pkgs; };
in
{
  # this insecure package is used for the webui package
  nixpkgs.config.permittedInsecurePackages = [
    "pnpm-9.15.9"
  ];

  users.groups.garage-webui-secrets = { };
  sops.secrets = {
    "garage/webui-user-pass" = {
      group = "garage-webui-secrets";
      mode = "0440";
    };
  };

  sops.templates."garage-webui.env" = {
    content = ''
      API_BASE_URL=http://127.0.0.1:${builtins.toString cfg.s3_admin_bind_port}
      API_ADMIN_KEY=${config.sops.placeholder."garage/admin-token"}
      S3_ENDPOINT_URL=http://127.0.0.1:${builtins.toString cfg.s3_api_bind_port}
      S3_REGION=${cfg.s3_region}
      AUTH_USER_PASS=${config.sops.placeholder."garage/webui-user-pass"}
    '';
    group = "garage-webui-secrets";
    mode = "0440";
  };

  systemd.services.garage-webui = {
    description = "Garage Web UI";
    wantedBy = [ "multi-user.target" ];

    after = [ "garage.service" ];
    requires = [ "garage.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.garage-webui}/bin/garage-webui";

      EnvironmentFile = config.sops.templates."garage-webui.env".path;

      Restart = "on-failure";
      RestartSec = 5;

      # Identity / privilege
      DynamicUser = true;
      SupplementaryGroups = [
        "garage-webui-secrets"
        "garage-secrets"
      ];
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";

      # Filesystem
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;

      # Kernel / host isolation
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectHostname = true;

      LockPersonality = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;

      SystemCallArchitectures = "native";

      # No useful reason for this process to dump its memory.
      LimitCORE = 0;

      # Network
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];

      IPAddressDeny = "any";
      IPAddressAllow = [
        "127.0.0.1"
        "::1"
      ];
    };
  };
}
