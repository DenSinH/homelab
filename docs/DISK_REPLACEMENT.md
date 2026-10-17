# ZFS `tank` migration: 2× 4TB → 2× 8TB HGST Ultrastar He8

**Date:** 2026-10-17
**Host:** `nas` — HP MicroServer Gen8, NixOS, ZFS
**Pool:** `tank` (2-disk mirror, `ashift=12`)

## Summary

Replaced both 4TB disks in the `tank` mirror with second-hand 8TB HGST Ultrastar He8 drives, one disk at a time using `zpool replace`, with only two drives installed at any moment. A third 8TB drive of the same model is kept as a cold spare.

## Hardware

| Device | Role | Notes |
|---|---|---|
| Crucial M4 128GB SSD (`M4-CT128M4SSD2`) | Boot / OS | Not on the pool, so the system boots without `tank` drives |
| Seagate Expansion 1TB (USB) | External | Not part of the pool |
| USB flash disk 15GB | — | Present on internal USB |

## Drive inventory (new drives)

All three: **HGST HUH728080ALE604** (Ultrastar He8), firmware A4GNW907, 512 logical / 4096 physical sectors, SATA 6Gb/s. Bought second-hand.

| Serial | WWN | Power-on hrs | Spindle hrs | Load cycles | Max temp | Role |
|---|---|---|---|---|---|---|
| **VLJKM0LZ** | 0x5000cca260e430b6 | 18,106 | 2,517 | 2,471 | 46°C | **Pool** (replaced first old disk) |
| **VLJN8RGZ** | 0x5000cca260e5672e | 20,584 | 6,272 | 5,375 | 44°C | **Pool** (replaced second old disk) |
| **VLJNTBYY** | 0x5000cca260e5a1f8 | 20,583 | 6,266 | 5,426 | 46°C | **Cold spare** |

SMART findings at time of purchase, all three drives:

- Overall health: PASSED
- Reallocated sectors, reallocated events, pending sectors, offline uncorrectable: **0**
- Reported uncorrectable errors (device statistics): **0**
- UDMA CRC errors / interface CRC errors: **0**
- Helium level: **100**
- Error log: **No errors logged**
- Self-test history: regular short tests by the previous owner, all "Completed without error"
- Short self-test on arrival: passed

### Why this pool/spare split

VLJN8RGZ and VLJNTBYY are effectively twins: near-identical power-on hours, spindle hours, load cycles, I/O totals and self-test schedule. They clearly ran side by side in the same system. VLJKM0LZ came from a different system and has the least wear.

To reduce the risk of correlated failure in the mirror (two drives with identical history failing around the same time, e.g. during a resilver), the pool uses **one twin + VLJKM0LZ**. The other twin is the cold spare.

## Procedure

### 1. Testing the new drives without another PC

The OS lives on the SSD, so the old pool drives were pulled (with the machine powered off, since the Gen8 cage is non-hot-plug) and the new drives tested in their bays.

On boot without the pool drives, NixOS ran a startup job trying to import `tank`. It times out on its own after about a minute. To skip it entirely, add this to the kernel command line at the boot menu (one boot only, no config change):

```
systemd.mask=zfs-import-tank.service
```

