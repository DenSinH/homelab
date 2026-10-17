# Disaster recovery

Recovery procedures for the homelab. Host setup, sops and deploy commands follow the [README](./README.md) ("Creating a new physical NixOS host", "Secrets", "Deploying").

## What lives where

| Data | Primary | Other copies |
|---|---|---|
| `tank/drive`, `tank/photos` | NAS `tank` | NAS `backup` pool (`hosts/nas/replication.nix`), offsite `tank` (syncoid pull over the tailnet) |
| Proxmox VM/LXC backups | local PBS | offsite PBS datastore `offsite` (`/tank/pbs` on the offsite host), pulled by a sync job. Some VMs are excluded. |
| Configuration | this repo | any clone |
| Secrets | `secrets/` (sops) | readable only with an age key |

Use master SSH key derived age key for secrets by setting
```
export SOPS_AGE_KEY_FILE=/path/to/private/key/id_ed25519
sops secrets/example.yaml
```

## Rules

1. Find the good copy first (`zpool status -v`, `zfs list -t snapshot`). Do not `zpool create`, `zfs destroy` or `zfs recv -F` until you know which copy is authoritative.
1. Never let an empty or rebuilt side replicate over a good one. Pause the timers (`systemctl list-timers | grep -E 'sanoid|syncoid'`) and PBS sync jobs until the restore is verified.
1. Pool layouts (mirror/raidz) are not recorded here. `zpool status` decides which branch applies.

## Dataset reference

Which datasets exist, where, and how they come to exist. "Auto" means `zfs receive` (via syncoid) creates it on first sync — don't pre-create these or the incoming stream may conflict with an empty dataset's properties.

| Dataset | Pool @ host | Created by | Notes |
|---|---|---|---|
| `tank/drive` | `tank` @ NAS | manual: `zfs create tank/drive` | NFS share, snapshotted (sanoid) + replicated to `backup` and offsite |
| `tank/photos` | `tank` @ NAS | manual: `zfs create tank/photos` | NFS share (immich), snapshotted + replicated to `backup` and offsite |
| `tank/media` | `tank` @ NAS | manual: `zfs create tank/media` | NFS share (nixflix); **not** snapshotted or replicated anywhere |
| `tank/vaultwarden` | `tank` @ NAS | manual: `zfs create tank/vaultwarden` | NFS share, receives vaultwarden's nightly sqlite backup dump; **not** snapshotted or replicated (the vault's live DB is backed up separately via PBS) |
| `backup/drive-backup` | `backup` @ NAS | auto (syncoid, first `tank/drive` sync) | on-NAS mirror of `tank/drive` |
| `backup/photos-backup` | `backup` @ NAS | auto (syncoid, first `tank/photos` sync) | on-NAS mirror of `tank/photos` |
| `tank/drive` | `tank` @ offsite-backup | auto (syncoid receive, first pull) | `readonly=on`, kept `--use-hold` |
| `tank/photos` | `tank` @ offsite-backup | auto (syncoid receive, first pull) | `readonly=on`, kept `--use-hold` |
| `tank/pbs` | `tank` @ offsite-backup | manual: `zfs create tank/pbs` | virtiofs-shared into the PBS VM as its datastore |

`tank/media` and `tank/vaultwarden` are the only two datasets with a single copy — if their disks are lost, that data is unrecoverable from this repo's tooling.

## Keep outside the homelab

- A copy of the sops age key (`/var/lib/sops-nix/keys.txt`). Without one you cannot decrypt secrets or run `sops updatekeys`.
- The PBS client encryption key, if backups are encrypted.
- Tailscale admin and GitHub access, plus any ISP/WAN details that are not in the repo.

---

## 1. Local PBS failure

Impact: no local restore points. The offsite PBS holds everything except VMs excluded from the sync (e.g. the Windows template), which have no other copy.

1. On the offsite PBS (`Datastore > offsite > Sync Jobs`) disable the pull job and check that *Remove vanished* is off. A rebuilt, empty local store must not wipe the offsite copy.
1. Reinstall PBS on the replacement and install Tailscale.
1. Perform any other post-installation steps (post-install script etc.)
1. Create the datastore.
   - **Disk intact:** attach it and reuse the data.
     ```sh
     proxmox-backup-manager datastore create <name> <path> --reuse-datastore true
     ```
   - **Disk lost:** create an empty datastore and refill it from offsite. On the offsite PBS create a reader user and token (`DatastoreReader` on `/datastore/offsite`, on both user and token, as for the offsite sync user). On the local PBS add it under *Remotes* (`offsite-backup.vpn`, port 8007, fingerprint from `proxmox-backup-manager cert info | grep Fingerprint` on the offsite PBS), then run a pull job offsite → local.
