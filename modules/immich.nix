{
  config,
  pkgs,
  lib,
  ...
}:

{
  # TODO: remove after updating to 26.11
  nixpkgs.config.permittedInsecurePackages = [
    "immich-2.7.5"
  ];

  sops.defaultSopsFile = ../secrets/immich.yaml;
  sops.secrets = {
    "immich/secrets" = {
      group = "immich";
      mode = "0440";
    };
  };

  # NFS settings
  services.rpcbind.enable = true;
  boot.supportedFilesystems = [ "nfs" ];
  fileSystems."/mnt/photos" = {
    # Expects primary/vaultwarden dataset / NFS share in TrueNAS
    device = "${lib.storage.nas.ip}:/tank/photos";
    fsType = "nfs";
    options = [
      "_netdev" # after network is available
      "nofail"
    ];
  };

  services.immich = {
    enable = true;
    host = "127.0.0.1"; # nginx in front now terminates TLS and proxies in
    # port = 80;  # default: 2283
    openFirewall = false;
    mediaLocation = "/mnt/photos";

    # These are settings I set in the past, I figured I'd just re-use them
    settings = {
      ffmpeg = {
        accel = "vaapi";
        accelDecode = true;
      };
      image = {
        # not sure what these do
        fullsize.progressive = false;
        preview.progressive = false;
        thumbnail.progressive = false;
      };
      job.editor.concurrency = 2;
      job.workflow.concurrency = 5;
    };

    environment = {
      IMMICH_VERSION = "release";
    };
    secretsFile = "${config.sops.secrets."immich/secrets".path}";

    accelerationDevices = [
      "/dev/dri/renderD128"
    ];
  };

  homelab.selfSignedCerts.immich = {
    hostName = "immich.home";
    extraSANs = [ "DNS:immich.vpn" ];
    vhosts = [ "immich.home" ];
  };

  services.nginx = {
    enable = true;

    virtualHosts."immich.home" = {
      serverAliases = [ "immich.vpn" ];

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.immich.port}";
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 0;
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  systemd.services.immich-server = {
    # wait for mount to be available
    wants = [
      "network-online.target"
      "mnt-photos.mount"
    ];
    after = [
      "network-online.target"
      "mnt-photos.mount"
    ];
  };

  # Fix access to passed through iGPU
  # May break when installed on a new system (different render GID), test with
  #   ls -ln /dev/dri/renderD128
  #   id immich
  # in the LXC, or for actually using the device, run
  #   nix-shell -p libva-utils --run 'sudo -u immich $(command -v vainfo) --display drm --device /dev/dri/renderD128'
  # or run ffmpeg:
  #   nix-shell -p ffmpeg --run 'sudo -u immich $(command -v ffmpeg) -init_hw_device vaapi=accel:/dev/dri/renderD128 -f lavfi -i testsrc=duration=2:size=1280x720:rate=30 -vf "format=nv12,hwupload" -c:v h264_vaapi -f null -'
  #
  # On a new install, get the render group GID with:
  # - on the LXC:
  #     stat -c %g /dev/dri/renderD128
  # - on the host:
  #     getent group render
  users.groups.hostrender.gid = 993;
  users.users.immich.extraGroups = [ "hostrender" ];

  # immich-server (NestJS) logs plenty of WARN-level lines (e.g. an upload
  # aborted by the client) that mention "error"/"aborted" and get
  # mis-detected as errors. Real errors are logged as "ERROR".
  homelab.alloy.extraLokiProcessConfig = ''
    stage.match {
      selector = "{unit=\"immich-server.service\"} |~ \"WARN\""

      stage.template {
        source   = "level"
        template = "warn"
      }

      stage.structured_metadata {
        values = {
          level = "",
        }
      }
    }
  '';
}
