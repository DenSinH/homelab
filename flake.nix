{
  description = "Homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      mkLxc = import ./lib/mkLxc.nix {
        inherit nixpkgs;
      };
    in
    {
      nixosConfigurations = {
        bhole = mkLxc {
          hostname = "bhole";
          ip = "192.168.50.215";

          modules = [
            ./hosts/bhole/hardware-configuration.nix
            ./modules/pihole.nix
          ];
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
