{
  config,
  pkgs,
  nixvirt,
  ...
}:

let
  vmName = "pbs";
  vmUuid = "6b9d7d72-2e0f-4d44-8e8d-7e0b6d9c6f42";

  networkName = "pbs";
  networkUuid = "3e5e7c4a-4f47-4e16-ae64-7d7d1d8d9f3b";

  storagePoolName = "pbs-vm";
  storagePoolPath = "/var/lib/libvirt/images";
  storagePoolUuid = "5a9d7c5e-9a6d-4b1d-8f5c-3e6a4c2b7d91";

  storageVolumeName = "pbs.qcow2";
  storageVolumeUuid = "8c3e4f6a-2d91-4b75-9e38-1a6c5d7f204b";

  vmSubnet = "192.168.122";
  vmIp = "${vmSubnet}.10";
  vmGateway = "${vmSubnet}.1";
  vmMac = "52:54:00:50:42:53";

  tailscaleInterface = config.services.tailscale.interfaceName;

  pbsIso = pkgs.fetchurl {
    url = "https://enterprise.proxmox.com/iso/proxmox-backup-server_4.2-1.iso";
    hash = "sha256-L7KZ3qw5KSU3EsnD38kjftvnCvg8iEhGdha3caHVRT4=";
  };
in
{
  # dataset created with:
  #   zfs create tank/pbs
  systemd.services.zfs-pbs-tuning = {
    description = "Tune ZFS parameters for the PBS dataset";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # fails if the dataset doesn't exist (before initial setup)
    # enable atime just to be sure (docs / forums seem to suggest
    # this may be needed)
    script = ''
      ${pkgs.zfs}/bin/zfs set compression=zstd tank/pbs
      ${pkgs.zfs}/bin/zfs set atime=on tank/pbs
      ${pkgs.zfs}/bin/zfs set relatime=on tank/pbs
    '';
  };

  # PBS VM
  imports = [
    nixvirt.nixosModules.default
  ];

  virtualisation.libvirt = {
    enable = true;

    connections."qemu:///system" = {
      networks = [
        {
          definition = nixvirt.lib.network.writeXML {
            name = networkName;
            uuid = networkUuid;

            forward = {
              mode = "open";
            };

            bridge = {
              name = "virbr-pbs";
            };

            ip = {
              address = vmGateway;
              netmask = "255.255.255.0";

              dhcp = {
                range = {
                  start = "${vmSubnet}.100";
                  end = "${vmSubnet}.200";
                };

                host = {
                  mac = vmMac;
                  name = vmName;
                  ip = vmIp;
                };
              };
            };
          };

          active = true;
        }
      ];

      pools = [
        {
          definition = nixvirt.lib.pool.writeXML {
            name = storagePoolName;
            uuid = storagePoolUuid;
            type = "dir";

            target = {
              path = storagePoolPath;
            };
          };

          active = true;

          volumes = [
            {
              definition = nixvirt.lib.volume.writeXML {
                name = storageVolumeName;
                uuid = storageVolumeUuid;

                capacity = {
                  count = 16;
                  unit = "GiB";
                };

                target = {
                  format = {
                    type = "qcow2";
                  };
                };
              };
            }
          ];
        }
      ];

      domains = [
        {
          active = true;

          definition = nixvirt.lib.domain.writeXML (
            let
              base = nixvirt.lib.domain.templates.linux {
                name = vmName;
                uuid = vmUuid;

                memory = {
                  count = 4;
                  unit = "GiB";
                };

                vcpu = {
                  count = 2;
                };

                storage_vol = {
                  pool = storagePoolName;
                  volume = storageVolumeName;
                };

                install_vol = "${pbsIso}";

                virtio_video = false;
              };
            in
            base
            // {
              # boot from the hdd first, to ensure the VM boots into PBS after
              # it has been installed from the ISO
              os = base.os // {
                boot = [
                  { dev = "hd"; }
                  { dev = "cdrom"; }
                ];
              };

              memoryBacking = {
                source = {
                  type = "memfd";
                };

                access = {
                  mode = "shared";
                };
              };
              devices = base.devices // {
                graphics = {
                  type = "spice";

                  autoport = true;

                  listen = {
                    type = "address";
                    address = "127.0.0.1";
                  };

                  gl = {
                    enable = false;
                  };
                };

                filesystem = [
                  {
                    type = "mount";
                    accessmode = "passthrough";

                    driver = {
                      type = "virtiofs";
                    };

                    source = {
                      dir = "/tank/pbs";
                    };

                    target = {
                      dir = "pbs-datastore";
                    };
                  }
                ];

                interface = [
                  {
                    type = "network";

                    mac = {
                      address = vmMac;
                    };

                    source = {
                      network = networkName;
                    };

                    model = {
                      type = "virtio";
                    };
                  }
                ];
              };
            }
          );
        }
      ];
    };
  };
  # the VM is started automatically (active = true above); check it with
  #   virsh -c qemu:///system list --all
  #
  # if it is somehow shut down, start it with
  #   virsh -c qemu:///system start pbs
  # and check
  #   virsh -c qemu:///system list
  #
  # find the spice display with
  #   virsh -c qemu:///system domdisplay pbs
  #
  # from your working machine, run
  #   ssh -L 5900:127.0.0.1:5900 root@offsite-backup.vpn
  # and connect to the tunnelled display with
  #   hosts/offsite-backup/remote-desktop.sh
  # when installing, ENSURE THE VM IP AND GATEWAY ARE SET CORRECTLY
  # boot order is hd then cdrom, so once PBS is installed it boots straight
  # from hd on its own (a blank hd is skipped, falling through to cdrom)
  #
  # You may need to run
  #   printf 'search home\nnameserver 192.168.122.1\n' > /etc/resolv.conf
  # to fix DNS issues after install
  #
  # Initialize the system with the post-install script at
  #   https://community-scripts.org/scripts/post-pbs-install
  # and configure the tank/pbs datastore as a datastore for PBS by running
  # the following:
  #   mkdir -p /mnt/datastore
  #   echo 'pbs-datastore /mnt/datastore virtiofs defaults,nofail 0 0' >> /etc/fstab
  #   systemctl daemon-reload && mount /mnt/datastore
  #   proxmox-backup-manager datastore create offsite /mnt/datastore
  #
  # this will create a datastore called 'offsite'.
  #
  # To set up the syncing, tailscale needs to be installed on the local pbs host
  #   curl -fsSL https://tailscale.com/install.sh | sh
  # from https://tailscale.com/docs/install/linux
  #
  # Create an offsite backup user on the local PBS for the sync with
  #   proxmox-backup-manager user create offsite@pbs
  #   proxmox-backup-manager user generate-token offsite@pbs sync    # secret is shown once
  #   proxmox-backup-manager acl update /datastore/<MAIN_STORE> DatastoreReader --auth-id offsite@pbs
  #   proxmox-backup-manager acl update /datastore/<MAIN_STORE> DatastoreReader --auth-id 'offsite@pbs!sync'
  #   proxmox-backup-manager cert info | grep Fingerprint
  #
  # The role goes on both the user and the token, because a token can't have more privileges
  # than its user. A sync job can only sync backup groups that the remote's user or token is
  # able to read, so the reader role is what lets it see everything.
  # https://pbs.proxmox.com/docs-3/managing-remotes.html
  #
  # Create the remote in the web UI at "Remotes" and the sync job at
  # "Datastore > offsite > Sync Jobs > Add > Add Pull Job"

  virtualisation.libvirtd.qemu.vhostUserPackages = [
    pkgs.virtiofsd
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/libvirt/images 0755 root root -"
  ];

  # enable forwarding
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.nftables.enable = true;
  networking.nftables.ruleset = ''
    table ip pbs_nat {
      chain prerouting {
        type nat hook prerouting priority dstnat;
        policy accept;

        iifname "${tailscaleInterface}" tcp dport 8007 dnat to ${vmIp}:8007;
      }

      chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;

        ip saddr ${vmSubnet}.0/24 oifname != "virbr-pbs" masquerade;
      }
    }
  '';

  networking.firewall = {
    filterForward = true;

    trustedInterfaces = [
      "virbr-pbs"
    ];

    extraForwardRules = ''
      iifname "virbr-pbs" oifname != "virbr-pbs" accept
      oifname "virbr-pbs" ct state established,related accept
      iifname "${tailscaleInterface}" ip daddr ${vmIp} tcp dport 8007 accept
    '';
  };
}
