{ config, lib, ... }:

let
  egressCfg = config.homelab.egress;
  ingressCfg = config.homelab.ingress;

  allowedEntry = {
    options = {
      host = lib.mkOption { type = lib.types.str; };
      ports = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
      };
      protos = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "tcp"
            "udp"
          ]
        );
        default = [ "tcp" ];
      };
      comment = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
    };
  };

  # dir: "daddr" for egress, "saddr" for ingress. No ports means "any port",
  # which needs "meta l4proto tcp" - bare "tcp accept" is a syntax error.
  mkAllowedRuleLines =
    dir: entries:
    lib.concatMap (
      a:
      map (
        proto:
        if a.ports == [ ] then
          "ip ${dir} ${a.host} meta l4proto ${proto} accept comment \"${a.comment}\""
        else
          "ip ${dir} ${a.host} ${proto} dport { ${
            lib.concatMapStringsSep ", " toString a.ports
          } } accept comment \"${a.comment}\""
      ) a.protos
    ) entries;

  egressAllowedRuleLines = mkAllowedRuleLines "daddr" egressCfg.allowed;
  ingressAllowedRuleLines = mkAllowedRuleLines "saddr" ingressCfg.allowed;

  # Trusted by default; iot/services need an explicit allowed entry.
  trustedIngressRanges =
    map (name: "${lib.lan.rangeAddrs.${name}.lo}-${lib.lan.rangeAddrs.${name}.hi}") (
      builtins.attrNames (
        removeAttrs lib.lan.ranges [
          "iot"
          "services"
        ]
      )
    )
    # Tailscale's CGNAT range: covers both tailscale peers terminating here
    # directly and traffic subnet-router.nix forwards keeping their 100.x source.
    ++ [ "100.64.0.0/10" ];
in
{
  # Blocks outbound LAN by default (stops lateral movement); WAN stays open
  # since tailscale-enabled LXCs need broad UDP+443 anyway. Separate nftables
  # table from networking.firewall, so a compromised guest can't disable it.
  options.homelab.egress = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Block outbound LAN access except what's explicitly allowed below. WAN is unrestricted.";
    };
    allowLan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow outbound to the rest of the LAN.";
    };
    allowed = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule allowedEntry);
      default = [ ];
      description = "Explicit LAN destinations always allowed, regardless of allowLan.";
    };
  };

  # Denies iot/other-LXC sources by default; trusted ranges and `allowed`
  # entries still reach whatever ports networking.firewall opens.
  options.homelab.ingress = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Default-deny inbound from iot/other-LXC sources except what's explicitly allowed below.";
    };
    blockIot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Always block inbound from iot, independent of `enable` (set true for every LXC by modules/lxc/default.nix).";
    };
    allowed = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule allowedEntry);
      default = [ ];
      description = "Explicit sources always allowed inbound, regardless of range.";
    };
  };

  # `tables`, not `ruleset`: a ruleset enables flushRuleset, which wipes tailscaled's rules on reload.
  config = lib.mkMerge [
    (lib.mkIf egressCfg.enable {
      networking.nftables.enable = true;
      networking.nftables.tables.homelab_egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority 0; policy accept;

            ct state established,related accept
            oifname "lo" accept comment "loopback"
            tcp dport 53 accept comment "DNS"
            udp dport 53 accept comment "DNS"

            ${lib.concatStringsSep "\n            " egressAllowedRuleLines}
            ${lib.optionalString (!egressCfg.allowLan) ''
              ip daddr ${lib.lan.cidr} drop comment "LAN blocked by default"
            ''}
          }
        '';
      };
    })
    (lib.mkIf (ingressCfg.enable || ingressCfg.blockIot) {
      networking.nftables.enable = true;
      networking.nftables.tables.homelab_ingress = {
        family = "inet";
        content =
          if ingressCfg.enable then
            ''
              chain input {
                type filter hook input priority 0; policy drop;

                ct state established,related accept
                iifname "lo" accept comment "loopback"

                ip saddr { ${lib.concatStringsSep ", " trustedIngressRanges} } accept comment "trusted LAN ranges"
                ${lib.concatStringsSep "\n                " ingressAllowedRuleLines}
              }
            ''
          else
            # Lightweight mode: only iot is blocked, everything else stays as
            # open as networking.firewall already allows it.
            ''
              chain input {
                type filter hook input priority 0; policy accept;

                ${lib.concatStringsSep "\n                " ingressAllowedRuleLines}
                ip saddr ${lib.lan.rangeAddrs.iot.lo}-${lib.lan.rangeAddrs.iot.hi} drop comment "iot always blocked"
              }
            '';
      };
    })
  ];
}
