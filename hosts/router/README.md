# APU4D4 NixOS router (flat LAN, MAC-based profiles + Asus APs)

A flake-based NixOS configuration for a 2-NIC APU4D4 router. Originally
scoped around 802.1Q VLANs, but rebuilt around **one flat LAN with
MAC-based static IP profiles**, because the actual downstream gear
(unmanaged switches + Asus RT-AX57/RT-AX55 as APs) can't split or honor
VLAN tags. See "Why not VLANs?" below for the full reasoning.

## Topology

```
        ISP (Odido: ONT, then either their router, or straight to us)
         |
     enp1s0 (WAN, DHCP client, untagged)
     enp1s0.300 (WAN, DHCP client, VLAN 300)  -- see "WAN / ISP replacement"
         |
    +---------+
    |  APU4D4 |
    +---------+
         |
     enp2s0 (single flat LAN, 192.168.50.0/24)
         |
      AX57 (AP)
      SSID: home / guest
      /                        \
  AX55 (AP)              unmanaged 8-port switch
  SSID: home / guest     (multimedia devices)
      |
  unmanaged 8-port switch
  (servers: proxmox, NAS, etc.)
```

Each AX's built-in Guest Network is its own isolated bridge, independent of
the router - see below.

## Why not VLANs?

VLAN tagging is decided *before* traffic reaches the router — by whatever
untags/splits it downstream. That's a managed-switch job. Unmanaged
switches only forward by MAC address; they don't understand 802.1Q tags,
so they can't hand VLAN 10 to one port and VLAN 20 to another. And Asus's
per-SSID VLAN tagging ("Guest Network Pro" / SDN) is only on the
Pro/GT/ExpertWiFi tier, not confirmed on plain RT-AX57/RT-AX55 — check
your own unit's web UI for a "Guest Network Pro" or "SDN" tab (not just
the basic "Guest Network" tab) if you want to verify.

So instead: one flat `192.168.50.0/24`, with devices sorted into IP
*ranges* by convention, populated either statically or by MAC via dnsmasq:

| Range | Addresses | Who | Assignment |
|---|---|---|---|
| net | `.1` – `.9` | DNS (pihole), subnet router, cloudflared | static |
| compute | `.10` – `.19` | proxmox nodes, PBS | static |
| storage | `.20` – `.29` | NAS (both NICs, iLO) | static |
| services | `.30` – `.49` | self-hosted services | dhcp, self-requested IP, MAC-tag gated |
| iot | `.50` – `.99` | IoT devices | dhcp, fixed IP by MAC |
| dynamic (guest-equivalent) | `.100` – `.199` | anything with an unrecognized MAC | dhcp, dynamic pool |
| fixed | `.200` – `.254` | known devices, mixed trust | dhcp, fixed IP by MAC |

### What this does and doesn't get you

**Works, fully enforced:**
- MAC → range assignment (via dnsmasq `dhcp-host`), with automatic
  fallback for unknown MACs — exactly as asked.
- The `services` range is tag-gated (`tag:services` on the dhcp-range,
  `set:services` on each registered MAC), so a service can still pick/keep
  whatever IP it wants inside `.30-49`, but a random unregistered device
  can't just DHCP-request an address in that range.
- Per-range policy for anything that terminates at or transits through
  the router: SSH into the router is allowed from every range *except*
  `net`, `services` and `iot` (so a brand-new device landing in `dynamic`
  can still SSH in); `iot` is blocked from reaching the public internet
  by default (opt in specific devices by setting `wan = true` on their
  entry in `iotHosts`); every other range gets outbound internet.

**Does NOT work, and can't with this hardware:**
- Isolation *between* devices on the same wire. Two devices on the same
  flat LAN reach each other directly at layer 2 (switched, not routed) —
  that traffic never reaches the router's firewall at all. An IoT device
  in the `iot` range can still directly probe a laptop in `fixed` if
  they're on the same switch. The forward-chain rules in `router.nix` are
  real and correct, they just currently only matter for LAN→WAN traffic.
- If you ever want real isolation, the fix is a single inexpensive managed
  switch (~$25–40, e.g. TP-Link TL-SG108E or similar) to properly
  terminate VLAN trunks into separate access ports. At that point this
  config can go back to true `networking.vlans` per-VLAN interfaces —
  ask if you want that version.

## WAN / ISP replacement (Odido)

This config brings up WAN two ways at once, so you can test either without
editing anything - whichever cable is actually connected gets a lease:

- **Behind Odido's own router** (their router's LAN port -> our `enp1s0`):
  a plain, untagged DHCP client. Useful for testing before fully committing.
- **Replacing Odido's router** (straight into their ONT -> our `enp1s0`):
  Odido require VLAN 300 tagged, DHCP - brought up here as `enp1s0.300`.

Background, and why only the *router* is replaced here (not the ONT):
Odido give you two boxes, an ONT ("glasvezel omzetter") and a router. Their
router can't be bridged, so it has to be replaced with your own equipment -
any device that can tag VLAN 300 and DHCP works. The ONT is a different
story: on an AON (point-to-point) line you can replace it with your own
SFP/media converter, but on xPON (GPON <1Gbit, or XGS-PON 2Gbit+) it's
registered to your line and generally can't be swapped (some modules
support cloning its serial number). **Don't connect your own equipment
directly to a GPON line in place of the ONT** - it can take down the fiber
for the whole street. The simple, safe approach - and what this config
assumes - is: keep Odido's ONT, replace only their router.

Source: https://gathering.tweakers.net/forum/list_messages/2206944#eigenhardware

## Setting up the AX57/AX55 as access points

Both routers get flashed into plain AP mode (not gateway/router mode) and
plugged into the flat LAN via a LAN port — never their WAN port.

