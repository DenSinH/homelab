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
              mode = "nat";
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
  #   nix shell nixpkgs#virt-viewer
  #   remote-viewer spice://127.0.0.1:5900
  # when installing, ENSURE THE VM IP AND GATEWAY ARE SET CORRECTLY
  # boot order is hd then cdrom, so once PBS is installed it boots straight
  # from hd on its own (a blank hd is skipped, falling through to cdrom)

  virtualisation.libvirtd.qemu.vhostUserPackages = [
    pkgs.virtiofsd
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/libvirt/images 0755 root root -"
  ];

  networking.nftables.enable = true;
  networking.nftables.ruleset = ''
    table ip pbs_nat {
      chain prerouting {
        type nat hook prerouting priority dstnat;
        policy accept;

        tcp dport 8007 dnat to ${vmIp}:8007;
      }
    }
  '';

  networking.firewall = {
    filterForward = true;

    trustedInterfaces = [
      "virbr-pbs"
    ];

    extraForwardRules = ''
      iifname "${tailscaleInterface}" ip daddr ${vmIp} tcp dport 8007 accept
    '';
  };
}
