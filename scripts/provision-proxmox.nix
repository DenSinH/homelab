{
  lib,
  pkgs,
}:

let
  scriptLib = import ./lib.nix { inherit lib pkgs; };
  inherit (scriptLib) preamble requireArgs hostCase;

  # Grafana dashboard URL for the kiosk role; reads lib.lxcs.telemetry only to
  # derive this value, not as an inventory target.
  grafanaKioskUrl = "http://${lib.lxcs.telemetry.ip}:3000/d/advzc6f/kiosk?kiosk&_dash.hideTimePicker=true&_dash.hideVariables=true&hideLogo=true";

  # lib.hosts only (never lib.lxcs as inventory targets); provision.* flags become hostvars.
  hostVars = builtins.mapAttrs (_: host: {
    ansible_host = host.ip;
    pve_hostname = host.hostname;
    pve_powertop_enabled = (host.provision or { }).powertop or false;
    pve_unattended_upgrades_enabled = (host.provision or { }).autoUpdates or false;
    pve_ssd_optimization_enabled = (host.provision or { }).ssdOptimization or false;
    pve_console_powersave_enabled = (host.provision or { }).consolePowerSaving or false;
    # Opt-out, not opt-in: true unless a host explicitly sets cpuGovernor = false.
    pve_cpu_governor_enabled = (host.provision or { }).cpuGovernor or true;
    pve_pvestatd_autorestart_enabled = (host.provision or { }).pvestatdAutoRestart or false;
    pve_lxc_fstrim_enabled = (host.provision or { }).lxcFstrim or false;
    pve_vmid_range_lower = host.ctidRange.min;
    pve_vmid_range_upper = host.ctidRange.max;
    pve_grafana_kiosk_enabled = (host.provision or { }).grafanaKiosk or false;
    pve_grafana_kiosk_url = grafanaKioskUrl;
  }) lib.hosts;

  allHosts = builtins.attrNames lib.hosts;

  # community.proxmox modules run locally (delegate_to: localhost) and need proxmoxer.
  ansibleEnv = pkgs.python3.withPackages (ps: [
    ps.ansible
    ps.ansible-core
    ps.proxmoxer
    ps.requests
  ]);

  inventoryJson = builtins.toJSON {
    proxmox = {
      hosts = hostVars;
    };
    local.hosts.localhost = {
      ansible_connection = "local";
      ansible_python_interpreter = "${ansibleEnv}/bin/python3";
    };
  };

  inventoryFile = pkgs.writeText "proxmox-inventory.json" inventoryJson;

  # Ranges allowed to reach Proxmox SSH/web UI; excludes services/iot.
  # Individual IPs, not ranges - Proxmox ipsets don't accept those.
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

  pveSshVarsFile = pkgs.writeText "pve-ssh-vars.json" (
    builtins.toJSON {
      pve_ssh_authorized_keys = lib.admin.ssh_keys;
    }
  );

  allHostsSpaceSeparated = builtins.concatStringsSep " " allHosts;

  repoRoot = ../.;
  ansiblePlaybook = "${ansibleEnv}/bin/ansible-playbook";

in

pkgs.writeShellScript "provision-proxmox" ''
  ${preamble}
  ${requireArgs {
    usage = "Usage: $0 <proxmox-host> [extra ansible-playbook args...]\n       $0 all [extra ansible-playbook args...]";
    description = "Examples:\n  $0 proxmox1 --tags firewall --check\n  $0 all --check";
  }}

  target="$1"
  shift

  ${hostCase {
    varName = "target";
    extraArms = "all) ;;";
    extraEcho = "Known hosts: ${allHostsSpaceSeparated} all";
  }}

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
      --extra-vars "@${pveSshVarsFile}" \
      "''${extra_args[@]}" \
      "${toString repoRoot}/ansible/playbooks/site.yml" \
      "$@"

  print_success "Provisioning finished for $target"
''