1. **Factory reset** each unit if it's been used as a gateway before
   (Settings → Administration → Restore/Save/Upload → Restore).
2. Connect to it directly, log into the web UI (`http://router.asus.com`
   or `192.168.1.1` by default).
3. Go to **Administration → Operation Mode** and select **Access Point
   (AP) Mode**. This disables the unit's own DHCP server and NAT — it
   becomes a pure bridge, which is what you want since your NixOS box is
   already doing DHCP/routing.
4. After it reboots into AP mode, it'll request an address from your
   router's dnsmasq — check `192.168.50.100`–`.199` (the dynamic range)
   for it, or add its MAC to `dhcp-host` in `router.nix` to give it a
   stable fixed-range address (recommended, since you'll want to reach
   its admin UI reliably).
5. Connect the AP's **LAN port** (not WAN) to your unmanaged switch/router.
6. Set up your main SSID under **Wireless → General** as usual.
7. For a guest-style network on the same AP: **Wireless → Guest Network**,
   enable a guest SSID, and:
   - Turn **Access Intranet** *off* — this is the AP's own local
     isolation, independent of anything on the router side, and it's the
     one piece of real device-to-device isolation available on this
     hardware without a managed switch.
   - Enable **Wireless client isolation** if offered, so guest devices on
     that SSID can't see each other either.
   - Note this isolates that guest SSID from *this AP's own* bridge only —
     it doesn't know about or interact with the router's ranges at all.
     Treat it as a second, independent layer, not a substitute for the
     router-side MAC assignment.
8. Repeat for the second unit. Give both APs the same SSID/password if you
   want seamless roaming between them (they're both just bridges into the
   same flat LAN, so this works fine without any special mesh setup).

## Before you deploy (NixOS side)

1. **Fix the interface names.** Boot a NixOS live USB on the actual box
   and run `ip link` — edit `wanIf`/`lanIf` at the top of
   `hosts/router/router.nix` accordingly (`wanVlanIf` is derived from
   `wanIf`, no need to touch it separately).
2. **Generate real hardware config.**
   `hosts/router/hardware-configuration.nix` is a stub. Run
   `nixos-generate-config --root /mnt` during install and copy the real
   one over it (see the comment at the top of that file for the full
   serial-console install flow).
3. **Set your boot disk** in `hosts/router/configuration.nix`
   (`boot.loader.grub.device`).
4. **Add your SSH public key** in `hosts/router/configuration.nix` —
   password auth is disabled, so skipping this locks you out.
5. **Fill in `dhcp-host` entries** in `router.nix` with your real devices'
   MAC addresses once you know them (`ip neigh` on the router, or check
   each device's own Wi-Fi/network settings).
6. **Set your timezone** in `configuration.nix`.

## Deploying

From your workstation, once the box is booted off the NixOS installer and
reachable over SSH as root:

```sh
nixos-generate-config --root /mnt     # run on the router itself, then
                                       # copy hardware-configuration.nix out
rsync -av . root@<router-ip>:/etc/nixos/flake-router/
ssh root@<router-ip> "nixos-rebuild switch --flake /etc/nixos/flake-router#router"
```

Prefer `nixos-rebuild test` over `switch` for anything touching
networking — it takes effect immediately but reverts on reboot, so a bad
firewall change doesn't permanently strand you.

## Not included (deliberately out of scope)

- **IPv6.** Both IPv6 chains default-deny for now. Solene's post covers a
  full dual-stack live-USB router setup if you want to add it:
  https://dataswamp.org/~solene/2022-08-03-nixos-with-live-usb-router.html
- **Monitoring (Prometheus/Grafana).** skogsbrus has a ~15-line drop-in:
  https://skogsbrus.xyz/building-a-router-with-nixos/#june-2-add-grafana-monitoring
- **WireGuard remote access.** Also from skogsbrus:
  https://skogsbrus.xyz/building-a-router-with-nixos/#june-26-add-wireguard

## Debugging tips

- `journalctl -u nftables.service` and `nft list ruleset` for the live
  firewall state.
- `journalctl -u dnsmasq.service` and check `/var/lib/dnsmasq/dnsmasq.leases`
  to confirm a device landed in the range you expected.
- If a device isn't getting the static IP you assigned, double check the
  MAC in `dhcp-host` — a typo there just silently falls through to the
  dynamic range, which can look like "it's ignoring my config" when it's
  actually working exactly as designed (unrecognized MAC → dynamic).
- If a "services" device isn't getting an IP in `.30-49` at all, check
  it has a `dhcp-host = "mac,set:services"` entry — without the tag it's
  treated as an unrecognized MAC and refused that range entirely.

## Sources

- tweakers.net forum, *Odido glasvezel: eigen router/ONT gebruiken* (WAN
  VLAN 300, AON vs GPON/XGS-PON, why not to swap your own NT on GPON)
  https://gathering.tweakers.net/forum/list_messages/2206944#eigenhardware
- Solene Rapenne, *NixOS with a live-usb router*
  https://dataswamp.org/~solene/2022-08-03-nixos-with-live-usb-router.html
- Johan (skogsbrus), *Building a Router with NixOS*
  https://skogsbrus.xyz/building-a-router-with-nixos/
- Francis Begyn, *Setting up my own router with NixOS*
  https://francis.begyn.be/blog/nixos-home-router
- Josh Pearce, *DIY Home Router with NixOS*
  https://www.jjpdev.com/posts/home-router-nixos/
- Hardware: PC Engines APU4D4 via TekLager
  https://teklager.se/en/products/routers/apu4d4-open-source-router
- Asus VLAN/Guest Network Pro (SDN) documentation, for reference on what
  your specific model may or may not support:
  https://www.asus.com/support/faq/1049415/
