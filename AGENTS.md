# AGENTS.md

Guidance for AI coding agents working in this repository. For human-oriented setup/deploy
instructions see [README.md](README.md); for incident response see [docs/RECOVERY.md](docs/RECOVERY.md).

## What this repo is

A NixOS flake defining every machine in a home lab: three Proxmox hosts running LXC
containers, a bare-metal router, a bare-metal NAS, and an offsite backup host. Everything
is declarative — there is no config drift to reason about, only what's in this repo.

## Layout

| Path | Contents |
|---|---|
| `homelab.nix` | Single source of truth for topology: `hosts`, `lxcs`, `router` (incl. its dnsmasq/nftables device lists), `storage`, `backup`, `admin` keys, `lan` (subnet/CIDR/IP-range table), and per-host `provision` flags that drive Ansible. Imports `devices.nix`. |
| `devices.nix` | Known non-flake LAN devices (phones, IoT, etc.), keyed by name, validated against `lan.ranges`. |
| `flake.nix` | Imports `homelab.nix`, builds the extended `lib` and `nixosConfigurations`, defines `apps` (deploy/provisioning scripts) and `devShells`. |
| `hosts/<name>/` | Full NixOS configs for the three non-LXC machines: `nas`, `router`, `offsite-backup`. Each has its own `default.nix`, `hardware-configuration.nix`, and often a `README.md` with machine-specific notes. |
| `modules/` | Reusable NixOS modules, mostly one per LXC service (`vaultwarden.nix`, `paperless.nix`, ...) or a directory when a service needs multiple files (`modules/cookbook/`, `modules/garage/`, `modules/reporting/`). `modules/common/` (incl. `firewall.nix`, the egress/ingress mechanism) and `modules/host/`/`modules/lxc/` are the base layers every machine imports. |
| `lib/` | Nix helper functions: `mkLxc.nix` builds an LXC `nixosSystem` from a `homelab.nix` entry; `hardenedService.nix` is the shared systemd sandboxing baseline for self-written services. |
| `scripts/` | Nix-wrapped shell apps exposed via `nix run .#<name>` (deploy, tailscale login, igpu/proxmox config, security report, Ansible provisioning). |
| `secrets/` | `sops-nix`-encrypted secrets, one YAML file per service/host. `.sops.yaml` (repo root) maps each file to the age keys allowed to decrypt it. |
| `ansible/` | Playbooks/roles for the three Proxmox hosts themselves — never the LXCs/VMs they host, which stay NixOS-managed. See **Ansible / Proxmox provisioning** below. |
| `docs/` | Freeform operational writeups: disaster recovery runbook, hardware migration logs. |