Commands used per drive:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/ | grep -v part
smartctl -x /dev/sdX          # full report incl. error log and self-test history
smartctl -t short /dev/sdX    # ~2 minutes
smartctl -l selftest /dev/sdX # check result
```

### 2. Checking the old pool

```bash
zpool status tank
zpool get ashift tank
```

Result: 2-disk mirror, all `ONLINE`, last scrub 2026-10-01 with 0 errors, `ashift=12`.

`ashift=12` means 4096-byte blocks (2¹²), matching the 4K physical sectors of the new drives. An `ashift=9` pool would have required building a new pool and using `zfs send | zfs receive` instead.

Old disks:

| Name in pool | Removed |
|---|---|
| `wwn-0x500003977ba80d9d-part1` | First |
| `wwn-0x500003977bc02117-part1` | Second (holds the most recent pre-migration copy) |

### 3. Replace the first old disk

Since the Gen8 makes it awkward to map bays to serials, the drives weren't identified in advance. Instead: power off, pull either old drive, insert the new one, boot, and let `zpool status` show which disk went missing.

```bash
poweroff
# pull one old drive, label it "tank – removed first", insert VLJKM0LZ, boot
zpool status tank
# showed: 8661423818365294209  UNAVAIL  was /dev/disk/by-id/wwn-0x500003977ba80d9d-part1
wipefs -a /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJKM0LZ
zpool replace tank 8661423818365294209 /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJKM0LZ
zpool status tank   # wait for resilver to complete
```

After the resilver, checks before continuing:

```bash
zpool status tank   # both ONLINE, 0 READ/WRITE/CKSUM, resilvered with 0 errors
smartctl -A /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJKM0LZ | grep -E "Reallocated|Pending|Uncorrectable|CRC"
```

Result: resilver clean; all SMART counters still 0.

### 4. Replace the second old disk

The remaining old disk is in the *other* bay (not the one just filled).

```bash
poweroff
# pull the remaining old drive, label it "tank – removed second", insert VLJN8RGZ, boot
zpool status tank   # note the GUID of the UNAVAIL disk
wipefs -a /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJN8RGZ
zpool replace tank <GUID> /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJN8RGZ
zpool status tank   # wait for resilver to complete
```

Add `-f` to `zpool replace` if it complains about existing partitions.

### 5. Expand and verify

```bash
zpool status tank
zpool list tank     # SIZE should be ~7.2T
```

If the size is still ~3.6T (check the `EXPANDSZ` column):

```bash
zpool set autoexpand=on tank
zpool online -e tank /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJKM0LZ
zpool online -e tank /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJN8RGZ
```

Final scrub:

```bash
zpool scrub tank
zpool status tank   # expect: scrub repaired 0B ... with 0 errors
```

## Risks taken and known uncertainties

- **No pre-migration scrub.** A scrub was started and cancelled. Accepted because the last scrub (2026-10-01) was clean, and a resilver verifies checksums on everything it reads. The removed old disks still hold a copy if a bad block had surfaced.
- **No redundancy during each resilver.** Only two bays were usable, so each replace ran with a single source disk. A failure of that disk during the resilver would have meant falling back to the removed old disk.
- **No long SMART test or burn-in** on the new drives. Only `smartctl -x` and short tests were run; the resilvers and final scrub serve as the practical full-surface check for the space in use. Consider running `smartctl -t long` (~20–22 hours each) at a quiet moment.
- **Short self-test results from the second test session** were read before they had finished and didn't appear in the log yet. Not re-verified.
- **Drives are used, ~2–2.3 years of power-on time.** Healthy now, but wear-out will come sooner than with new drives. Keep an eye on SMART and scrub results.
- **Pool features not upgraded.** `zpool status` reports features that aren't enabled. Left as-is; `zpool upgrade tank` is optional and makes the pool unimportable on older ZFS versions.

## Follow-ups

- [ ] Fit screws in the drive caddies
- [ ] Fill in the Results section above
- [ ] Optional: enable drive write cache (`hdparm -W1 /dev/sdX`); disabled by default on these drives. ZFS issues cache flushes, so this is safe. Does not persist across power cycles; add to NixOS config (udev rule or systemd oneshot).
- [ ] Optional: enable SCT Error Recovery Control (`smartctl -l scterc,70,70 /dev/sdX`) so a drive gives up on a bad sector after 7s and lets ZFS repair it. Also resets on power cycle; add to NixOS config.
- [ ] Optional: run a long SMART test on all three new drives
- [ ] Make sure regular scrubs and SMART monitoring are configured (`services.zfs.autoScrub`, `services.smartd`)
- [ ] Keep the old 4TB drives untouched until the new pool has run for a while. **Never insert them alongside the new drives**: they are members of the same pool and would confuse ZFS. To recover from one, use it on its own.
- [ ] Cold spare VLJNTBYY: store safely; if it replaces a pool disk, `wipefs -a` it and `zpool replace` as above

## Cold spare replacement procedure

If a pool disk fails:

```bash
zpool status tank   # identify the failed disk
poweroff
# swap the failed drive for VLJNTBYY, boot
wipefs -a /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJNTBYY
zpool replace tank <failed-disk-name-or-GUID> /dev/disk/by-id/ata-HGST_HUH728080ALE604_VLJNTBYY
zpool status tank   # wait for resilver, then scrub
```