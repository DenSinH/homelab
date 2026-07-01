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

      hosts = {
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

      lxcs = {
        ahole = {
          hostname = "ahole";
          ip = "192.168.50.2";
          pveHost = "proxmox1";
          ctid = 109;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };

        bhole = {
          hostname = "bhole";
          ip = "192.168.50.3";
          pveHost = "proxmox2";
          ctid = 204;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };

        chole = {
          hostname = "chole";
          ip = "192.168.50.4";
          pveHost = "proxmox3";
          ctid = 311;

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
          ];
        };

        cloudflared = {
          hostname = "cloudflared";
          ip = "192.168.50.9";
          pveHost = "proxmox1";
          ctid = 115;

          modules = [
            ./modules/cloudflared.nix
          ];
        };

        subnet-router = {
          hostname = "subnet-router";
          ip = "192.168.50.8";
          pveHost = "proxmox1";
          ctid = 113;

          modules = [
            ./modules/subnet-router.nix
          ];
        };

        telemetry = {
          hostname = "subnet-router";
          ip = "192.168.50.34";
          pveHost = "proxmox1";
          ctid = 114;

          modules = [
            ./modules/telemetry/default.nix
          ];
        };

        gatus = {
          hostname = "gatus";
          ip = "192.168.50.35";
          pveHost = "proxmox1";
          ctid = 100;

          modules = [
            ./modules/gatus/default.nix
          ];
        };

        vaultwarden = {
          hostname = "vaultwarden";
          ip = "192.168.50.37";
          pveHost = "proxmox1";
          ctid = 116;

          modules = [
            ./modules/vaultwarden.nix
            ./modules/tailscale.nix
          ];
        };

        immich = {
          hostname = "immich";
          ip = "192.168.50.36";
          pveHost = "proxmox3";
          ctid = 307;

          modules = [
            ./modules/igpu.nix
            ./modules/immich.nix
            ./modules/tailscale.nix
          ];
        };

        blog = {
          hostname = "blog";
          ip = "192.168.50.39";
          pveHost = "proxmox1";
          ctid = 101;

          modules = [
            ./modules/blog.nix
          ];
        };
      };

      # make hosts and lxcs globally accessible
      lib = nixpkgs.lib.extend (
        final: prev: {
          hosts = hosts;
          lxcs = lxcs;
        }
      );

      mkLxc = import ./lib/mkLxc.nix {
        inherit
          nixpkgs
          pkgs
          sops-nix
          lib
          ;
      };
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs (_: host: mkLxc host) lib.lxcs;

      apps.${system} =
        let
          callScript = path: pkgs.callPackage path { inherit lib; };
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

          config-igpu = {
            type = "app";
            program = toString (callScript ./scripts/config-igpu.nix);
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
