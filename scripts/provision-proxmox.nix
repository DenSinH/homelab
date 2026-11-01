{
  lib,
  pkgs,
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  # lib.hosts is the only source of inventory data (never lib.lxcs). Shaped
  # for the ansible yaml inventory plugin: group -> hosts -> {host: vars}.
  # provision.* flags become hostvars, so roles can gate on them (e.g.
  # pve_powertop_enabled below).
  hostVars = builtins.mapAttrs (_: host: {
    ansible_host = host.ip;
    pve_powertop_enabled = (host.provision or { }).powertop or false;
    pve_unattended_upgrades_enabled = (host.provision or { }).autoUpdates or false;
  }) lib.hosts;

  allHosts = builtins.attrNames lib.hosts;

  inventoryJson = builtins.toJSON {
    proxmox = {
      hosts = hostVars;
    };
  };

  inventoryFile = pkgs.writeText "proxmox-inventory.json" inventoryJson;

  # Ranges allowed to reach Proxmox SSH/web UI; excludes services/iot.
  # Individual IPs (not hyphenated ranges - Proxmox ipsets don't accept
  # those) from lib.lan.rangeIps, fed into the Proxmox "management" ipset.
  pveFirewallManagementCategories = [
    "compute"
    "dynamic"
    "fixed"
  ];
  pveFirewallManagementIps = lib.lists.concatMap (
    cat: lib.lan.rangeIps.${cat}
  ) pveFirewallManagementCategories;

  pveFirewallVarsFile = pkgs.writeText "pve-firewall-vars.json" (
    builtins.toJSON {
      pve_firewall_ipsets.management = pveFirewallManagementIps;
    }
  );

  allHostsSpaceSeparated = builtins.concatStringsSep " " allHosts;

  hostCases = builtins.concatStringsSep "\n" (
    map (name: ''
      ${name}) ;;
    '') allHosts
  );

  repoRoot = ../.;
  ansiblePlaybook = "${pkgs.ansible}/bin/ansible-playbook";

in

pkgs.writeShellScript "provision-proxmox" ''
  #!/usr/bin/env bash
  set -euo pipefail

  ${colorsScript}

  if [ $# -eq 0 ]; then
      print_error "No host specified"
      echo "Usage: $0 <proxmox-host> [extra ansible-playbook args...]"
      echo "       $0 all [extra ansible-playbook args...]"
      echo "Examples:"
      echo "  $0 proxmox1 --tags firewall --check"
      echo "  $0 all --check"
      exit 1
  fi

  target="$1"
  shift

  case "$target" in
      ${hostCases}
      all) ;;
      *)
          print_error "Unknown host: $target"
          echo "Known hosts: ${allHostsSpaceSeparated} all"
          exit 1
          ;;
  esac

  extra_args=()
  if [ "$target" != "all" ]; then
      extra_args+=(--limit "$target")
  fi

  if printf '%s\n' "$@" | grep -qx -- '--check' 2>/dev/null; then
      print_warning "Running in --check (dry-run) mode: no changes will be applied"
  else
      print_warning "This will apply changes to real Proxmox host(s): $target"
  fi

  print_info "Running ansible-playbook against: $target"

  export ANSIBLE_CONFIG="${toString repoRoot}/ansible/ansible.cfg"
  export ANSIBLE_ROLES_PATH="${toString repoRoot}/ansible/roles"

  ${ansiblePlaybook} \
      -i "${inventoryFile}" \
      --extra-vars "@${pveFirewallVarsFile}" \
      "''${extra_args[@]}" \
      "${toString repoRoot}/ansible/playbooks/site.yml" \
      "$@"

  print_success "Provisioning finished for $target"
''
