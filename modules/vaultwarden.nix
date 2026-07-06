{
  config,
  pkgs,
  lib,
  ...
}:

let
  # be sure to point a DNS record to the tailscale IP
  # corresponding to this host
  domain = "vault.dennishilhorst.nl";
in
{
  sops.defaultSopsFile = ../secrets/vaultwarden.yaml;
  sops.secrets = {
    "vaultwarden/cloudflare_dns_api_key" = { 
      group = "vaultwarden";
      mode = "0440";
    };
  };

  # NFS share for vaultwarden data backup
  # see
  # https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/services/security/vaultwarden/backup.sh
  # which refers to
  # https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault
  # For restoring:
  #   Restoring backup data
  #   Make sure vaultwarden is stopped, and then simply replace each file or directory
  #   in the data dir with its backed up version.
  #   When restoring a backup created using .backup or VACUUM INTO, make sure to first
  #   delete any existing db.sqlite3-wal file, as this could potentially result in
  #   database corruption when SQLite tries to recover db.sqlite3 using a
  #   stale/mismatched WAL file.
  #   However, if you backed up the database using a straight copy of db.sqlite3 and
  #   its matching db.sqlite3-wal file, then you must restore both files as a pair. You
  #   don't need to back up or restore the db.sqlite3-shm file.
  #
  #   It's a good idea to run through the process of restoring from backup periodically,
  #   just to verify that your backups are working properly. When doing this, make sure
  #   to move or keep a copy of your original data in case your backups do not in fact
  #   work properly.
  services.rpcbind.enable = true;
  boot.supportedFilesystems = [ "nfs" ];
  fileSystems."/mnt/vaultwarden-backup" = {
    # Expects primary/vaultwarden dataset / NFS share in TrueNAS
    device = "nas.home:/mnt/primary/vaultwarden";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail" # allow mount to fail as it is non critical
      "x-systemd.idle-timeout=600"
    ];
  };

  # migrating from proxmox LXC:
  # https://daniel.es/blog/how-to-migrate-vaultwarden/
  services.vaultwarden = {
    enable = true;
    domain = domain;

    configureNginx = true;

    # creates backup script automatically
    backupDir = "/mnt/vaultwarden-backup";

    config = {
      ROCKET_PORT = 8222;
    };
  };

  # change vaultwarden backup time
  systemd.timers.backup-vaultwarden.timerConfig.OnCalendar = "01:00";

  # for HTTPS to work, we use ACME
  # https://wiki.nixos.org/wiki/ACME
  # see also
  # https://blog.alper-celik.dev/posts/self-hosting-vaultwarden-and-setting-up-ssl-certificates-under-tailscale-in-nixos/
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${domain}";
    certs = {
      ${domain} = {
        domain = domain;
        group = "nginx";
        dnsProvider = "cloudflare";
        # create a token at https://dash.cloudflare.com/profile/api-tokens
        # with permissions:
        # - Zone - Zone - Read
        # - Zone - DNS - Edit
        # with resources
        # - Include - Specific zone - <your domain>
        # from some random documentation page:
        # see https://go-acme.github.io/lego/dns/cloudflare/#api-tokens
        credentialFiles = {
          CLOUDFLARE_DNS_API_TOKEN_FILE = config.sops.secrets."vaultwarden/cloudflare_dns_api_key".path;
        };
        dnsResolver = "1.1.1.1:53";
      };
    };
  };

  # the virtualhost is just called the domain name when configured with
  # services.vaultwarden.configureNginx = true
  # https://github.com/NixOS/nixpkgs/blob/4062d36ebeae843c750011eef6b61ec9a9dbc9a9/nixos/modules/services/security/vaultwarden/default.nix#L225
  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    acmeRoot = null;
  };
}
