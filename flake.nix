{
  description = "Homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
      nixflix,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      hosts = {
        proxmox1 = {
          hostname = "proxmox1.home";
          ip = "192.168.50.11";
          mac = "6c:4b:90:5a:74:19";
          ctidRange = {
            min = 100;
            max = 199;
          };
        };

        proxmox2 = {
          hostname = "proxmox2.home";
          ip = "192.168.50.12";
          mac = "6c:4b:90:5a:73:9d";
          ctidRange = {
            min = 200;
            max = 299;
          };
        };

        proxmox3 = {
          hostname = "proxmox3.home";
          ip = "192.168.50.13";
          mac = "e0:51:d8:1b:fb:9c"; # e0:51:d8:1b:fb:9b unused
          ctidRange = {
            min = 300;
            max = 399;
          };
        };
      };

      storage = {
        nas = {
          hostname = "nas";
          ip = "192.168.50.20";
          mac = "34:64:a9:9a:44:bc";
        };
      };

      lxcs = {
        ahole = {
          hostname = "ahole";
          ip = "192.168.50.2";
          mac = "bc:24:11:4e:81:b0";
          pveHost = "proxmox1";
          ctid = 109;

          stateVersion = "26.05";

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        bhole = {
          hostname = "bhole";
          ip = "192.168.50.3";
          mac = "bc:24:11:7d:98:4a";
          pveHost = "proxmox2";
          ctid = 204;

          stateVersion = "26.05";

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        chole = {
          hostname = "chole";
          ip = "192.168.50.4";
          mac = "bc:24:11:f1:b2:39";
          pveHost = "proxmox3";
          ctid = 311;

          stateVersion = "26.05";

          modules = [
            ./modules/pihole.nix
            ./modules/tailscale.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        cloudflared = {
          hostname = "cloudflared";
          ip = "192.168.50.9";
          mac = "bc:24:11:2f:5f:8b";
          pveHost = "proxmox1";
          ctid = 115;

          stateVersion = "26.05";

          modules = [
            ./modules/cloudflared.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        subnet-router = {
          hostname = "subnet-router";
          ip = "192.168.50.8";
          mac = "bc:24:11:d4:c8:f5";
          pveHost = "proxmox1";
          ctid = 113;

          stateVersion = "26.05";

          modules = [
            ./modules/subnet-router.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        telemetry = {
          hostname = "telemetry";
          ip = "192.168.50.34";
          mac = "bc:24:11:d6:ef:b6";
          pveHost = "proxmox1";
          ctid = 114;

          stateVersion = "26.05";

          modules = [
            ./modules/telemetry/default.nix
          ];
        };

        gatus = {
          hostname = "gatus";
          ip = "192.168.50.35";
          mac = "bc:24:11:a5:a6:f0";
          pveHost = "proxmox1";
          ctid = 100;

          stateVersion = "26.05";

          modules = [
            ./modules/gatus/default.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        immich = {
          hostname = "immich";
          ip = "192.168.50.36";
          mac = "bc:24:11:a9:1a:9c";
          tailnet_ip = "100.100.52.120";
          pveHost = "proxmox3";
          ctid = 307;

          stateVersion = "26.05";

          modules = [
            ./modules/igpu.nix
            ./modules/immich.nix
            ./modules/tailscale.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        vaultwarden = {
          hostname = "vaultwarden";
          ip = "192.168.50.37";
          mac = "bc:24:11:e1:2e:dd";
          tailnet_ip = "100.119.210.127";
          pveHost = "proxmox1";
          ctid = 116;

          stateVersion = "26.05";

          modules = [
            ./modules/vaultwarden.nix
            ./modules/tailscale.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        cookbook = {
          hostname = "cookbook";
          ip = "192.168.50.38";
          mac = "bc:24:11:57:fc:da";
          pveHost = "proxmox1";
          ctid = 105;

          stateVersion = "26.05";

          modules = [
            ./modules/cookbook/default.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        blog = {
          hostname = "blog";
          ip = "192.168.50.39";
          mac = "bc:24:11:34:1b:83";
          pveHost = "proxmox1";
          ctid = 101;

          stateVersion = "26.05";

          modules = [
            ./modules/blog.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        nixflix = {
          hostname = "nixflix";
          ip = "192.168.50.40";
          mac = "bc:24:11:0f:2d:1a";
          tailnet_ip = "100.84.251.29";
          pveHost = "proxmox3";
          ctid = 312;

          stateVersion = "26.05";

          modules = [
            ./modules/nixflix/default.nix
            ./modules/telemetry/alloy.nix
          ];
        };

        dawarich = {
          hostname = "dawarich";
          ip = "192.168.50.41";
          tailnet_ip = "100.90.160.73";
          mac = "bc:24:11:cc:e8:e7";
          pveHost = "proxmox1";
          ctid = 106;

          stateVersion = "26.05";

          modules = [
            ./modules/tailscale.nix
            ./modules/dawarich.nix
          ];
        };

        garage = {
          hostname = "garage";
          ip = "192.168.50.42";
          mac = "bc:24:11:27:a7:95";
          pveHost = "proxmox1";
          ctid = 108;

          stateVersion = "26.05";

          modules = [
            ./modules/garage
          ];
        };
      };

      # make hosts and lxcs globally accessible
      lib = nixpkgs.lib.extend (
        final: prev: {
          hosts = hosts;
          lxcs = lxcs;
          storage = storage;
          admin = {
            ssh_keys = [
              # master key
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPr33f0ptFpGkZbsMcUkAeON5m6aqOHcVg046jiy320N"
              # laptop
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq2MnvCGfq5BvLzpxEcITRpMaNZ+ERlKP6+ecbb6LWb git@dennishilhorst.nl"
              # work laptop
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1OABl55HC7R+kgK7mQJhckQc5lUjdRHZ/8KifNM8l8 nixos@nixos"
            ];
          };
        }
      );

      mkLxc = import ./lib/mkLxc.nix {
        inherit
          nixpkgs
          pkgs
          nixflix
          sops-nix
          lib
          ;
      };
    in
    {
      nixosConfigurations = {
        nas = nixpkgs.lib.nixosSystem {
          system = system;

          specialArgs = {
            # pass through lxc data
            inherit lib;
          };

          modules = [
            sops-nix.nixosModules.sops
            ./hosts/nas/default.nix
          ];
        };

        router = nixpkgs.lib.nixosSystem {
          system = system;

          specialArgs = {
            # pass through lxc data
            inherit lib;
          };

          modules = [
            ./hosts/router/default.nix
          ];
        };
      }
      // nixpkgs.lib.mapAttrs (_: host: mkLxc host) lib.lxcs;

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
