{
  description = "Homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvirt = {
      url = "github:AshleyYakeley/NixVirt";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      sops-nix,
      nixflix,
      nixvirt,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgs-unstable = import nixpkgs-unstable { inherit system; };

      homelab = import ./homelab.nix { lib = nixpkgs.lib; };

      # make the homelab topology globally accessible
      lib = nixpkgs.lib.extend (
        final: prev: {
          inherit (homelab)
            lan
            hosts
            lxcs
            router
            storage
            backup
            admin
            devices
            ;
        }
      );

      mkLxc = import ./lib/mkLxc.nix {
        inherit
          nixpkgs
          pkgs
          pkgs-unstable
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
            host = lib.storage.nas;
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
            host = lib.router;
          };

          modules = [
            ./hosts/router/default.nix
          ];
        };

        offsite-backup = nixpkgs.lib.nixosSystem {
          system = system;

          specialArgs = {
            # pass through lxc data
            inherit lib nixvirt;
            host = lib.backup.offsite-backup;
          };

          modules = [
            sops-nix.nixosModules.sops
            ./hosts/offsite-backup/default.nix
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

          provision-proxmox = {
            type = "app";
            program = toString (callScript ./scripts/provision-proxmox.nix);
          };
        };

      # systemd hardening scores, see modules/common/hardening.nix
      checks.${system} = lib.concatMapAttrs (
        host: sys:
        lib.mapAttrs' (
          unit: check: lib.nameValuePair "hardening-${host}-${unit}" check
        ) sys.config.system.build.hardeningChecks
      ) self.nixosConfigurations;

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            pkgs.sops
            pkgs.age
            pkgs.ssh-to-age
            pkgs.ansible
          ];

          shellHook = ''
            export EDITOR="code --wait"
            export SOPS_EDITOR="code --wait"
            export SOPS_AGE_KEY_FILE="/var/lib/sops-nix/keys.txt"

            echo "Use: sops edit secrets/secrets.yaml"
          '';
        };

        immich-go = pkgs.mkShell {
          packages = [
            pkgs.immich-go
          ];

          # for example:
          # immich-go upload from-folder \
          #  --server=http://192.168.50.36:2283 \
          #  --api-key="$IMMICH_API_KEY" \
          #  --folder-as-album=FOLDER \
          #  /path/to/google-photos-album.zip
          shellHook = ''
            echo "Immich-Go $(immich-go --version)"
            echo "Server: http://${lib.lxcs.immich.ip}:2283"
          '';
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
