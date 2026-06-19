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

      apps.${system} = {
        tailscale-login = {
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
        deploy = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "deploy" ''
              set -euo pipefail

              RED='\033[1;31m'
              YELLOW='\033[1;33m'
              GREEN='\033[1;32m'
              RESET='\033[0m'

              host="$1"

              case "$host" in
                ${builtins.concatStringsSep "\n" (
                  map (name: ''
                    ${name})
                      ip="${lxcHosts.${name}.meta.ip}"
                      ctid="${toString lxcHosts.${name}.meta.ctid}"
                    ;;
                  '') (builtins.attrNames lxcHosts)
                )}
                *)
                  printf "''${RED}Unknown host: $host\n''${RESET}"
                  exit 1
                  ;;
              esac

              printf "Deploying to $host (IP=$ip, CTID=$ctid)\n"
              printf "Checking remote CTID...\n"

              actual="$(
                ssh root@$ip '
                  cat /proc/self/mountinfo \
                  | sed -n "s#.*pve-vm--\\([0-9]\\+\\)--disk--0.*#\\1#p" \
                  | head -n1
                '
              )"

              if [ -z "$actual" ]; then
                printf "''${RED}ERROR: Could not determine CTID from remote system\n''${RESET}"
                exit 1
              fi

              if [ "$actual" != "$ctid" ]; then
                printf "''${RED}ERROR: CTID mismatch\n''${RESET}"
                printf "''${YELLOW}Expected: %s''${RESET}\n" "$ctid"
                printf "''${YELLOW}Actual:   %s''${RESET}\n" "$actual"
                exit 1
              fi

              printf "''${GREEN}CTID OK, deploying to %s@%s... ''${RESET}\n" "$actual" "$ip"

              nixos-rebuild switch \
                --flake ".#$host" \
                --target-host root@$ip
            ''
          );
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