1. Restore the sync path: create `offsite@pbs` and its `sync` token on the new local PBS (`DatastoreReader` on both), then update the Remote on the offsite PBS. The fingerprint and token secret have changed. Re-enable the offsite pull job only once the local store is populated.
1. Recreate prune, GC and verify jobs. On PVE repoint the PBS storage (`pvesm set <storage> --fingerprint <new-fp>`, plus address if changed) and restore the encryption key if used.
1. Rebuild the excluded VMs by hand.

## 2. Offsite backup failure (host or drive)

Impact: redundancy loss only. NAS and local PBS are intact and everything offsite can be re-pulled, but you have no offsite copy until it is rebuilt.

**Drive failed, host up:** `zpool status -v`. If `tank` is still redundant, `zpool replace tank <old> <new>` (use `/dev/disk/by-id`), wait for the resilver, then `zpool scrub tank`. If the pool is lost, continue below with fresh disks.

**Host failed or pool lost:**

1. Install NixOS on the replacement and add it as in the README. Disks intact: `zpool import -f tank` (or reuse the old `networking.hostId`). Fresh disks, matching whatever redundancy the old pool used:
   ```sh
   zpool create tank <mirror|raidz1|raidz2> /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> ...
   ```
1. Create `tank/pbs` and `chown 34:34 /tank/pbs` (the `backup` user in the guest). Do this before deploying, because the VM's virtiofs share sources that path.
   ```sh
   zfs create tank/pbs
   chown 34:34 /tank/pbs
   ```
   `zfs-pbs-tuning.service` (`pbs.nix`) sets `compression=zstd`/`atime=on`/`relatime=on` on it automatically after the next deploy; run `systemctl restart zfs-pbs-tuning.service` to apply immediately without waiting for a reboot.
You may have to disable parts of the configuration, as you may need `zfs` tools which are only available with some parts of the configuration, but other parts may fail without the pool existing.
1. Deploy:
   ```sh
   nixos-rebuild switch --flake .#offsite-backup --target-host root@<ip> --sudo
   ```
   NixVirt recreates the network, pool, volume and VM (blank disk, booting from the ISO).
1. Re-join the tailnet (remove the stale node in the admin console first). Update any IPs if necessary.
1. If the syncoid SSH key was regenerated, add the new public key to the NAS `backup` user and redeploy the NAS. Then start the syncoid units by hand. The first run is a full send of `tank/drive` and `tank/photos`. If the NAS's sanoid cannot prune afterwards, look for stale holds (`zfs holds -r tank/drive`) and `zfs release` them.
1. Reinstall the PBS VM following the setup notes in the pbs module: VM IP `192.168.122.10`, gateway `192.168.122.1`, post-install script, mount `pbs-datastore` at `/mnt/datastore`, create datastore `offsite` (add `--reuse-datastore true` if `/tank/pbs` survived), recreate the Remote and pull job. It refills from the local PBS. See also [hosts/offsite-backup/README.md](hosts/offsite-backup/README.md).

## 3. NAS disk failure

