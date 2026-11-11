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
      # syncoid copies every snapshot but never prunes the target
      "backup/drive-backup" = {
        useTemplate = [ "replica" ];
        recursive = true;
      };
      "backup/photos-backup" = {
        useTemplate = [ "replica" ];
        recursive = true;
      };
    };
    templates.replica = {
      hourly = 24;
      daily = 7;
      weekly = 4;
      monthly = 3;
      autosnap = false;
      autoprune = true;
    };
    templates.production = {
      # hourly gives same-day rollback for accidental deletes/overwrites,
      # instead of waiting for the next daily snapshot
      hourly = 24;
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
