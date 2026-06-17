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
        ahole = mkLxc {
          hostname = "ahole";
          ip = "192.168.50.2";

          modules = [
            ./hosts/ahole/hardware-configuration.nix
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        bhole = mkLxc {
          hostname = "bhole";
          ip = "192.168.50.3";

          modules = [
            ./hosts/bhole/hardware-configuration.nix
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        chole = mkLxc {
          hostname = "chole";
          ip = "192.168.50.4";

          modules = [
            ./hosts/chole/hardware-configuration.nix
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
