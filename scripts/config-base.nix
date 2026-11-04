{
  lib,
  pkgs,
}:

let
  scriptLib = import ./lib.nix { inherit lib pkgs; };
  inherit (scriptLib) preamble requireArgs lxcCase;
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
      ${preamble}
      ${requireArgs { inherit usage description; }}

      host="$1"

      ${lxcCase { varName = "host"; }}

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
          if ping -c 1 -W 2 $ip >/dev/null 2>&1; then
              print_success "Container $host is back online at $ip"
          else
              print_warning "Container may still be starting up. Check with: ping $ip"
          fi
      elif [ "$OUTPUT" = "NO_CHANGES_NEEDED" ]; then
          print_success "Configuration already correct"
      else
          print_error "Unexpected result from configuration check"
          exit 1
      fi
    '';
}
