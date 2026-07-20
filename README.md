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
After a first deploy, it is wise to run 
```bash
/etc/init-lxc.sh
```
from the LXC, it will rotate the SSH key and machine id, as well as generate a derived age key for sops.
It will tell you how to update `.sops.yaml` if you need secrets on this LXC.

## Secrets

Secrets are managed with `sops-nix`. The (age) `keys.txt` file is expected to be at
```
/var/lib/sops-nix/keys.txt
```
and may have to be provisioned to any hosts using it.

## Deploying

For an LXC, run
```bash
nix run .#deploy -- <lxc-name>
```
For the NAS, run
```bash
nixos-rebuild switch --flake .#nas --target-host root@nas.home --sudo
```
