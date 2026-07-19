{ config, pkgs, ... }:

{
  # NFS settings
  services.nfs.server = {
    enable = true;

    # Fix ports for the auxiliary RPC services because we run a firewall
    mountdPort = 20048;
    statdPort = 32765;
    lockdPort = 32766;

    # todo: manage access properly
    exports = ''
      /tank/media 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/proxmox-backup 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/drive 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/vaultwarden 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
      /tank/photos 192.168.50.0/24(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,sec=sys,rw,secure,root_squash,all_squash)
    '';
  };

  networking.firewall =
    let
      ports = [
        111 # rpcbind
        2049 # nfs
        20048 # mountd
        32765 # statd
        32766 # lockd
      ];
    in
    {
      allowedTCPPorts = ports;
      allowedUDPPorts = ports;
    };
}