Two hosts also carry their own `README.md` with context that isn't derivable from the Nix
alone: [hosts/router/README.md](hosts/router/README.md) (LAN topology, why no VLANs, the IP
range convention below, AP setup) and
[hosts/offsite-backup/README.md](hosts/offsite-backup/README.md) (ZFS pool bring-up, the PBS
VM's setup/network details). Read the relevant one before changing that host.

## How a machine is defined

- **LXCs** are declared as data in `homelab.nix` under `lxcs = { ... }` (hostname, ip, mac,
  `pveHost`, `ctid`, `stateVersion`, `modules = [...]`, optional `provision = {...}`).
  `lib/mkLxc.nix` turns each entry into a full `nixosSystem`, wiring in sops, static
  networking, and the listed modules. `ctid` must fall inside the owning Proxmox host's
  `ctidRange` — enforced by an assertion in `mkLxc.nix`.
- **Bare-metal hosts** (`nas`, `router`, `offsite-backup`) are defined directly in
  `nixosConfigurations` in `flake.nix`, pointing at `hosts/<name>/default.nix`.
- Every machine pulls in `modules/common/default.nix` (timezone, locale, SSH, base packages,
  journald limits, egress/ingress firewall) either directly or via `modules/lxc/default.nix` /
  `modules/host/default.nix`.
- A global extended `lib` (see `flake.nix`, sourced from `homelab.nix`) exposes `lib.lan`,
  `lib.hosts`, `lib.lxcs`, `lib.router`, `lib.storage`, `lib.backup`, `lib.devices`,
  `lib.admin.ssh_keys`, and `lib.hardenedService` to every module.

## Conventions

- **Hardening**: self-written systemd services should start from `lib.hardenedService` (a set
  of `systemd.service.<name>.serviceConfig` options) and `removeAttrs`/override only what that
  specific service needs, rather than hand-rolling sandboxing. See `modules/host/default.nix`
  (powertop) for the override pattern, and the comment in `lib/hardenedService.nix` for what
  each option does.
- **Secrets**: never put plaintext credentials in a module. Add them to the relevant
  `secrets/<name>.yaml` via `sops edit secrets/<name>.yaml`, reference them in the module with
  `sops.secrets."<key>"` / `config.sops.secrets."<key>".path`, and add a `path_regex` +
  `key_groups` entry in `.sops.yaml` if it's a new file. After adding a new age key to a group,
  run `sops updatekeys secrets/<name>.yaml`.
- **Formatting**: `nixfmt-tree` is the repo formatter (`formatter.${system}` in `flake.nix`).
  Run `nix fmt` before committing Nix changes.
- **Comments — keep them short. This is a hard rule, not a suggestion.** One line, maybe two,
  never a paragraph. Only write one at all if it explains something the code can't: a hidden
  constraint, a workaround, *why* a choice was made. Never restate what the code already says,
  never narrate implementation history or background — that belongs in a commit message, not
  the file. Before adding a comment, ask whether a reader would lose anything if you deleted it;
  if not, delete it. This has been raised multiple times — treat any 3+ line comment you're
  about to write as a sign to cut it down before, not after, you're told to.
- **New LXC service checklist**: create `modules/<service>.nix` (or a directory), add an entry
  under `lxcs` in `homelab.nix` with the next free IP/MAC/ctid in the owning Proxmox host's
  range, pick a `stateVersion` matching other recent entries, list the needed modules, and (if
  it needs tailscale) include `./modules/tailscale.nix`. Then follow the "Creating a new LXC"
  steps in [README.md](README.md) to actually provision it.
- **Egress/ingress firewall**: `modules/common/firewall.nix` defines `homelab.egress`
  (`enable`/`allowLan`/`allowed` — blocks outbound LAN by default, WAN is always open) and
  `homelab.ingress` (`enable`/`blockIot`/`allowTailscale`/`allowed` — blocks iot/other-LXC
  inbound by default). `modules/lxc/default.nix` sets `ingress.blockIot = mkDefault true` for
  every LXC; a module adds `allowed` entries for specific LAN dependencies (NAS, garage,
  telemetry, ...). Not yet applied to `telemetry`/`reporting` ingress beyond `blockIot` (needs a
  per-source audit) or to any bare-metal host — don't assume it's universal.
- **Networking**: static IPs/MACs live in `homelab.nix`'s `lib.hosts`/`lib.lxcs`/`devices.nix`
  and are the source of truth; DHCP reservations on the router come from the same data. The
  "services" IP range requires redeploying the router before a new MAC will get its address.
  The `192.168.50.0/24` LAN is carved into purpose-based ranges, defined as real data in
  `homelab.nix`'s `lib.lan.ranges` (see [hosts/router/README.md](hosts/router/README.md) for
  the human-readable version) — pick a new IP from the right one:

  | Range | Who |
  |---|---|
  | `.1`–`.9` | net (DNS, subnet router, cloudflared) |
  | `.10`–`.19` | compute (Proxmox nodes, PBS) |
  | `.20`–`.29` | storage (NAS) |
  | `.30`–`.49` | services (self-hosted LXC services — most new LXCs go here) |
  | `.50`–`.99` | IoT |
  | `.100`–`.199` | dynamic/unrecognized |
  | `.200`–`.254` | other fixed/known devices |
- **HTTPS**: pihole resolves `<hostname>` in every `lib.lan.domains` zone for every LXC
  (`.home.hlhrst.nl` → LAN IP, `.vpn.hlhrst.nl` → tailnet IP, `.hlhrst.nl` → tailnet IP if any, else LAN).
  A service module sets `homelab.https.enable = true` to get a Let's Encrypt cert (DNS-01, token in
  `secrets/acme.yaml`) and merges `config.homelab.https.vhost` into its nginx vhost (HTTPS only);
  :80 only redirects to HTTPS. Tunneled services set `tunnel = true` and use `tunnelVhost`, adding
  plain HTTP on `lib.lan.tunnelPort` for cloudflared only (its upstreams use that port, never :80).
  `extraNames` must also go in `aliases` in `modules/pihole.nix`. Add the LXC's
  age key to `acme.yaml`'s `.sops.yaml` rule, then `sops updatekeys secrets/acme.yaml`.
