{
  config,
  pkgs,
  lib,
  ...
}:

{
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
    device = "192.168.50.20:/mnt/primary/photos";
    fsType = "nfs";
    options = [
      "_netdev" # after network is available
      "nofail"
    ];
  };

  # todo: DB backup?
  services.immich = {
    enable = true;
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
}
