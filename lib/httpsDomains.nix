# An LXC's `https` entry as [{ fqdn, ip, wildcard }], *.home first; .vpn only with a tailnet_ip.
{ lib }:
lxc:
let
  https = lxc.https or null;
  zones = {
    ${lib.lan.domains.home} = lxc.ip;
  }
  // lib.optionalAttrs ((lxc.tailnet_ip or null) != null) {
    ${lib.lan.domains.vpn} = lxc.tailnet_ip;
  };
in
lib.optionals (https != null) (
  lib.concatMap (
    name:
    lib.mapAttrsToList (zone: ip: {
      fqdn = "${name}.${zone}";
      inherit ip;
      wildcard = https.wildcard or false;
    }) zones
  ) (https.names or [ lxc.hostname ])
)
