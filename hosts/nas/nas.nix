{ config, pkgs, ... }:

{
  # enable ZFS
  boot.supportedFilesystems = [ "zfs" ];

  # root file system is NOT zfs
  boot.zfs.forceImportRoot = false;

  # generate with
  # head -c8 /etc/machine-id
  networking.hostId = "fe7e6f35";

  # after initial import, i.e.
  # check available pools with
  #   zpool list
  # import with
  #   zpool import <pool>
  # rename with
  #   zpool import <pool> tank
  # then we may need to update the mountpoints
  # we can enable the below settings
  # autoload "tank" pool
  boot.zfs.extraPools = [
    "tank"
    "backup"
  ];

  boot.kernelParams = [
    # NAS has 16GB memory, set 12GiB for arc_max
    "zfs.zfs_arc_max=12884901888"
  ];

  # todo: scrub settings
  # services.zfs.autoScrub = {
  #   enable = true;
  #   pools = [ "primary" ];
  #   interval = "monthly"; # recommended
  # };

  # NFS settings
  services.nfs.server = {
    enable = true;

    # todo: manage access properly
    exports = ''
      /tank/media 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/proxmox-backup 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/drive 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/vaultwarden 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/photos 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
    '';
  };

  networking.firewall.allowedTCPPorts = [
    2049
  ];

  # S.M.A.R.T values
  # todo: easy monitoring?
  services.smartd.enable = true;
  environment.systemPackages = with pkgs; [
    smartmontools # for smartctl
  ];

  # todo: add snapshot management
  # todo: add backup management (ZFS send / rcv from / to PBS? USB backup disk?)
  # todo: ZFS dataset settings (oneshot systemd service?)
  # todo: telegraf monitoring
}
