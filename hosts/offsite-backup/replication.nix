{
  config,
  lib,
  pkgs,
  ...
}:

let
  nasHost = lib.storage.nas.tailnet_ip;
  sshKeyPath = "/var/lib/syncoid/.ssh/id_ed25519";

  # datasets pulled from the NAS (same name on both ends)
  replicatedDatasets = [
    "tank/drive"
    "tank/photos"
  ];
in
{
  # trust NAS public key
  programs.ssh.knownHosts."${nasHost}" = {
    # NAS's SSH host public key
    #   cat /etc/ssh/ssh_host_ed25519_key.pub
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmI0EOW5SNrZ4cF+F60mLMkwKmXKTHVPLV1hBhxxI2L root@nixos";
  };

  # pulls the same datasets the NAS already protects locally (see
  # hosts/nas/replication.nix) into this host's tank/drive and tank/photos
  # (already provisioned and set readonly in zfs.nix, since they're
  # replication targets and shouldn't be touched locally)
  #
  # recovering a single file from a snapshot:
  #   <mountpoint>/.zfs/snapshot/<snapshot-name>/
  #
  # disaster recovery, i.e. restoring a whole dataset back to a (new) NAS
  # after data loss there - run this FROM this host, in the opposite
  # direction of the normal pull above:
  #   list available snapshots to restore from:
  #     zfs list -t snapshot tank/drive
  #   send the chosen snapshot back, -F rolls the destination back to match
  #   (needed since a fresh/replacement NAS pool won't be)
  #     zfs send -R tank/drive@<snapshot> | ssh root@<nas-tailnet-ip> zfs receive -F tank/drive
  services.syncoid = {
    enable = true;
    sshKey = sshKeyPath;

    # the NAS's own sanoid config already creates the snapshots we send
    # (see hosts/nas/replication.nix), so we just pull whatever's newest
    # we do ensure that the snapshots cannot be deleted so we don't run
    # out of sync
    commonArgs = [
      "--no-sync-snap"
      "--use-hold"
    ];

    # the NAS only takes new snapshots daily, no point pulling more often
    interval = "daily";

    # permissions on local system to manage datasets
    localTargetAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "hold"
      "release"
    ];

    # wait for the ssh key below to exist before trying to connect
    service = {
      after = [ "syncoid-ssh-key.service" ];
      requires = [ "syncoid-ssh-key.service" ];

      # auto-tune datasets after sync (only really does something
      # after the initial sync job)
      unitConfig.OnSuccess = [ "zfs-replica-tuning.service" ];
    };

    commands = lib.genAttrs replicatedDatasets (ds: {
      source = "backup@${nasHost}:${ds}";
      target = ds;
    });
  };

  # dedicated keypair for the syncoid user to authenticate to the NAS with.
  # the private key never leaves this host, so there's nothing to manage
  # through sops here - just the NAS needs to trust the public half
  systemd.services.syncoid-ssh-key = {
    description = "Generate an SSH key for syncoid to authenticate to the NAS";
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "syncoid";
      Group = "syncoid";
      StateDirectory = "syncoid";
      StateDirectoryMode = "700";
    };

    script = ''
      mkdir -p -m 700 "$(dirname ${sshKeyPath})"
      if [ ! -f ${sshKeyPath} ]; then
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f ${sshKeyPath} -C "syncoid@offsite-backup"
      fi
    '';
  };

  # prune retrieved snapshots to avoid this dataset from blowing up
  # autosnap is set to false because the snapshots are taken from the
  # remote system
  services.sanoid = {
    enable = true;
    datasets = lib.genAttrs replicatedDatasets (_: {
      useTemplate = [ "replica" ];
      recursive = true;
    });
    templates.replica = {
      hourly = 0;
      daily = 7;
      weekly = 4;
      monthly = 3;
      autosnap = false;
      autoprune = true;
    };
  };

  # dataset tuning
  # replication targets are created by syncoid on first run, so they may not
  # exist yet. Deliberately no RemainAfterExit, so every sync re-triggers it.
  systemd.services.zfs-replica-tuning = {
    description = "Tune ZFS parameters for replicated datasets";
    after = [ "zfs-import.target" ];
    serviceConfig.Type = "oneshot";

    script =
      let
        zfs = "${pkgs.zfs}/bin/zfs";
      in
      ''
        for ds in ${lib.escapeShellArgs replicatedDatasets}; do
          if ${zfs} list -H -o name "$ds" >/dev/null 2>&1; then
            ${zfs} set compression=zstd "$ds"
            ${zfs} set atime=off "$ds"
            ${zfs} set readonly=on "$ds"
          fi
        done
      '';
  };
}
