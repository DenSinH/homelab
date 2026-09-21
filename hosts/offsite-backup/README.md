# Offsite Backup

The offsite backup strategy consists of two parts:

- a PBS remote for backing up (some of) the Proxmox containers
- ZFS datasets with sync jobs to sync data from the NAS

## ZFS Sync

Initially when installing the system, a ZFS pool `tank` must be created.
In order to do this, you will need the required ZFS tools installed, meaning you may have to do a first deploy _without_
```nix
boot.zfs.extraPools = [
  "tank"
];
```
in `zfs.nix`. You may want to list the available pools
```sh
zpool list
```
and import it with
```sh
zpool import <pool>
```
or, if `tank` does not exist, create it with
```sh
zpool create tank /dev/disk/by-id/...
```
of course finding the appropriate disk with
```sh
lsblk
ls -l /dev/disk/by-id
```
or something similar.

ZFS syncing is done with syncoid, and a specific `backup` user is created on the NAS (see `hosts/nas/offsite-backup.nix`) with the appropriate permissions.

In case there is a new host, an SSH key will be created at
```
/etc/ssh/ssh_host_ed25519_key.pub
```
and it will need to be added as trusted SSH key in `hosts/nas/offsite-backup.nix`, of course followed by a redeploy of `nas`.

## The PBS VM

The PBS VM is declared with [`NixVirt`](https://github.com/AshleyYakeley/NixVirt) in `pbs.nix`.
It is currently set up to have 2 vCPUs and 4GiB of memory.

In order for the configuration to work, a dataset `tank/pbs` must be created (manually) by running
```sh
zfs create tank/pbs
```
The parameters are tuned automatically with `zfs-pbs-tuning.service`, in `pbs.nix`.

### Starting and checking the VM

The VM is started automatically (`active = true` in the config). Check it with:

```sh
virsh -c qemu:///system list --all
```

If it is somehow shut down, start it with:

```sh
virsh -c qemu:///system start pbs
```

and check it with:

```sh
virsh -c qemu:///system list
```

### Connecting to the display

Check that the SPICE display is enabled with:

```sh
virsh -c qemu:///system domdisplay pbs
```

Then connect to the tunnelled display from your local machine with:

```sh
hosts/offsite-backup/remote-desktop.sh
```

### Installing PBS

When installing, **ENSURE THE VM IP AND GATEWAY ARE SET CORRECTLY**.
That is:

- VM IP: `192.168.122.10`
- Gateway: `192.168.122.1`

see also the top of `pbs.nix`

The boot order is hd then cdrom, so once PBS is installed it boots straight from hd on its own (a blank hd is skipped, falling through to cdrom).

You may need to run the following to fix DNS issues after install:

```sh
printf 'search home\nnameserver 192.168.122.1\n' > /etc/resolv.conf
```

### Post-install setup

Initialize the system with the [post-install script](https://community-scripts.org/scripts/post-pbs-install).

Then configure the `tank/pbs` dataset as a PBS datastore by running the following inside the VM:

```sh
mkdir -p /mnt/datastore
echo 'pbs-datastore /mnt/datastore virtiofs defaults,nofail 0 0' >> /etc/fstab
systemctl daemon-reload && mount /mnt/datastore
proxmox-backup-manager datastore create offsite /mnt/datastore
```

This creates a datastore called `offsite`.

### Setting up syncing

Tailscale needs to be installed on the local (i.e. main, onsite) PBS host
([docs](https://tailscale.com/docs/install/linux)):

```sh
curl -fsSL https://tailscale.com/install.sh | sh
```

Create an offsite backup user on the local PBS for the sync:

```sh
proxmox-backup-manager user create offsite@pbs
proxmox-backup-manager user generate-token offsite@pbs sync    # secret is shown once
proxmox-backup-manager acl update /datastore/<MAIN_STORE> DatastoreReader --auth-id offsite@pbs
proxmox-backup-manager acl update /datastore/<MAIN_STORE> DatastoreReader --auth-id 'offsite@pbs!sync'
proxmox-backup-manager cert info | grep Fingerprint
```

The role goes on both the user and the token, because a token can't have more
privileges than its user. A sync job can only sync backup groups that the
remote's user or token is able to read, so the reader role is what lets it see
everything. See [Managing Remotes](https://pbs.proxmox.com/docs-3/managing-remotes.html).

Create the remote in the web UI at **Remotes**, and the sync job at
**Datastore > offsite > Sync Jobs > Add > Add Pull Job**.

In order for the ZFS datastore to not grow unbounded, create a prune job with settings:
- Keep daily: 7
- Keep weekly: 4
- Keep monthly: 6

And run a GC job every week.