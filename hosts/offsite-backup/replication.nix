{
  config,
  lib,
  pkgs,
  ...
}:

let
  nasHost = lib.storage.nas.tailnet_ip;
  sshKeyPath = "/var/lib/syncoid/.ssh/id_ed25519";
in
{
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
  #   this requires this host's public key (/var/lib/syncoid/.ssh/id_ed25519.pub)
  #   to be in the NAS's authorized_keys too, the same as the pull direction
  services.syncoid = {
    enable = true;
    sshKey = sshKeyPath;

    # the NAS's own sanoid config already creates the snapshots we send
    # (see hosts/nas/replication.nix), so we just pull whatever's newest
    commonArgs = [ "--no-sync-snap" ];

    # the NAS only takes new snapshots daily, no point pulling more often
    interval = "daily";

    # wait for the ssh key below to exist before trying to connect
    service = {
      after = [ "syncoid-ssh-key.service" ];
      requires = [ "syncoid-ssh-key.service" ];
    };

    commands = {
      "tank/drive" = {
        source = "root@${nasHost}:tank/drive";
        target = "tank/drive";
      };
      "tank/photos" = {
        source = "root@${nasHost}:tank/photos";
        target = "tank/photos";
      };
    };
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

  # TODO once the NAS is actually reachable over tailscale:
  #   - replace lib.storage.nas.tailnet_ip's placeholder in flake.nix with
  #     its real tailscale IP
  #   - grab the generated public key with
  #       ssh root@offsite-backup.vpn cat /var/lib/syncoid/.ssh/id_ed25519.pub
  #     and add it to the NAS's /root/.ssh/authorized_keys

  # prevents received snapshots from piling up here forever: the NAS's own
  # sanoid already prunes tank/drive and tank/photos on its side (see
  # hosts/nas/replication.nix), but syncoid only ever receives, it never
  # deletes - so without this, every snapshot ever sent would stick around
  # on this host indefinitely. autosnap is off since snapshots arrive via
  # syncoid, not taken locally; retention matches the NAS's own policy so
  # this replica doesn't outgrow the space budget shared with tank/pbs
  services.sanoid = {
    enable = true;
    datasets = {
      "tank/drive" = {
        useTemplate = [ "replica" ];
        recursive = true;
      };
      "tank/photos" = {
        useTemplate = [ "replica" ];
        recursive = true;
      };
    };
    templates.replica = {
      hourly = 0;
      daily = 7;
      weekly = 4;
      monthly = 3;
      autosnap = false;
      autoprune = true;
    };
  };
}
