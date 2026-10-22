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
  homelab.hardenedServices = [ "garage-webui" ];

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

    serviceConfig = lib.hardenedService // {
      ExecStart = "${pkgs.garage-webui}/bin/garage-webui";

      EnvironmentFile = config.sops.templates."garage-webui.env".path;

      Restart = "on-failure";
      RestartSec = 5;

      # Identity
      DynamicUser = true;
      SupplementaryGroups = [
        "garage-webui-secrets"
        "garage-secrets"
      ];

      # Network: admin API + S3 API are both on localhost only.
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
