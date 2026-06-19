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
        inherit nixpkgs pkgs;
      };

      lxcHosts = {
        ahole = mkLxc {
          hostname = "ahole";
          ip = "192.168.50.2";
          ctid = 109;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        bhole = mkLxc {
          hostname = "bhole";
          ip = "192.168.50.3";
          ctid = 204;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        chole = mkLxc {
          hostname = "chole";
          ip = "192.168.50.4";
          ctid = 311;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };

        subnet-router = mkLxc {
          hostname = "subnet-router";
          ip = "192.168.50.8";
          ctid = 113;

          modules = [
            ./modules/subnet-router.nix
          ];
        };
      };
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs (_: host: host.system) lxcHosts;

      apps.${system} =
        let
          callScript = path: pkgs.callPackage path { inherit lxcHosts; };
        in
        {
          tailscale-login = {
            type = "app";
            program = toString (callScript ./scripts/tailscale-login.nix);
          };

          deploy = {
            type = "app";
            program = toString (callScript ./scripts/deploy.nix);
          };
        };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
