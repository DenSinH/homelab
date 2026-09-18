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

                # default boot hard disk after installation from cdrom is complete
                boot = [
                  { dev = "hd"; }
                  { dev = "cdrom"; }
                ];

                storage_vol = {
                  pool = storagePoolName;
                  volume = storageVolumeName;
                };

                install_vol = "${pbsIso}";

                virtio_drive = true;
                virtio_video = false;
              };
            in
            base
            // {
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
  # after deployment, check if the VM exists with
  #   virsh -c qemu:///system list --all
  #
  # start it with
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
  # and after installing, you may need to remove the installation media
  # by finding it (on the offsite-backup machine) with 
  #   virsh -c qemu:///system domblklist pbs
  # and ejecting it (likely sdc) with
  #   virsh -c qemu:///system change-media pbs sdc --eject
  # 
  # (you may need to shutdown the vm)
  #   virsh -c qemu:///system shutdown pbs
  # or
  #   virsh -c qemu:///system destroy pbs

  virtualisation.libvirtd.qemu.vhostUserPackages = [
    pkgs.virtiofsd
  ];

  environment.systemPackages = [
    pkgs.libvirt
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

      chain output {
        type nat hook output priority dstnat;
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
      iifname "enp0s31f6" ip daddr ${vmIp} tcp dport 8007 accept
      iifname "tailscale0" ip daddr ${vmIp} tcp dport 8007 accept
    '';
  };
}
