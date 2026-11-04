{
  lib,
  pkgs,
}:

let
  scriptLib = import ./lib.nix { inherit lib pkgs; };
  inherit (scriptLib) preamble requireArgs lxcCase;

  allLxcs = scriptLib.spaceSeparated (scriptLib.names lib.lxcs);
in

pkgs.writeShellScript "deploy" ''
  ${preamble}
  ${requireArgs { usage = "Usage: $0 <hostname> [hostname ...] | all"; }}

  CHECKPOINT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.deploy-checkpoint"

  # "all" resumes from a previous failed run if a checkpoint exists; an
  # explicit host list always ignores it.
  if [ $# -eq 1 ] && [ "$1" = "all" ]; then
      if [ -f "$CHECKPOINT" ]; then
          print_warning "Resuming from checkpoint ($(wc -l < "$CHECKPOINT") host(s) remaining)"
          mapfile -t hosts < "$CHECKPOINT"
      else
          hosts=(${allLxcs})
      fi
  else
      hosts=("$@")
  fi

  validate_host() {
      local host="$1"
      ${lxcCase { varName = "host"; }}
  }

  for host in "''${hosts[@]}"; do
      validate_host "$host"
  done

  deploy_one() {
      local host="$1"
      ${lxcCase { varName = "host"; }}

      print_info "Deploying to $host (IP=$ip, CTID=$ctid)"
      print_info "Checking remote CTID..."

      actual="$(
          ssh root@$ip '
              cat /proc/self/mountinfo \
              | sed -n "s#.*pve-vm--\\([0-9]\\+\\)--disk--[0-9]\\+.*#\\1#p" \
              | head -n1
          '
      )"

      if [ -z "$actual" ]; then
          print_error "Could not determine CTID from remote system"
          return 1
      fi

      if [ "$actual" != "$ctid" ]; then
          print_error "CTID mismatch"
          print_warning "Expected: $ctid"
          print_warning "Actual:   $actual"
          return 1
      fi

      print_success "CTID OK, deploying to $actual@$ip..."

      env \
          -u LD_LIBRARY_PATH \
          -u NIX_LD \
          -u NIX_LD_LIBRARY_PATH \
          nixos-rebuild switch \
              --flake ".#$host" \
              --target-host "root@$ip"

      print_success "Deployment finished for $host"

      print_info "Cleaning up remote nix store..."
      ssh root@$ip '
          nix-collect-garbage -d
      '
  }

  for ((i = 0; i < ''${#hosts[@]}; i++)); do
      host="''${hosts[$i]}"
      if ! ( set -euo pipefail; deploy_one "$host" ); then
          print_error "Deployment failed for $host"
          printf '%s\n' "''${hosts[@]:$i}" > "$CHECKPOINT"
          print_warning "Checkpoint saved; run '$0 all' again to resume from $host"
          exit 1
      fi
  done

  rm -f "$CHECKPOINT"
''
