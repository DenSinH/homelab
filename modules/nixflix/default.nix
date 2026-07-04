{
  config,
  pkgs,
  lib,
  nixflix,
  utils,
  ...
}:

let
  mediaMount = "/mnt/media";
in
{
  # NFS settings
  services.rpcbind.enable = true;
  boot.supportedFilesystems = [ "nfs" ];
  fileSystems.${mediaMount} = {
    # Expects primary/vaultwarden dataset / NFS share in TrueNAS
    device = "192.168.50.20:/mnt/primary/media";
    fsType = "nfs";
    options = [
      "_netdev" # after network is available
      "nofail"
    ];
  };

  sops.secrets = {
    "sonarr/api_key" = { };
    "sonarr/password" = { };
    "radarr/api_key" = { };
    "radarr/password" = { };
    "prowlarr/api_key" = { };
    "prowlarr/password" = { };
    "qbittorrent/password" = { };
    # "jellyfin/alice_password" = { };
  };

  # enable tailscale
  imports = [
    ../tailscale.nix
  ];

  services.tailscale.extraSetFlags = [
    # find mullvad exit nodes with
    # tailscale exit-node list
    "--exit-node=nl-ams-wg-201.mullvad.ts.net"
    "--exit-node-allow-lan-access"
  ];

  # see
  # https://kiriwalawren.github.io/nixflix/reference/
  nixflix = {
    enable = true;

    mediaDir = mediaMount;
    downloadsDir = "${mediaMount}/downloads";

    # todo: put this somewhere else? NFS? Backed up?
    stateDir = "/data/.state";

    # I don't want nginx, since multiple domains do not seem to be
    # implemented, and I just couldn't get it working...
    postgres.enable = true;

    serviceDependencies = [
      # services should wait for media mount to finish
      # see
      # https://github.com/NixOS/nixpkgs/blob/80d591ed473cfc46329932c2aadac9b435342c7c/nixos/modules/tasks/filesystems/overlayfs.nix#L31
      "${utils.escapeSystemdPath mediaMount}.mount"
      "tailscaled.service"
    ];

    radarr = {
      enable = true;
      openFirewall = true;

      config = {
        apiKey = {
          _secret = config.sops.secrets."radarr/api_key".path;
        };
        hostConfig = {
          username = "admin";
          password = {
            _secret = config.sops.secrets."radarr/password".path;
          };
          # applicationUrl
        };
        rootFolders = [
          {
            path = "${mediaMount}/movies";
          }
        ];
      };
    };

    sonarr = {
      enable = true;
      openFirewall = true;

      config = {
        apiKey = {
          _secret = config.sops.secrets."sonarr/api_key".path;
        };
        hostConfig = {
          username = "admin";
          password = {
            _secret = config.sops.secrets."sonarr/password".path;
          };
          # applicationUrl
        };
        rootFolders = [
          {
            path = "${mediaMount}/shows";
          }
        ];
      };
    };

    flaresolverr.enable = true;

    prowlarr = {
      enable = true;
      openFirewall = true;

      config = {
        apiKey = {
          _secret = config.sops.secrets."prowlarr/api_key".path;
        };
        hostConfig = {
          username = "admin";
          password = {
            _secret = config.sops.secrets."prowlarr/password".path;
          };
          # applicationUrl
        };
        indexers = [
          # additional properties are injected into the schema
          # as per https://kiriwalawren.github.io/nixflix/reference/prowlarr/config/indexers/
          # see ./indexer-example.json
          {
            name = "1337x";
            tags = [ "flaresolverr" ];
          }
          {
            name = "EZTV";
            tags = [ "flaresolverr" ];
          }
          {
            name = "LimeTorrents";
          }
          {
            name = "Magnet Cat";
            tags = [ "flaresolverr" ];
          }
          {
            name = "The Pirate Bay";
          }
          # offline? 522: try again later
          # {
          #   name = "Torrent Downloads";
          # }
          # {
          #   name = "TorrentDownload";
          # }
          {
            name = "YTS";
          }
        ];
      };
    };

    torrentClients.qbittorrent = {
      enable = true;
      openFirewall = true;

      password = {
        _secret = config.sops.secrets."prowlarr/password".path;
      };

      # see
      # https://search.nixos.org/options?channel=unstable&query=qbittorrent#show=option%253Aservices.qbittorrent.serverConfig
      serverConfig = {
        LegalNotice.Accepted = true;

        BitTorrent.Session = {
          AddTorrentStopped = false;
          GlobalMaxRatio = 0;

          # Only use tailscale interface
          Interface = config.services.tailscale.interfaceName;
          InterfaceName = config.services.tailscale.interfaceName;
        };

        Preferences = {
          WebUI = {
            User = "admin";

            # generate with
            # nix run git+https://codeberg.org/feathecutie/qbittorrent_password -p <password>
            # or
            # nix run git+https://codeberg.org/feathecutie/qbittorrent_password -i <password-file>
            # for example run ./gen-password.sh to generate it from stdin
            Password_PBKDF2 = "@ByteArray(kR+FfrNzdOkhVab2ph7Ocg==:kHtoKhAe64dbk7wQJl0eeUF1hYu767BObpRzn1DxON1drcgOBC5zlAA6aGrfRwZCRcaoPqp3K6Yu3UYK2O2sJg==)";
            LocalHostAuth = false;
            AuthSubnetWhitelist = "192.168.50.0/24";
            AuthSubnetWhitelistEnabled = true;
          };
        };
      };
    };
  };
}
