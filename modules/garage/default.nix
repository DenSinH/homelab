{
  config,
  pkgs,
  lib,
  ...
}:

let
  garageData = "/var/lib/garage";
  garagePackage = pkgs.garage_2;

  # Internal hostname suffix used by Garage's web gateway.
  #
  # It does NOT need to exist in DNS. nginx connects to Garage on
  # localhost and supplies this Host header.
  garageWebDomain = "web.garage.internal";
in
{
  sops.defaultSopsFile = ../../secrets/garage.yaml;
  sops.secrets = {
    "garage/rpc-secret" = { };
    "cookbook/masterchef-access-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
    };
    "cookbook/masterchef-secret-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
    };
  };

  sops.templates."garage.env".content = ''
    GARAGE_RPC_SECRET=${config.sops.placeholder."garage/rpc-secret"}
  '';

  services.garage = {
    enable = true;

    # Default currently, but to ensure this never accidentally breaks
    # with some nix flake update
    package = garagePackage;
    environmentFile = config.sops.templates."garage.env".path;

    settings = {
      metadata_dir = "${garageData}/meta";
      data_dir = "${garageData}/data";

      db_engine = "lmdb";

      # This is intentionally a single-node Garage deployment.
      replication_factor = 1;

      # Nothing else needs to talk Garage RPC remotely.
      rpc_bind_addr = "127.0.0.1:3901";

      s3_api = {
        s3_region = "garage";

        # S3 API, restricted access to only the cookbook
        # (see firewall below)
        api_bind_addr = "0.0.0.0:3900";
      };

      s3_web = {
        # nginx is the only thing that needs to talk to the web gateway.
        bind_addr = "127.0.0.1:3902";

        # Garage's web gateway chooses the bucket based on Host:
        #
        #   cookbook.web.garage.internal
        #
        # We manufacture that Host header in nginx.
        root_domain = ".${garageWebDomain}";
      };
    };
  };

  # Override ExecStart to use --single-node mode
  systemd.services.garage.serviceConfig.ExecStart =
    lib.mkForce "${garagePackage}/bin/garage server --single-node";

  # Credentials for cookbook bucket
  sops.templates."garage-masterchef.env" = {
    content = ''
      COOKBOOK_CREDENTIALS_ACCESS_KEY=${config.sops.placeholder."cookbook/masterchef-access-key"}
      COOKBOOK_CREDENTIALS_SECRET_KEY=${config.sops.placeholder."cookbook/masterchef-secret-key"}
    '';
  };

  # Configure the public website endpoint after Garage is running.
  systemd.services.garage-cookbook-provision = {
    description = "Configure Garage cookbook bucket";

    wantedBy = [ "multi-user.target" ];

    after = [ "garage.service" ];
    requires = [ "garage.service" ];

    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = [
        config.sops.templates."garage.env".path
        config.sops.templates."garage-masterchef.env".path
      ];
    };

    path = [ garagePackage ];

    script = ''
      set -euo pipefail

      garage() {
        ${garagePackage}/bin/garage "$@"
      }

      # Create bucket
      if ! garage bucket info cookbook >/dev/null 2>&1; then
        echo "Creating cookbook bucket"
        garage bucket create cookbook
      fi

      # Remove every access key except the one managed by NixOS.
      #
      # `garage key list` outputs the access key IDs. We deliberately
      # compare against the SOPS-provided key rather than the key name.
      while read -r key; do
        [ -z "$key" ] && continue

        if [ "$key" != "$COOKBOOK_CREDENTIALS_ACCESS_KEY" ]; then
          echo "Removing unmanaged access key: $key"
          garage key delete "$key"
        fi
      done < <(
        garage key list |
          tail -n +2 |
          awk '{print $1}'
      )

      # Create/import the managed key if it doesn't exist.
      if ! garage key info "$COOKBOOK_CREDENTIALS_ACCESS_KEY" >/dev/null 2>&1; then
        echo "Importing cookbook access key"

        garage key import \
          --yes \
          "$COOKBOOK_CREDENTIALS_ACCESS_KEY" \
          "$COOKBOOK_CREDENTIALS_SECRET_KEY" \
          --name cookbook
      fi

      # Ensure the key has exactly the permissions required by the
      # cookbook application.
      garage bucket allow \
        --read \
        --write \
        --key "$COOKBOOK_CREDENTIALS_ACCESS_KEY" \
        cookbook

      # Public read access through the web gateway.
      garage bucket website --allow cookbook

      echo "Garage cookbook provisioning complete"
    '';
  };

  services.nginx = {
    enable = true;

    virtualHosts."cdn.dennishilhorst.nl" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ];

      serverAliases = [
        "garage.home"
      ];

      locations."/" = {
        extraConfig = ''
          # /<bucket>/<object>
          if ($uri !~ ^/([^/]+)(/.*)$) {
            return 404;
          }

          set $garage_bucket $1;
          set $garage_object $2;

          proxy_set_header Host "$garage_bucket.${garageWebDomain}";
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

          rewrite ^/[^/]+/(.*)$ /$1 break;

          proxy_pass http://127.0.0.1:3902;
          proxy_buffering off;

          # only allow GET and HEAD requests to retrieve data from garage
          # through the web
          limit_except GET HEAD {
              deny all;
          }
        '';
      };
    };
  };

  networking.nftables.enable = true;
  networking.firewall = {
    # Public HTTP access to nginx
    allowedTCPPorts = [ 80 ];

    # Garage S3 API: only reachable by cookbook LXC
    extraInputRules = ''
      ip saddr ${lib.lxcs.cookbook.ip} tcp dport 3900 accept
    '';
  };
}
