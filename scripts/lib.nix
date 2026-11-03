{ lib, pkgs }:
rec {
  colorsScript = builtins.readFile ./colors.sh;

  # Shared preamble: shebang, strict mode, colors.
  preamble = ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${colorsScript}
  '';

  # "No host specified" usage/error boilerplate.
  requireArgs =
    {
      usage,
      description ? "",
    }:
    ''
      if [ $# -eq 0 ]; then
          print_error "No host specified"
          echo "${usage}"
          ${lib.optionalString (description != "") ''
            echo ""
            echo "${description}"
          ''}
          exit 1
      fi
    '';

  # Build a `case "$x" in <name>) <render name value> ;; ... esac` body from an
  # attrset. `render` returns the bash lines for one arm (no `name)`/`;;`).
  mkCaseBlock =
    attrs: render:
    builtins.concatStringsSep "\n" (
      builtins.attrValues (
        builtins.mapAttrs (name: value: ''
          ${name})
          ${render name value}
            ;;
        '') attrs
      )
    );

  names = attrs: builtins.attrNames attrs;
  spaceSeparated = xs: builtins.concatStringsSep " " xs;

  # Fallback `case` arm for an unrecognized host/target, reading `varName`
  # (e.g. "host" -> $host). `extraEcho`, if given, is printed after the error
  # (e.g. to list known hosts).
  unknownCase =
    {
      varName,
      extraEcho ? "",
    }:
    ''
      *)
          print_error "Unknown host: ${"$" + varName}"
          ${lib.optionalString (extraEcho != "") ''echo "${extraEcho}"''}
          exit 1
          ;;
    '';

  # A complete `case "$<varName>" in ... esac`, dispatching on `attrs` via
  # `render` (see mkCaseBlock) and falling back to unknownCase. `extraArms`
  # (raw case-arm bash, e.g. `all) ;;`) is spliced in before the fallback.
  mkCase =
    {
      attrs,
      render,
      varName,
      extraArms ? "",
      extraEcho ? "",
    }:
    ''
      case "${"$" + varName}" in
          ${mkCaseBlock attrs render}
          ${extraArms}
          ${unknownCase { inherit varName extraEcho; }}
      esac
    '';

  # Canonical per-host/per-LXC case statements, shared by every script that
  # dispatches on a hostname. Each sets every field any caller needs; a
  # script that only uses some of them just leaves the rest unread.
  hostCase =
    {
      varName,
      extraArms ? "",
      extraEcho ? "",
    }:
    mkCase {
      inherit varName extraArms extraEcho;
      attrs = lib.hosts;
      render = _: host: ''
        hostname="${host.hostname}"
        ip="${host.ip}"
      '';
    };

  lxcCase =
    { varName }:
    mkCase {
      inherit varName;
      attrs = lib.lxcs;
      render =
        _: lxc:
        let
          pveHost = lib.hosts.${lxc.pveHost};
        in
        ''
          ip="${lxc.ip}"
          ctid="${toString lxc.ctid}"
          pve_ip="${pveHost.ip}"
          pve_hostname="${pveHost.hostname}"
        '';
    };
}
