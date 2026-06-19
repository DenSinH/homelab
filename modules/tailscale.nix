{ config, pkgs, ... }:

{
  services.tailscale.enable = true;

  # Check existence of /dev/net/tun
  # this is required for tailscale to even work
  system.activationScripts.check-tun = ''
    RED='\033[1;31m'
    YELLOW='\033[1;33m'
    RESET='\033[0m'
    GREEN='\033[1;32m'

    if [[ ! -c /dev/net/tun ]]; then
      printf "''${RED}ERROR: /dev/net/tun missing. Tailscale will not work in this LXC.''${RESET}\n"
      printf "''${YELLOW}Fix this in your Proxmox container config (/etc/pve/lxc/<ctid>.conf):''${RESET}\n"
      printf "\n"
      printf "''${YELLOW}lxc.cgroup2.devices.allow: c 10:200 rwm''${RESET}\n"
      printf "''${YELLOW}lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file''${RESET}\n"
      printf "\n"
    else
      printf "''${GREEN}OK: /dev/net/tun exists''${RESET}\n"
    fi    
  '';

  # Check if tailscale is already logged in
  # this serves as a reminder on first deploy
  # (or subsequent deploys if you forgot to log in)
  system.activationScripts.check-tailscale-login = ''
    RED='\033[1;31m'
    YELLOW='\033[1;33m'
    RESET='\033[0m'
    GREEN='\033[1;32m'

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
      printf "''${RED}ERROR: Tailscale is not running or not reachable''${RESET}\n"
    else
      BACKEND_STATE=$(echo "$STATUS" | $JQ -r '.BackendState // "Unknown"')

      if [ "$BACKEND_STATE" != "Running" ]; then
        printf "''${YELLOW}WARNING: Tailscale is not authenticated (state: %s)''${RESET}\n" "$BACKEND_STATE"
        printf "''${YELLOW}Run: tailscale login or configure authKeyFile''${RESET}\n"
      else
        IP=$($TAILSCALE ip -4 2>/dev/null || true)

        if [ -z "$IP" ]; then
          printf "''${YELLOW}WARNING: Tailscale running but no IP assigned''${RESET}\n"
        else
          printf "''${GREEN}OK: Tailscale is authenticated and has IP %s''${RESET}\n" "$IP"
        fi
      fi
    fi
  '';
}
