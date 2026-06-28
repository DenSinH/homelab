{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts,
}:

let
  configBase = import ./config-base.nix {
    inherit lib pkgs lxcHosts proxmoxHosts;
  };
in

configBase.mkConfigScript {
  name = "config-igpu";
  description = "This will configure /dev/dri passthrough for Intel GPU access";
  addLines = ''
    print_info "Detecting DRM devices on host..."

    CARDS=(/dev/dri/card*)

    if compgen -G "/dev/dri/card*" > /dev/null; then
      CARD_PATH="$(ls /dev/dri/card* | head -n1)"
      CARD_NAME="$(basename "$CARD_PATH")"
    else
      CARD_PATH=""
      CARD_NAME=""
    fi

    if [ ! -e "/dev/dri/renderD128" ]; then
      print_error "renderD128 not found on host"
      exit 1
    fi

    # --- Add config lines dynamically ---
    add_line "lxc.cgroup2.devices.allow: c 226:1 rwm"

    if [ -n "$CARD_NAME" ]; then
      add_line "lxc.mount.entry: /dev/dri/$CARD_NAME dev/dri/$CARD_NAME none bind,create=file 0 0"
    fi

    add_line "lxc.cgroup2.devices.allow: c 226:128 rwm"
    add_line "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,create=file 0 0"
  '';
}
