{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = import ./common.nix { inherit pkgs; };

  garageData = "/var/lib/garage";
in
{
  sops.defaultSopsFile = ../../secrets/garage.yaml;
  sops.secrets = {
    "garage/rpc-secret" = { };
    "garage/admin-token" = { };
  };

  sops.templates."garage.env".content = ''
    GARAGE_RPC_SECRET=${config.sops.placeholder."garage/rpc-secret"}
    GARAGE_ADMIN_TOKEN=${config.sops.placeholder."garage/admin-token"}
  '';

  services.garage = {
    enable = true;

    package = cfg.garagePackage;
    environmentFile = config.sops.templates."garage.env".path;

    settings = {
      metadata_dir = "${garageData}/meta";
      data_dir = "${garageData}/data";

      db_engine = "lmdb";

      # This is intentionally a single-node Garage deployment.
      replication_factor = 1;

      # Nothing else needs to talk Garage RPC remotely.
      rpc_bind_addr = "127.0.0.1:${builtins.toString cfg.s3_rpc_bind_port}";

      admin = {
        api_bind_addr = "127.0.0.1:${builtins.toString cfg.s3_admin_bind_port}";
      };

      s3_api = {
        s3_region = cfg.s3_region;

        # S3 API, restricted access to only the cookbook
        # (see firewall below)
        api_bind_addr = "0.0.0.0:${builtins.toString cfg.s3_api_bind_port}";
      };

      s3_web = {
        # nginx is the only thing that needs to talk to the web gateway.
        bind_addr = "127.0.0.1:${builtins.toString cfg.s3_web_bind_port}";

        # Garage's web gateway chooses the bucket based on Host:
        #
        #   cookbook.web.garage.internal
        #
        # We manufacture that Host header in nginx.
        root_domain = ".${cfg.garageWebDomain}";
      };
    };
  };

  # Override ExecStart to use --single-node mode
  systemd.services.garage.serviceConfig.ExecStart =
    lib.mkForce "${cfg.garagePackage}/bin/garage server --single-node";
}
