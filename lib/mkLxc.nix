{
  nixpkgs,
  pkgs,
  proxmoxHosts,
  ...
}:

{
  hostname,
  ip,
  ctid,
  pveHost,
  system ? "x86_64-linux",
  modules ? [ ],
}:

let
  # Validate that pveHost exists
  hostConfig = proxmoxHosts.${pveHost} or (throw "Unknown Proxmox host: ${pveHost}");

  # Validate CTID is in the correct range
  ctidInRange = ctid >= hostConfig.ctidRange.min && ctid <= hostConfig.ctidRange.max;

  assertion =
    assert
      ctidInRange
      || throw "CTID ${toString ctid} for ${hostname} is not in range ${toString hostConfig.ctidRange.min}-${toString hostConfig.ctidRange.max} for host ${pveHost}";
    true;
in
{
  system = nixpkgs.lib.nixosSystem {
    system = system;

    modules = [
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

      ./../modules/common.nix
    ]
    ++ modules;
  };

  meta = {
    inherit
      hostname
      ip
      ctid
      pveHost
      ;
  };
}
