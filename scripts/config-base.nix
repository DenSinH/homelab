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
{
  # Main function to create a config script
  mkConfigScript =
    {
      name,
      description ? "",
      usage ? "Usage: $0 <hostname>",
      addLines, # Bash code to add lines using add_line function
    }:
    pkgs.writeShellScript name ''
      #!/usr/bin/env bash
      set -euo pipefail

      ${colorsScript}

      if [ $# -eq 0 ]; then
          print_error "No host specified"
          echo "${usage}"
          ${lib.optionalString (description != "") ''
            echo ""
            echo "${description}"
          ''}
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

      print_info "Configuring $host (CTID: $ctid) on $pve_hostname"

      CONFIG_FILE="/etc/pve/lxc/$ctid.conf"

      print_info "Connecting to Proxmox host $pve_hostname ($pve_ip)..."

      # Configure file
      OUTPUT=$(ssh root@$pve_ip bash -s <<EOF 2>&1 | tee /dev/stderr | tail -1
        set -e

        # Source color functions
        # https://stackoverflow.com/a/22107893/6788362
        $(typeset -p RED YELLOW GREEN RESET 2>/dev/null || true)
        $(typeset -f print_error print_warning print_success print_info)

        if [ ! -f "$CONFIG_FILE" ]; then
            print_error "Container config $CONFIG_FILE not found!"
            exit 1
        fi

        print_info "Checking $CONFIG_FILE..."

        # Function to add a line if it doesn't exist
        add_line() {
          local line="\$1"
          if ! grep -qF "\$line" "$CONFIG_FILE"; then
            echo "\$line" >> "$CONFIG_FILE"
            print_success "Added: \$line"
            changed=true
          fi
        }

        # Initialize changed flag
        changed=false

        # Add configuration lines
        ${addLines}

        if [ "\$changed" = true ]; then
            # Backup the config
            cp "$CONFIG_FILE" "$CONFIG_FILE.bak.\$(date +%Y%m%d-%H%M%S)"
            echo "CHANGES_MADE"
        else
            print_success "All lines already present in config"
            echo "NO_CHANGES_NEEDED"
        fi
      EOF
      )

      if [ "$OUTPUT" = "CHANGES_MADE" ]; then
          print_success "Configuration updated"

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
          print_success "Configuration already correct"
      else
          print_error "Unexpected result from configuration check"
          exit 1
      fi
    '';

  inherit colorsScript hostCases;
}
