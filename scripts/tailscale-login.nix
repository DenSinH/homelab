{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts ? { },
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  # Generate case statements from lxcHosts - only need IP for tailscale login
  hostCases = builtins.concatStringsSep "\n" (
    builtins.attrValues (
      builtins.mapAttrs (name: host: ''
        ${name})
          ip="${host.meta.ip}"
          ;;
      '') lxcHosts
    )
  );
in

pkgs.writeShellScript "tailscale-login" ''
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

  print_info "Logging into Tailscale on $host ($ip)"
  ssh -t root@$ip "tailscale login && reboot"
''
