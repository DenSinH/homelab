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
  fromRepo = nixflix.lib.jellyfinPlugins.fromRepo;

  defaultSecretSettings = {
    group = "media";
    mode = "0440";
  };
in
{
  # NFS settings
  services.rpcbind.enable = true;
  boot.supportedFilesystems = [ "nfs" ];
  fileSystems.${mediaMount} = {
    # Expects primary/vaultwarden dataset / NFS share in TrueNAS
    device = "${lib.storage.nas.ip}:/tank/media";
    fsType = "nfs";
    options = [
      "_netdev" # after network is available
      "nofail"
    ];
  };

  sops.defaultSopsFile = ../../secrets/nixflix.yaml;
  sops.secrets = {
    "sonarr/api_key" = defaultSecretSettings;
    "sonarr/password" = defaultSecretSettings;
    "radarr/api_key" = defaultSecretSettings;
    "radarr/password" = defaultSecretSettings;
    "prowlarr/api_key" = defaultSecretSettings;
    "prowlarr/password" = defaultSecretSettings;
    "qbittorrent/password" = defaultSecretSettings;
    "jellyfin/api_key" = defaultSecretSettings;
    "jellyfin/dennis_password" = defaultSecretSettings;
    "jellyfin/merel_password" = defaultSecretSettings;
    "jellyfin/opensubtitles/password" = defaultSecretSettings;
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
      # We may enable this, but qBitTorrent is configured to only
      # run over the tailscale NIC anyway...
      # "tailscaled.service"
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
            # for example run ./gen-qbittorrent-password.sh to generate it from stdin
            Password_PBKDF2 = "@ByteArray(kR+FfrNzdOkhVab2ph7Ocg==:kHtoKhAe64dbk7wQJl0eeUF1hYu767BObpRzn1DxON1drcgOBC5zlAA6aGrfRwZCRcaoPqp3K6Yu3UYK2O2sJg==)";
            LocalHostAuth = false;
            AuthSubnetWhitelist = "192.168.50.0/24";
            AuthSubnetWhitelistEnabled = true;
          };
        };
      };
    };

    jellyfin = {
      enable = true;
      openFirewall = true;

      apiKey._secret = config.sops.secrets."jellyfin/api_key".path;
      users = {
        # user IDs taken from existing Jellyfin installation for easier
        # migration of data
        dennis = {
          mutable = false;
          id = "cbfb974aab8f41f98902458b28ccc372";
          policy.isAdministrator = true;
          password._secret = config.sops.secrets."jellyfin/dennis_password".path;
        };
        merel = {
          mutable = false;
          id = "33ff2447d0584ae480d4392f42ae17c9";
          policy.isAdministrator = false;
          password._secret = config.sops.secrets."jellyfin/merel_password".path;
        };
      };

      libraries = {
        Movies = lib.mkForce {
          collectionType = "movies";
          enableRealtimeMonitor = true;
          paths = [
            "${mediaMount}/movies"
          ];
          preferredMetadataLanguage = "en";
          enableTrickplayImageExtraction = false;
          extractTrickplayImagesDuringLibraryScan = false;
          saveTrickplayWithMedia = true;
        };
        Shows = lib.mkForce {
          collectionType = "tvshows";
          enableRealtimeMonitor = true;
          paths = [
            "${mediaMount}/shows"
          ];
          seasonZeroDisplayName = "Specials";
          enableTrickplayImageExtraction = false;
          extractTrickplayImagesDuringLibraryScan = false;
          saveTrickplayWithMedia = true;
        };
      };

      encoding = {
        allowAv1Encoding = true;
        allowHevcEncoding = true;
        hardwareAccelerationType = "qsv"; # Intel Quicksync (running on N100)
      };

      system.pluginRepositories = {
        "Intro Skipper" = {
          url = "https://raw.githubusercontent.com/intro-skipper/manifest/main/10.11/manifest.json";
          hash = "sha256:0bkvcliywipn7k2cp15x5fkx3n7k3da47f4p8x2fzli2h5jqz5vd";
          enabled = true;
        };
      };

      plugins = {
        # https://kiriwalawren.github.io/nixflix/examples/jellyfin-plugins/#configuration
        "Intro Skipper" = {
          package = fromRepo {
            version = "1.10.11.22";
            hash = "sha256-x8xxfJb2to3BIdneUj2FcPdMBbTt7kmhfvGtBqWlDQ4=";
          };
        };

        # https://kiriwalawren.github.io/nixflix/examples/jellyfin-subtitles/#configuration
        "Open Subtitles" = {
          enable = true;
          config = {
            Username = "DenSinH";
            Password._secret = config.sops.secrets."jellyfin/opensubtitles/password".path;
          };
        };

        "Subtitle Extract" = {
          enable = true;
          config.ExtractionDuringLibraryScan = true;
        };
      };
    };
  };
}
