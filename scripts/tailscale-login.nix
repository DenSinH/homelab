{
  lib,
  pkgs,
}:

let
  scriptLib = import ./lib.nix { inherit lib pkgs; };
  inherit (scriptLib) preamble requireArgs lxcCase;
in

pkgs.writeShellScript "tailscale-login" ''
  ${preamble}
  ${requireArgs { usage = "Usage: $0 <hostname>"; }}

  host="$1"

  ${lxcCase { varName = "host"; }}

  print_info "Logging into Tailscale on $host ($ip)"
  ssh -t root@$ip "tailscale login && reboot"
''