1. `zpool status -v` on the NAS. Note the pool (`tank` or `backup`) and the disk (by-id).
1. **Redundancy intact:** `zpool replace <pool> <old> <new>` (use `/dev/disk/by-id`), wait for the resilver, `zpool scrub <pool>`, and check SMART on the remaining disks. Done.
1. **`backup` pool lost, `tank` fine:** recreate `backup` and run the NAS syncoid units to re-seed it from `tank`.
1. **`tank` lost, `backup` fine:** pause the timers, recreate `tank`:
   ```sh
   zpool create tank <mirror|raidz1|raidz2> /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> ...
   ```
   then restore `tank/drive` and `tank/photos` from the local copy (`zfs receive` creates the target dataset itself, so don't pre-create these two):
   ```sh
   syncoid --no-sync-snap -r backup/drive-backup tank/drive
   syncoid --no-sync-snap -r backup/photos-backup tank/photos
   ```
   The snapshot history comes along, so NAS → `backup` and offsite replication resume incrementally. Check `zfs get -r readonly,mountpoint tank`, then re-enable the timers.
   `tank/media` and `tank/vaultwarden` are not replicated anywhere (see "Dataset reference" above), so recreate them directly:
   ```sh
   zfs create tank/media
   zfs create tank/vaultwarden
   ```
   Then apply dataset tuning (recordsize/cache/atime — see `zfs-dataset-tuning.service` in `zfs.nix`):
   ```sh
   systemctl restart zfs-dataset-tuning.service
   ```
1. **Both lost:** see section 4, restoring from offsite.

## 4. NAS total failure

1. On the offsite host stop the pull timers (`systemctl stop 'syncoid-*.timer'`) so nothing pulls from a half-restored NAS.
1. Replacement hardware: install NixOS as in the README and provision the age key. **Disks survived:** `zpool import -f tank backup` (or reuse the old `networking.hostId`) and skip to step 4.
1. **Disks lost:** create `tank` and `backup`, matching the old redundancy level:
   ```sh
   zpool create tank <mirror|raidz1|raidz2> /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> ...
   zpool create backup <mirror|raidz1|raidz2> /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> ...
   ```
   `tank/drive` and `tank/photos` are recreated automatically by the `zfs receive` in step 5 below — don't pre-create them. `tank/media` and `tank/vaultwarden` have no offsite copy (see "Dataset reference" above): if their disks are gone too, that data is unrecoverable; otherwise recreate them empty:
   ```sh
   zfs create tank/media
   zfs create tank/vaultwarden
   ```
1. Deploy:
   ```sh
   nixos-rebuild switch --flake .#nas --target-host root@<ip> --sudo
   ```
1. **Disks lost:** restore from offsite by running this on the NAS. It needs root SSH from the NAS to offsite, so add the NAS's new key there.
   ```sh
   syncoid --no-sync-snap -r root@offsite-backup.vpn:tank/drive tank/drive
   syncoid --no-sync-snap -r root@offsite-backup.vpn:tank/photos tank/photos
   ```
   For large datasets it is faster to carry the offsite disks to the NAS, `zpool import` them and send locally. The offsite copies are `readonly`. Make sure the restored datasets are writable (`zfs get -r readonly tank`).
1. Fix trust: clear the NAS's old SSH host key on the offsite host (`ssh-keygen -R <nas>`) and re-join the tailnet after removing the stale node.
1. Verify (`zfs list -t snapshot`, spot-check files), then re-enable NAS sanoid/syncoid (this re-seeds `backup`) and the offsite pull timers. Snapshot history was restored, so the pull is incremental. Run `systemctl restart zfs-dataset-tuning.service` to apply cache/recordsize/atime tuning to any freshly created datasets.

## 5. Router failure

Impact: the LAN loses routing, DHCP, DNS and WAN access. The subnet router and the offsite pulls also stop until it is back.

1. Bring up temporary internet if needed (spare router or the ISP modem in routed mode). The router config is declarative, so there is nothing to restore from backup.
1. Replacement hardware (or VM) needs a WAN and a LAN NIC. Install NixOS as in the README. Interface names and MACs change on new hardware, so update `hardware-configuration.nix` and any interface names in the router's host config.
1. Deploy from a workstation with a static IP on the LAN, since there is no DHCP and `router.home` will not resolve:
   ```sh
   nixos-rebuild switch --flake .#router --target-host root@<ip> --sudo
   ```
   If root SSH is not available on a fresh install, use the non-root variant from the README (`--ask-sudo-password`).
1. Verify: WAN up, DHCP and DNS working, and LXCs in the "services" range getting their configured IPs (renew the lease or restart if not). Check `tailscale status` on `subnet-router` and the NAS, then run the offsite syncoid units to confirm replication.

---

## 6. ZFS / VM command reference

### Pool and disk health

```sh
zpool status -v <pool>          # health, errors, resilver/scrub progress
zpool list                      # size, allocation, fragmentation, health, one line per pool
zpool iostat -v <pool> 2        # live per-vdev/per-disk throughput and latency
zpool events -v                 # recent pool events (faults, checksum errors, etc.)
zpool history <pool>            # commands that built the pool (vdev layout, if the pool still exists)
lsblk                           # see attached disks
ls -l /dev/disk/by-id           # stable disk identifiers to use in zpool/create/replace commands
smartctl -a /dev/disk/by-id/<disk>   # SMART health for one disk
```

### Replacing a failed disk

```sh
zpool replace <pool> <old-disk-or-by-id> <new-disk-by-id>
zpool status <pool>              # watch "resilver in progress"
zpool scrub <pool>                # run after a resilver completes, to confirm data integrity
zpool clear <pool>                 # clear a stale error count once the fault is actually resolved
```

### Datasets

```sh
zfs list -r <pool>                          # datasets, used/avail space, mountpoints
zfs list -t snapshot -r <pool>              # all snapshots, e.g. to find a recovery point
zfs get -r compression,recordsize,atime,readonly <dataset>
zfs create <pool>/<name>                    # new dataset (see "Dataset reference" above for which ones)
zfs set <property>=<value> <dataset>        # e.g. compression=zstd, atime=off, recordsize=1M
zfs rename <dataset> <new-name>
zfs destroy <dataset>                       # DESTRUCTIVE - see RECOVERY rules above before ever using this
```

### Snapshots (sanoid takes these automatically; manual use for one-off protection)

```sh
zfs snapshot <dataset>@<name>
zfs snapshot -r <dataset>@<name>            # recursive, includes child datasets
zfs rollback <dataset>@<name>               # DESTRUCTIVE - discards everything newer than the snapshot
zfs diff <dataset>@<snap1> <dataset>@<snap2>   # what changed between two snapshots
zfs destroy <dataset>@<name>                # remove one snapshot
```
Browse a snapshot without rolling back: files are exposed read-only at `<mountpoint>/.zfs/snapshot/<snapshot-name>/`.

### Send / receive (what syncoid wraps)

```sh
zfs send -R <dataset>@<snap> | zfs receive -F <target-dataset>   # full send; -F rolls the destination back to match
zfs send -R -I <dataset>@<oldsnap> <dataset>@<newsnap> | zfs receive <target-dataset>   # incremental
zfs send ... | pv | zfs receive ...          # pipe through pv to watch transfer progress
```

### Holds (prevent a snapshot syncoid/sanoid still needs from being pruned)

```sh
zfs holds -r <dataset>            # list current holds
zfs hold <tag> <dataset>@<snap>
zfs release <tag> <dataset>@<snap>
```

### Sanoid / syncoid operational commands

```sh
systemctl list-timers | grep -E 'sanoid|syncoid'   # when jobs last/next ran
systemctl start syncoid-<dataset>.service          # run a sync job immediately, e.g. syncoid-tank-drive.service
journalctl -u syncoid-<dataset>.service -f          # watch a sync job's output live
syncoid --dryrun <source> <target>                  # preview what a manual syncoid run would do, without sending
```

### VMs (libvirt/NixVirt — currently just the offsite PBS VM)

```sh
virsh -c qemu:///system list --all                  # running/stopped VMs
virsh -c qemu:///system start <vm>
virsh -c qemu:///system shutdown <vm>                # graceful ACPI shutdown
virsh -c qemu:///system destroy <vm>                 # hard power-off, only if shutdown hangs
virsh -c qemu:///system dumpxml <vm>                 # current live domain XML
virsh -c qemu:///system domdisplay <vm>              # SPICE display URI (see remote-desktop.sh to tunnel it)
virsh -c qemu:///system domiflist <vm>               # the VM's network interfaces
virsh -c qemu:///system net-list --all
virsh -c qemu:///system net-dhcp-leases <network>    # e.g. `pbs` - confirm the VM got its expected IP
virsh -c qemu:///system pool-list --all
virsh -c qemu:///system vol-list <pool>
```
The VM, its network and its storage pool/volume are all declared in `pbs.nix` via NixVirt and reconciled on every `nixos-rebuild switch` — treat `virsh define`/`virsh net-define`/manual XML edits as temporary, since the next deploy overwrites them back to what's in the Nix config. Disk-level snapshots (`virsh snapshot-create-as`) aren't managed by NixVirt at all; there is currently no VM-disk-snapshot workflow in this repo, only PBS's own backup/restore of what's running inside the VM.
