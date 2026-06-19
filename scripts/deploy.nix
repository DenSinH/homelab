{
  lib,
  pkgs,
  lxcHosts,
  proxmoxHosts ? { },
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  # Generate case statements from lxcHosts
  hostCases = builtins.concatStringsSep "\n" (
    builtins.attrValues (
      builtins.mapAttrs (name: host: ''
        ${name})
          ip="${host.meta.ip}"
          ctid="${toString host.meta.ctid}"
          ;;
      '') lxcHosts
    )
  );
in

pkgs.writeShellScript "deploy" ''
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

  print_info "Deploying to $host (IP=$ip, CTID=$ctid)"
  print_info "Checking remote CTID..."

  actual="$(
      ssh root@$ip '
          cat /proc/self/mountinfo \
          | sed -n "s#.*pve-vm--\\([0-9]\\+\\)--disk--0.*#\\1#p" \
          | head -n1
      '
  )"

  if [ -z "$actual" ]; then
      print_error "Could not determine CTID from remote system"
      exit 1
  fi

  if [ "$actual" != "$ctid" ]; then
      print_error "CTID mismatch"
      print_warning "Expected: $ctid"
      print_warning "Actual:   $actual"
      exit 1
  fi

  print_success "CTID OK, deploying to $actual@$ip..."

  nixos-rebuild switch \
      --flake ".#$host" \
      --target-host root@$ip
''
