{
  config,
  lib,
  pkgs,
  ...
}:

let
  backupDatasets = [
    "tank/drive"
    "tank/photos"
  ];
in
{
  users.groups.backup = { };

  users.users.backup = {
    isSystemUser = true;
    group = "backup";
    home = "/var/lib/backup";
    createHome = true;

    # user needs shell for syncoid to work
    shell = pkgs.bash;

    # auto-generated SSH key at
    #   /var/lib/syncoid/.ssh/id_ed25519.pub
    # on the offsite-backup system itself
    openssh.authorizedKeys.keys = [
      "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzWXcHoX+a/C2mxkMA663o+L6NCAOvV7KogKgBW6JVY syncoid@offsite-backup"
    ];
  };

  systemd.services.backup-zfs-permissions = {
    description = "Grant Syncoid backup permissions on ZFS datasets";
    wantedBy = [ "zfs.target" ];
    after = [ "zfs.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = lib.concatMapStringsSep "\n" (dataset: ''
      ${pkgs.zfs}/bin/zfs allow -u backup \
        send \
        ${lib.escapeShellArg dataset}
    '') backupDatasets;
  };
}
