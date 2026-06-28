{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts,
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  hostCases = builtins.concatStringsSep "\n" (
    builtins.attrValues (
      builtins.mapAttrs (
        name: host:
        let
          pveHost = proxmoxHosts.${host.meta.pveHost};
        in
        ''
          ${name})
            ctid="${toString host.meta.ctid}"
            pve_ip="${pveHost.ip}"
            pve_hostname="${pveHost.hostname}"
            lxc_ip="${host.meta.ip}"
            ;;
        ''
      ) lxcHosts
    )
  );
in

pkgs.writeShellScript "config-igpu" ''
  #!/usr/bin/env bash
  set -euo pipefail

  ${colorsScript}

  if [ $# -eq 0 ]; then
    print_error "No host specified"
    echo "Usage: $0 <hostname>"
    exit 1
  fi

  host="$1"

  case "$host" in
  ${hostCases}
  *)
    print_error "Unknown host: $host"
    exit 1
    ;;
  esac

  print_info "Configuring /dev/dri passthrough for $host (CTID: $ctid)"

  CONFIG_FILE="/etc/pve/lxc/$ctid.conf"

  print_info "Connecting to Proxmox host $pve_hostname ($pve_ip)..."

  OUTPUT=$(ssh root@$pve_ip bash -s <<EOF 2>&1 | tee /dev/stderr | tail -1
    set -e

    # Source color functions
    # https://stackoverflow.com/a/22107893/6788362
    $(typeset -f print_error)
    $(typeset -f print_warning)
    $(typeset -f print_info)
    $(typeset -f print_success)

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Container config $CONFIG_FILE not found!"
        exit 1
    fi

    print_info "Detecting DRM devices on host..."

    # --- Detect devices ---
    CARDS=(/dev/dri/card*)

    if compgen -G "/dev/dri/card*" > /dev/null; then
      CARD_PATH="\$(ls /dev/dri/card* | head -n1)"
      CARD_NAME="\$(basename "\$CARD_PATH")"
    else
      CARD_PATH=""
      CARD_NAME=""
    fi

    if [ ! -e "/dev/dri/renderD128" ]; then
      print_error "renderD128 not found on host"
      exit 1
    fi

    # --- Resolve correct GIDs dynamically ---
    VIDEO_GID=\$(getent group video | cut -d: -f3)
    RENDER_GID=\$(getent group render | cut -d: -f3)

    if [ -z "\$VIDEO_GID" ] || [ -z "\$RENDER_GID" ]; then
      print_error "Could not resolve video/render GIDs"
      exit 1
    fi

    print_info "video gid=\$VIDEO_GID, render gid=\$RENDER_GID"

    # --- Build NEW config lines (NO dev0/dev1) ---
    changed=false

    add_line "lxc.cgroup2.devices.allow: c 226:1 rwm"

    if [ -n "$CARD_NAME" ]; then
      add_line "lxc.mount.entry: /dev/dri/$CARD_NAME dev/dri/$CARD_NAME none bind,create=file 0 0"
    fi

    add_line "lxc.cgroup2.devices.allow: c 226:128 rwm"
    add_line "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,create=file 0 0"

    changed=false

    add_line() {
      local line="\$1"
      if ! grep -qF "\$line" "$CONFIG_FILE"; then
        echo "\$line" >> "$CONFIG_FILE"
        print_success "Added: \$line"
        changed=true
      fi
    }
  EOF
  )

  if [ "$OUTPUT" = "CHANGES_MADE" ]; then
      print_success "Configuration updated successfully"

      print_info "Restarting container $host (CTID: $ctid)..."
      ssh root@$pve_ip "pct reboot $ctid" || ssh root@$pve_ip "pct stop $ctid && pct start $ctid"

      print_success "Container restarted"
      print_info ""
      print_info "Waiting for container to come back online..."
      sleep 5

      if ping -c 1 -W 2 $lxc_ip >/dev/null 2>&1; then
          print_success "Container $host is back online at $lxc_ip"
      else
          print_warning "Container may still be starting up. Check with: ping $lxc_ip"
      fi
  elif [ "$OUTPUT" = "NO_CHANGES_NEEDED" ]; then
      print_success "Configuration already correct, no changes needed"
  else
      print_error "Unexpected result from configuration check"
      exit 1
  fi
''
