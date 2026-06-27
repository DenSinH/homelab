{ config, pkgs, ... }:

let
  # Define colors inline for activation scripts
  colorsScript = builtins.readFile ../scripts/colors.sh;
in
{
  services.tailscale.enable = true;

  # Check existence of /dev/net/tun
  # this is required for tailscale to even work
  system.activationScripts.check-tun = ''
    ${colorsScript}

    if [[ ! -c /dev/net/tun ]]; then
      print_error "/dev/net/tun missing. Tailscale will not work in this LXC."
      print_warning "Fix this in your Proxmox container config (/etc/pve/lxc/<ctid>.conf):"
      print_warning ""
      print_warning "lxc.cgroup2.devices.allow: c 10:200 rwm"
      print_warning "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
      print_warning ""
      print_warning "Or run 'nix run .#config-tun -- <lxc name>'"
    else
      print_success "/dev/net/tun exists"
    fi    
  '';

  # Check if tailscale is already logged in
  # this serves as a reminder on first deploy
  # (or subsequent deploys if you forgot to log in)
  system.activationScripts.check-tailscale-login = ''
    ${colorsScript}

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
