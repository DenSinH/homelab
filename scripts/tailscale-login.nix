{
  lib,
  pkgs,
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  # Generate case statements from lib.lxcs - only need IP for tailscale login
  lxcCases = builtins.concatStringsSep "\n" (
    builtins.attrValues (
      builtins.mapAttrs (name: lxc: ''
        ${name})
          ip="${lxc.ip}"
          ;;
      '') lib.lxcs
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
      ${lxcCases}
      *)
          print_error "Unknown host: $host"
          exit 1
          ;;
  esac

  print_info "Logging into Tailscale on $host ($ip)"
  ssh -t root@$ip "tailscale login && reboot"
''