- **nftables**: use `networking.nftables.tables`, never `.ruleset` — a ruleset turns on
  `flushRuleset`, which wipes tailscaled's rules on every reload. Exception: the router's ruleset
  owns every table there (no tailscale), so its flush is harmless.
- **Monitoring**: `modules/gatus/config.yaml` is a manually maintained list of uptime-check
  endpoints shown on the status page. Add an entry there if a new service should be monitored —
  it isn't automatic.

## Ansible / Proxmox provisioning

- `ansible/` only ever targets the three Proxmox hosts, never the LXCs/VMs they run. Roles so
  far: `pve_firewall` (host firewall via ipsets), `pve_powertop`, `pve_unattended_upgrades`,
  `pve_ssd_optimization`, `pve_console_powersave`, `pve_cpu_governor` (opt-out, defaults to
  `true` unlike every other flag here), `pve_pvestatd_autorestart`, `pve_vmid_range` (no flag,
  always applied - derived from each host's mandatory `ctidRange`), `pve_grafana_kiosk`
  (proxmox3 only; display hardware specifics live in the role's own defaults, not
  `homelab.nix`, since they aren't topology).
- Each role is gated per-host by `homelab.nix`'s `hosts.<name>.provision.<flag>`
  (`powertop`/`autoUpdates`/...), turned into an Ansible hostvar by
  `scripts/provision-proxmox.nix`, checked via `when:` in `ansible/playbooks/site.yml`. Add a
  new flag there, not a hardcoded `enable: true` in the role.
- Proxmox ipsets (used by `pve_firewall`) accept only individual IPs/CIDRs, never hyphenated
  ranges — `lib.lan.rangeIps` enumerates individual IPs for exactly this reason.
- `/etc/pve` (pmxcfs) rejects Ansible's normal `copy`/`template` writes; `pve_firewall` uses
  `tee` instead (see its `tasks/main.yml`).
- `nft`/Proxmox rule syntax needs a `dport`/`meta l4proto` qualifier — a bare `tcp accept` or
  `udp accept` is a syntax error, not a no-op. This has caused a real lockout before; verify
  generated rules (`nft --check` at NixOS build time, or `pve-firewall compile` on the host).
- `--check` does **not** exercise `shell`/`command` tasks (Ansible skips them in check mode) —
  it is not a reliable dry-run for `pve_firewall`. Test on `proxmox3` before `proxmox1`/`2`, and
  keep console/KVM access open when applying firewall changes for real.

## Making changes safely

- This repo controls real infrastructure. A bad `nixos-rebuild switch` can take down a service
  or (for the router/NAS) the whole LAN or data redundancy.
- There is no CI in this repo (no `.github/`, no pre-commit hooks). `nix flake check` and
  `nixos-rebuild build --flake .#<name>` are the only automated validation available, and an
  agent must run them itself rather than relying on a pipeline to catch mistakes.
- `nix run .#deploy -- <lxc-name>` (`scripts/deploy.nix`) SSHes in and cross-checks the live
  container's actual CTID (read from its mountinfo) against the CTID in `flake.nix` before
  deploying, aborting on a mismatch. That abort means the flake and the running container
  disagree about identity — treat it as a real safety stop, not a transient bug, and resolve the
  mismatch before retrying.
- Prefer `nixos-rebuild build --flake .#<name>` or `nix flake check` to validate before any
  `switch` is suggested, and always confirm with the user before running a `switch`/`deploy`
  against a real host — these are not reversible in the way a local file edit is.
- Same caution applies to `nix run .#provision-proxmox` — see **Ansible / Proxmox
  provisioning** above for its specific gotchas. Confirm with the user before any non-`--check`
  run, and apply to a single host before `all`.
- For anything touching ZFS pools/datasets (`hosts/nas/zfs.nix`, `hosts/offsite-backup/zfs.nix`)
  or replication (`replication.nix`), read [docs/RECOVERY.md](docs/RECOVERY.md) first — it
  documents which datasets have no second copy and the exact order of operations that avoids
  destroying data.
- Don't delete or rewrite anything under `secrets/` casually; it's encrypted but still the only
  copy of live credentials in this repo.
