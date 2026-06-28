{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts,
}:

let
  configBase = import ./config-base.nix {
    inherit
      lib
      pkgs
      lxcHosts
      proxmoxHosts
      ;
  };
in

configBase.mkConfigScript {
  name = "config-tun";
  description = "This will configure /dev/net/tun for the specified LXC container\nby adding the required lines to /etc/pve/lxc/<ctid>.conf on the Proxmox host";
  addLines = ''
    add_line "lxc.cgroup2.devices.allow: c 10:200 rwm"
    add_line "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
  '';
}
