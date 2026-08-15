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

  sops.secrets = {
    "garage/webui-user-pass" = { };
  };

  sops.templates."garage-webui.env".content = ''
    API_BASE_URL=http://127.0.0.1:${builtins.toString cfg.s3_admin_bind_port}
    API_ADMIN_KEY=${config.sops.placeholder."garage/admin-token"}
    S3_ENDPOINT_URL=http://127.0.0.1:${builtins.toString cfg.s3_api_bind_port}
    S3_REGION=${cfg.s3_region}
    AUTH_USER_PASS=${config.sops.placeholder."garage/webui-user-pass"}
  '';

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

      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
