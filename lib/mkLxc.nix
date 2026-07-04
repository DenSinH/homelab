{
  nixpkgs,
  pkgs,
  nixflix,
  sops-nix,
  lib,
  ...
}:

{
  hostname,
  ip,
  ctid,
  pveHost,
  tailnet_ip ? null,
  system ? "x86_64-linux",
  modules ? [ ],
}:

let
  # Validate that pveHost exists
  hostConfig = lib.hosts.${pveHost} or (throw "Unknown Proxmox host: ${pveHost}");

  # Validate CTID is in the correct range
  ctidInRange = ctid >= hostConfig.ctidRange.min && ctid <= hostConfig.ctidRange.max;

  assertion =
    assert
      ctidInRange
      || throw "CTID ${toString ctid} for ${hostname} is not in range ${toString hostConfig.ctidRange.min}-${toString hostConfig.ctidRange.max} for host ${pveHost}";
    true;
in
nixpkgs.lib.nixosSystem {
  system = system;

  # pass through extended lib with access to lxc / pve host configurations
  specialArgs = {
    lib = lib;
  };

  modules = [
    sops-nix.nixosModules.sops
    nixflix.nixosModules.default
    ../modules/common.nix
    ../secrets/default.nix
    ({ ... }: {
      # networking config (fixed IP, hostname)
      networking = {
        defaultGateway = {
          address = "192.168.50.1";
          interface = "eth0";
        };
        hostName = hostname;
        interfaces.eth0.ipv4.addresses = [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
      };
    })
  ]
  ++ modules;
}
