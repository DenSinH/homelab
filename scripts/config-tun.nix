{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts,
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  # Generate case statements from lxcHosts with all needed info
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

pkgs.writeShellScript "config-tun" ''
  #!/usr/bin/env bash
  set -euo pipefail

  ${colorsScript}

  if [ $# -eq 0 ]; then
      print_error "No host specified"
      echo "Usage: $0 <hostname>"
      echo ""
      echo "This will configure /dev/net/tun for the specified LXC container"
      echo "by adding the required lines to /etc/pve/lxc/<ctid>.conf on the Proxmox host"
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

  print_info "Configuring /dev/net/tun for $host (CTID: $ctid) on $pve_hostname"

  # The lines we need to add
  LINE1="lxc.cgroup2.devices.allow: c 10:200 rwm"
  LINE2="lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
  CONFIG_FILE="/etc/pve/lxc/$ctid.conf"

  print_info "Connecting to Proxmox host $pve_hostname ($pve_ip)..."

  # Configure file
  OUTPUT=$(ssh root@$pve_ip bash -s <<EOF 2>&1 | tee /dev/stderr | tail -1
    set -e

    # Source color functions
    ${colorsScript}

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Container config $CONFIG_FILE not found!"
        exit 1
    fi

    print_info "Checking $CONFIG_FILE..."

    # Check if both lines already exist
    has_line1=false
    has_line2=false

    if grep -qF "$LINE1" "$CONFIG_FILE"; then
        has_line1=true
    fi

    if grep -qF "$LINE2" "$CONFIG_FILE"; then
        has_line2=true
    fi

    if [ "\$has_line1" = true ] && [ "\$has_line2" = true ]; then
        print_success "Both lines already present in config"
        echo "NO_CHANGES_NEEDED"
    else
        print_warning "Adding missing configuration lines..."

        # Backup the config
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak.\$(date +%Y%m%d-%H%M%S)"

        # Add missing lines
        if [ "\$has_line1" = false ]; then
            echo "$LINE1" >> "$CONFIG_FILE"
            print_success "Added: $LINE1"
        fi

        if [ "\$has_line2" = false ]; then
            echo "$LINE2" >> "$CONFIG_FILE"
            print_success "Added: $LINE2"
        fi

        echo "CHANGES_MADE"
    fi
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

      # Test if the container is reachable
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
