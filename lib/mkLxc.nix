{
  nixpkgs,
  ...
}:

{
  hostname,
  ip,
  system ? "x86_64-linux",
  modules ? [ ],
}:

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
    inherit hostname ip;
  };
}
