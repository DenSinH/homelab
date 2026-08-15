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
  sops.secrets = {
    "cookbook/masterchef-access-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
    };
    "cookbook/masterchef-secret-key" = {
      sopsFile = ../../secrets/cookbook-s3.yaml;
    };
  };

  # Credentials for cookbook bucket
  sops.templates."garage-masterchef.env" = {
    content = ''
      COOKBOOK_CREDENTIALS_ACCESS_KEY=${config.sops.placeholder."cookbook/masterchef-access-key"}
      COOKBOOK_CREDENTIALS_SECRET_KEY=${config.sops.placeholder."cookbook/masterchef-secret-key"}
    '';
  };

  # Configure the public website endpoint after Garage is running.
  systemd.services.garage-provision = {
    description = "Configure Garage cookbook bucket";

    wantedBy = [ "multi-user.target" ];

    after = [ "garage.service" ];
    requires = [ "garage.service" ];

    serviceConfig = {
      Type = "oneshot";
      Environment = [
        "GARAGE_RPC_ADDR=127.0.0.1:${builtins.toString cfg.s3_rpc_bind_port}"
      ];
      EnvironmentFile = [
        config.sops.templates."garage.env".path
        config.sops.templates."garage-masterchef.env".path
      ];
    };

    path = [ cfg.garagePackage ];

    script = ''
      set -euo pipefail

      garage() {
        ${cfg.garagePackage}/bin/garage "$@"
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
}
