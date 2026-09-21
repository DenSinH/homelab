# Disaster recovery

Recovery procedures for the homelab. Host setup, sops and deploy commands follow the [README](./README.md) ("Creating a new physical NixOS host", "Secrets", "Deploying").

## What lives where

| Data | Primary | Other copies |
|---|---|---|
| `tank/drive`, `tank/photos` | NAS `tank` | NAS `backup` pool (`hosts/nas/replication.nix`), offsite `tank` (syncoid pull over the tailnet) |
| Proxmox VM/LXC backups | local PBS | offsite PBS datastore `offsite` (`/tank/pbs` on the offsite host), pulled by a sync job. Some VMs are excluded. |
| Configuration | this repo | any clone |
| Secrets | `secrets/` (sops) | readable only with an age key |

## Rules

1. Find the good copy first (`zpool status -v`, `zfs list -t snapshot`). Do not `zpool create`, `zfs destroy` or `zfs recv -F` until you know which copy is authoritative.
1. Never let an empty or rebuilt side replicate over a good one. Pause the timers (`systemctl list-timers | grep -E 'sanoid|syncoid'`) and PBS sync jobs until the restore is verified.
1. Pool layouts (mirror/raidz) are not recorded here. `zpool status` decides which branch applies.

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

1. Install NixOS on the replacement and add it as in the README. Disks intact: `zpool import -f tank` (or reuse the old `networking.hostId`). Fresh disks: `zpool create tank ...` with the same name and options.
1. Create `tank/pbs` and `chown 34:34 /tank/pbs` (the `backup` user in the guest). Do this before deploying, because the VM's virtiofs share sources that path.
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
1. **`tank` lost, `backup` fine:** pause the timers, create `tank`, then restore from the local copy:
   ```sh
   syncoid --no-sync-snap -r backup/drive-backup tank/drive
   syncoid --no-sync-snap -r backup/photos-backup tank/photos
   ```
   The snapshot history comes along, so NAS → `backup` and offsite replication resume incrementally. Check `zfs get -r readonly,mountpoint tank`, then re-enable the timers.
Create the other remaining datasets as well and run the tuning job.
1. **Both lost:** see section 4, restoring from offsite.

## 4. NAS total failure

1. On the offsite host stop the pull timers (`systemctl stop 'syncoid-*.timer'`) so nothing pulls from a half-restored NAS.
1. Replacement hardware: install NixOS as in the README and provision the age key. **Disks survived:** `zpool import -f tank backup` (or reuse the old `networking.hostId`) and skip to step 4.
1. **Disks lost:** create `tank` and `backup`.
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
1. Verify (`zfs list -t snapshot`, spot-check files), then re-enable NAS sanoid/syncoid (this re-seeds `backup`) and the offsite pull timers. Snapshot history was restored, so the pull is incremental.

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
