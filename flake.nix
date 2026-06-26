{
  description = "Homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Proxmox hosts definitions
      proxmoxHosts = {
        proxmox1 = {
          hostname = "proxmox1.home";
          ip = "192.168.50.11";
          ctidRange = {
            min = 100;
            max = 199;
          };
        };
        proxmox2 = {
          hostname = "proxmox2.home";
          ip = "192.168.50.12";
          ctidRange = {
            min = 200;
            max = 299;
          };
        };
        proxmox3 = {
          hostname = "proxmox3.home";
          ip = "192.168.50.13";
          ctidRange = {
            min = 300;
            max = 399;
          };
        };
      };

      mkLxc = import ./lib/mkLxc.nix {
        inherit
          nixpkgs
          pkgs
          sops-nix
          proxmoxHosts
          ;
      };

      lxcHosts = {
        ahole = mkLxc {
          hostname = "ahole";
          ip = "192.168.50.2";
          pveHost = "proxmox1";
          ctid = 109;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        bhole = mkLxc {
          hostname = "bhole";
          ip = "192.168.50.3";
          pveHost = "proxmox2";
          ctid = 204;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };
        chole = mkLxc {
          hostname = "chole";
          ip = "192.168.50.4";
          pveHost = "proxmox3";
          ctid = 311;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };

        cloudflared = mkLxc {
          hostname = "cloudflared";
          ip = "192.168.50.9";
          pveHost = "proxmox1";
          ctid = 115;

          modules = [
            ./modules/cloudflared.nix
          ];
        };

        subnet-router = mkLxc {
          hostname = "subnet-router";
          ip = "192.168.50.8";
          pveHost = "proxmox1";
          ctid = 113;

          modules = [
            ./modules/subnet-router.nix
          ];
        };

        telemetry = mkLxc {
          hostname = "subnet-router";
          ip = "192.168.50.34";
          pveHost = "proxmox1";
          ctid = 114;

          modules = [
            ./modules/telemetry/default.nix
          ];
        };
      };
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs (_: host: host.system) lxcHosts;

      apps.${system} =
        let
          callScript = path: pkgs.callPackage path { inherit lxcHosts proxmoxHosts; };
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

          config-tun = {
            type = "app";
            program = toString (callScript ./scripts/config-tun.nix);
          };
        };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.sops
          pkgs.age
        ];

        shellHook = ''
          export EDITOR="code --wait"
          export SOPS_EDITOR="code --wait"
          export SOPS_AGE_KEY_FILE="/var/lib/sops-nix/keys.txt"

          echo "Use: sops edit secrets/secrets.yaml"
        '';
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
