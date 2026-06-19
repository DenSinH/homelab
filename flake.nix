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

      lxcHosts = {
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

        subnet-router = mkLxc {
          hostname = "subnet-router";
          ip = "192.168.50.8";

          modules = [
            ./modules/subnet-router.nix
          ];
        };
      };
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs (_: host: host.system) lxcHosts;

      apps.${system}.tailscale-login = {
        type = "app";
        program = toString (
          pkgs.writeShellScript "tailscale-login" ''
            set -euo pipefail

            host="$1"

            case "$host" in
              ${builtins.concatStringsSep "\n" (
                map (
                  name:
                  let
                    ip = lxcHosts.${name}.meta.ip;
                  in
                  "${name}) ip=${ip} ;;"
                ) (builtins.attrNames lxcHosts)
              )}
              *)
                echo "Unknown host: $host"
                exit 1
                ;;
            esac

            ssh -t root@$ip tailscale login && reboot
          ''
        );
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
