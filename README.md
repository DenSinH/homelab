# Homelab

NixOS configurations for my homelab.

## Creating a new LXC

Clone the `nixos` LXC template I created. Configure the resource settings and log into it. A first deploy may have to be done to a DHCP-assigned IP (e.g. for `.#subnet-router`):
```bash
nixos-rebuild switch --flake .#chole --target-host root@192.168.50.186 --sudo
```
After a first deploy, the IP address should have been set. Subsequent deploys should be done with the configured IP in `flake.nix`:
```bash
nixos-rebuild switch --flake .#chole --target-host root@192.168.50.8 --sudo
```