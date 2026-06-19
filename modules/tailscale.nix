{ config, pkgs, ... }:

let
  # Define colors inline for activation scripts
  colorsSetup = ''
    RED='\033[1;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[1;32m'
    RESET='\033[0m'

    print_error() {
        printf "''${RED}ERROR: $1''${RESET}\n" >&2
    }

    print_warning() {
        printf "''${YELLOW}WARNING: $1''${RESET}\n"
    }

    print_success() {
        printf "''${GREEN}OK: $1''${RESET}\n"
    }
  '';
in
{
  services.tailscale.enable = true;

  # Check existence of /dev/net/tun
  # this is required for tailscale to even work
  system.activationScripts.check-tun = ''
    ${colorsSetup}

    if [[ ! -c /dev/net/tun ]]; then
      print_error "/dev/net/tun missing. Tailscale will not work in this LXC."
      print_warning "Fix this in your Proxmox container config (/etc/pve/lxc/<ctid>.conf):"
      printf "\n"
      printf "''${YELLOW}lxc.cgroup2.devices.allow: c 10:200 rwm''${RESET}\n"
      printf "''${YELLOW}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file''${RESET}\n"
      printf "\n"
    else
      print_success "/dev/net/tun exists"
    fi    
  '';

  # Check if tailscale is already logged in
  # this serves as a reminder on first deploy
  # (or subsequent deploys if you forgot to log in)
  system.activationScripts.check-tailscale-login = ''
    ${colorsSetup}

    TAILSCALE="${pkgs.tailscale}/bin/tailscale"
    JQ="${pkgs.jq}/bin/jq"

    # Wait briefly for tailscaled to be ready
    for i in $(seq 1 5); do
      if $TAILSCALE status >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done

    STATUS=$($TAILSCALE status --json 2>/dev/null || true)

    if [ -z "$STATUS" ]; then
      print_error "Tailscale is not running or not reachable"
    else
      BACKEND_STATE=$(echo "$STATUS" | $JQ -r '.BackendState // "Unknown"')

      if [ "$BACKEND_STATE" != "Running" ]; then
        print_warning "Tailscale is not authenticated (state: $BACKEND_STATE)"
        print_warning "Run: tailscale login or configure authKeyFile"
      else
        IP=$($TAILSCALE ip -4 2>/dev/null || true)

        if [ -z "$IP" ]; then
          print_warning "Tailscale running but no IP assigned"
        else
          print_success "Tailscale is authenticated and has IP $IP"
        fi
      fi
    fi
  '';
}
