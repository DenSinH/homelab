{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}:

{
  sops.defaultSopsFile = ../../secrets/immich.yaml;
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
    # TODO: remove after updating to 26.11
    package = pkgs-unstable.immich;

    host = "0.0.0.0";
    # port = 80;  # default: 2283
    openFirewall = true;
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

  # Helper script for matching up live photos to corresponding videos
  environment.systemPackages = [
    (pkgs.writers.writePython3Bin "immich-link-live-photos" {
      # the script has long lines; flake8 runs at build time by default
      flakeIgnore = [
        "E501"
        "E265"
      ];
    } (builtins.readFile ./immich-link-live-photos.py))
  ];

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
