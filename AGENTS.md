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
| `flake.nix` | Single source of truth for topology: every host/LXC's hostname, IP, MAC, and which modules it imports. Also defines `apps` (deploy scripts) and `devShells`. |
| `hosts/<name>/` | Full NixOS configs for the three non-LXC machines: `nas`, `router`, `offsite-backup`. Each has its own `default.nix`, `hardware-configuration.nix`, and often a `README.md` with machine-specific notes. |
| `modules/` | Reusable NixOS modules, mostly one per LXC service (`vaultwarden.nix`, `immich.nix`, `paperless.nix`, ...) or a directory when a service needs multiple files (`modules/cookbook/`, `modules/garage/`, `modules/reporting/`). `modules/common/` and `modules/host/` are the base layers every machine imports. |
| `lib/` | Nix helper functions: `mkLxc.nix` builds an LXC `nixosSystem` from a `flake.nix` entry; `hardenedService.nix` is the shared systemd sandboxing baseline for self-written services. |
| `scripts/` | Nix-wrapped shell apps exposed via `nix run .#<name>` (deploy, tailscale login, igpu/proxmox config, security report). |
| `secrets/` | `sops-nix`-encrypted secrets, one YAML file per service/host. `.sops.yaml` (repo root) maps each file to the age keys allowed to decrypt it. |
| `docs/` | Freeform operational writeups: disaster recovery runbook, hardware migration logs. |

Two hosts also carry their own `README.md` with context that isn't derivable from the Nix
alone: [hosts/router/README.md](hosts/router/README.md) (LAN topology, why no VLANs, the IP
range convention below, AP setup) and
[hosts/offsite-backup/README.md](hosts/offsite-backup/README.md) (ZFS pool bring-up, the PBS
VM's setup/network details). Read the relevant one before changing that host.

## How a machine is defined

- **LXCs** are declared as data in `flake.nix` under `lxcs = { ... }` (hostname, ip, mac,
  `pveHost`, `ctid`, `stateVersion`, `modules = [...]`). `lib/mkLxc.nix` turns each entry into
  a full `nixosSystem`, wiring in sops, static networking, and the listed modules. `ctid` must
  fall inside the owning Proxmox host's `ctidRange` — enforced by an assertion in `mkLxc.nix`.
- **Bare-metal hosts** (`nas`, `router`, `offsite-backup`) are defined directly in
  `nixosConfigurations` in `flake.nix`, pointing at `hosts/<name>/default.nix`.
- Every machine pulls in `modules/common/default.nix` (timezone, locale, SSH, base packages,
  journald limits) either directly or via `modules/lxc/default.nix` / `modules/host/default.nix`.
- A global extended `lib` (see `flake.nix`) exposes `lib.hosts`, `lib.lxcs`, `lib.router`,
  `lib.storage`, `lib.backup`, `lib.admin.ssh_keys`, and `lib.hardenedService` to every module.

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
- **New LXC service checklist**: create `modules/<service>.nix` (or a directory), add an entry
  under `lxcs` in `flake.nix` with the next free IP/MAC/ctid in the owning Proxmox host's range,
  pick a `stateVersion` matching other recent entries, list the needed modules, and (if it needs
  tailscale) include `./modules/tailscale.nix`. Then follow the "Creating a new LXC" steps in
  [README.md](README.md) to actually provision it.
- **Networking**: static IPs/MACs live in `flake.nix` and are the source of truth; DHCP
  reservations on the router come from the same data. The "services" IP range requires
  redeploying the router before a new MAC will get its address. The `192.168.50.0/24` LAN is
  carved into purpose-based ranges by convention (see
  [hosts/router/README.md](hosts/router/README.md) for the full picture) — pick a new IP from
  the right one:

  | Range | Who |
  |---|---|
  | `.1`–`.9` | net (DNS, subnet router, cloudflared) |
  | `.10`–`.19` | compute (Proxmox nodes, PBS) |
  | `.20`–`.29` | storage (NAS) |
  | `.30`–`.49` | services (self-hosted LXC services — most new LXCs go here) |
  | `.50`–`.99` | IoT |
  | `.100`–`.199` | dynamic/unrecognized |
  | `.200`–`.254` | other fixed/known devices |
- **Monitoring**: `modules/gatus/config.yaml` is a manually maintained list of uptime-check
  endpoints shown on the status page. Add an entry there if a new service should be monitored —
  it isn't automatic.

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
- For anything touching ZFS pools/datasets (`hosts/nas/zfs.nix`, `hosts/offsite-backup/zfs.nix`)
  or replication (`replication.nix`), read [docs/RECOVERY.md](docs/RECOVERY.md) first — it
  documents which datasets have no second copy and the exact order of operations that avoids
  destroying data.
- Don't delete or rewrite anything under `secrets/` casually; it's encrypted but still the only
  copy of live credentials in this repo.
