# Homelab

NixOS configurations for my homelab.

## Creating a new LXC

Clone the `nixos` LXC template I created. Configure the resource settings and log into it. A first deploy may have to be done to a DHCP-assigned IP (e.g. for `.#subnet-router`):
```bash
nixos-rebuild switch --flake .#subnet-router --target-host root@192.168.50.186 --sudo
```
After a first deploy, the IP address should have been set. Subsequent deploys should be done with the configured IP in `flake.nix`:
```bash
nix run .#deploy -- subnet-router
```

## Secrets

Secrets are managed with `sops-nix`. The (age) `keys.txt` file is expected to be at
```
/var/lib/sops-nix/keys.txt
```
and may have to be provisioned to any hosts using it.

## Todo

Feels like the order of scariness to migrate these:
- Grafana / InfluxDB  (add age key file existence check)
- Cloudflared
- Vaultwarden
- Arr stack
- Immich