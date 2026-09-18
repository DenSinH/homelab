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

If the new LXC needs an IP in the "services" network range, you will need to redeploy the router first in order for it to accept the mac address for the configured IP.

## Creating a new physical NixOS host

After installing the machine, enable the following line in `/etc/nixos/configuration.nix`:
```nix
services.openssh.enable = true;
```
and do a rebuild switch with
```bash
sudo nixos-rebuild switch
```
Get the new host's IP with `ip a` and you should be able to ssh from your main machine, which makes the process a little bit easier.
From SSH, edit `/etc/nixos/configuration.nix` again and add
```nix
nix.settings.trusted-users = [ "<username>" ]; 
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```
to enable flakes and allow your base user account to push packages into the nix store. Rebuild switch again with
```bash
sudo nixos-rebuild switch
```

Create a new folder in `hosts`, and get the hardware info of the target machine with
```bash
nixos-generate-config --show-hardware-config
```
and put it in the `hardware-configuration.nix`. Create a `default.nix` and start from
```nix
{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common/default.nix
  ];

  # possibly copy over some values from `/etc/nixos/configuration.nix`
  # for example bootloader stuff:
  #   boot.loader.grub.enable = true;
  #   boot.loader.grub.device = "/dev/nvme0n1";
  #   boot.loader.grub.useOSProber = true;

  networking.hostName = <fill in>;

  system.stateVersion = <fill in>;
}
```
and possibly copy over some configuration from the default `/etc/nixos/configuration.nix` if you want to.

For your first (subsequent) deploy, you may not be able to ssh as root, so you may have to run
```bash
nixos-rebuild switch --flake .#<system> --target-host <username>@<ip> --sudo --ask-sudo-password
```
and now you can edit your system and push like normal!

## Secrets

Secrets are managed with `sops-nix`. The (age) `keys.txt` file is expected to be at
```
/var/lib/sops-nix/keys.txt
```
and may have to be provisioned to any hosts using it.

If you add a new age key to a secret group, you will need to run
```bash
sops updatekeys secrets/telemetry.yaml
```
to update the keys listed to have access for the given secrets file.

To retrieve the (ssh derived) age key from a new LXC (printed when running `/etc/init-lxc.sh`, you can run)
```bash
nix-shell -p ssh-to-age --run "ssh-to-age -i \"/etc/ssh/ssh_host_ed25519_key.pub\""
```

## Deploying

For one or more LXCs, run
```bash
nix run .#deploy -- <lxc-name> <lxc-name>
```

To deploy all LXCs, run
```bash
nix run .#deploy -- all
```

For the NAS, run
```bash
nixos-rebuild switch --flake .#nas --target-host root@nas.home --sudo
```

For the router, run
```bash
nixos-rebuild switch --flake .#router --target-host root@router.home --sudo
```

For the offsite backup, run
```bash
nixos-rebuild switch --flake .#offsite-backup --target-host root@offsite-backup.vpn --sudo
```
