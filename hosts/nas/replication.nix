{ config, pkgs, ... }:

{
  # recovering file from snapshot:
  # files are exposed at
  #   <mountpoint>/.zfs/snapshot/<snapshot-name>/
  # rolling back entire dataset:
  #   zfs rollback <snapshot-name>
  # with snapshot-name being something like tank/drive@autosnap_...
  services.sanoid = {
    enable = true;
    datasets = {
      "tank/drive" = {
        useTemplate = [ "production" ];
        recursive = true;
      };
      "tank/photos" = {
        useTemplate = [ "production" ];
        recursive = true;
      };
    };
    templates.production = {
      hourly = 0;
      daily = 7;
      weekly = 4;
      monthly = 3;
      autosnap = true;
      autoprune = true;
    };
  };

  # restoring from backup:
  #   zfs send backup/drive-backup@<snapshot> | zfs receive tank/drive
  services.syncoid = {
    enable = true;
    commonArgs = [ "--no-sync-snap" ];
    commands = {
      "tank/drive" = {
        target = "backup/drive-backup";
      };
      "tank/photos" = {
        target = "backup/photos-backup";
      };
    };
  };
}
