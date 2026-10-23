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

  homelab.selfSignedCerts.garage-webui.hostName = "garage-admin.home";

  # garage-webui itself binds 0.0.0.0:3909 with no TLS of its own (nginx
  # proxies to it below, so 3909/3911 here are nginx's OWN external ports -
  # deliberately NOT 80/443, which the main garage.home/cdn vhost in
  # network.nix owns) so this admin dashboard can never end up served as the
  # fallback vhost for cloudflared's cdn.dennishilhorst.nl traffic - it's
  # LAN-only and must stay that way.
  services.nginx.virtualHosts."garage-admin.home" = {
    listen = [
      {
        addr = "0.0.0.0";
        port = 3908;
        ssl = false;
      }
      {
        addr = "0.0.0.0";
        port = 3911;
        ssl = true;
      }
    ];
    sslCertificate = config.homelab.selfSignedCerts.garage-webui.certFile;
    sslCertificateKey = config.homelab.selfSignedCerts.garage-webui.keyFile;

    # forceSSL's automatic redirect assumes the default 443 port, which is
    # wrong here (we're on 3911) - redirect manually instead.
    locations."/" = {
      proxyPass = "http://127.0.0.1:3909";
      proxyWebsockets = true;
    };
    extraConfig = ''
      if ($scheme = http) {
        return 301 https://$host:3911$request_uri;
      }
    '';
  };

  # LAN-only dashboard: separate ports from the public garage.home/cdn vhost.
  networking.firewall.allowedTCPPorts = [
    3908
    3911
  ];

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
