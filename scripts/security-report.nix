{ pkgs, ... }:

let
  colorsScript = builtins.readFile ./colors.sh;
in

pkgs.writeShellScript "security-report" ''
  #!/usr/bin/env bash
  set -euo pipefail

  ${colorsScript}

  jq="${pkgs.jq}/bin/jq"

  detail=false
  configs=()
  for arg in "$@"; do
      case "$arg" in
          --detail)
              detail=true
              ;;
          *)
              configs+=("$arg")
              ;;
      esac
  done

  # No hosts given on the command line: discover every nixosConfiguration
  # the flake defines, rather than keeping a list here by hand.
  if [ ''${#configs[@]} -eq 0 ]; then
      print_info "Discovering nixosConfigurations..."
      mapfile -t configs < <(nix eval --json .#nixosConfigurations --apply builtins.attrNames | "$jq" -r '.[]')
  fi

  for name in "''${configs[@]}"; do
      # Each module that hardens a unit records its name in
      # homelab.hardenedServices (see modules/common/hardened-services.nix) -
      # that's the single source of truth for what to check here, so adding
      # a new hardened unit never requires touching this script.
      units_json="$(nix eval --json ".#nixosConfigurations.$name.config.homelab.hardenedServices" 2>/dev/null)" || {
          print_error "Unknown nixosConfiguration: $name"
          exit 1
      }
      mapfile -t units < <(echo "$units_json" | "$jq" -r '.[]')

      if [ ''${#units[@]} -eq 0 ]; then
          continue
      fi

      print_info "Building $name..."
      root="$(nix build ".#nixosConfigurations.$name.config.system.build.toplevel" --no-link --print-out-paths)"

      for unit in "''${units[@]}"; do
          if $detail; then
              echo
              print_info "--- $name: $unit.service ---"
              systemd-analyze security --root="$root" --offline=yes --no-pager "$unit.service"
          else
              line="$(systemd-analyze security --root="$root" --offline=yes --no-pager "$unit.service" | grep 'Overall exposure level')"
              printf "%-16s %-28s %s\n" "$name" "$unit.service" "$line"
          fi
      done
  done
''
