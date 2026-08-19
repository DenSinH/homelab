{
  lib,
  pkgs,
}:

let
  colorsScript = builtins.readFile ./colors.sh;

  hostCases = builtins.concatStringsSep "\n" (
    builtins.attrValues (
      builtins.mapAttrs (name: host: ''
        ${name})
          hostname="${host.hostname}"
          ip="${host.ip}"
          ;;
      '') lib.hosts
    )
  );

  allHosts = builtins.concatStringsSep " " (builtins.attrNames lib.hosts);

  authorizedKeys = builtins.concatStringsSep "\n" (map (key: "    ${key}") lib.admin.ssh_keys);

in

pkgs.writeShellScript "config-proxmox" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${colorsScript}

    if [ $# -eq 0 ]; then
        print_error "No host specified"
        echo "Usage: $0 <proxmox-host> [proxmox-host ...]"
        echo "       $0 all"
        exit 1
    fi

    if [ $# -eq 1 ] && [ "$1" = "all" ]; then
        set -- ${allHosts}
    fi

    for host in "$@"; do
        case "$host" in
            ${hostCases}
            *)
                print_error "Unknown host: $host"
                exit 1
                ;;
        esac

        print_info "Configuring SSH on $host ($ip)..."

        # Install all configured admin keys.
        ssh root@$ip 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
        ssh root@$ip 'cat > /root/.ssh/authorized_keys' <<'EOF'
  ${authorizedKeys}
  EOF

        ssh root@$ip 'chmod 600 /root/.ssh/authorized_keys'

        print_success "SSH keys installed"

        # Test that key authentication actually works before
        # disabling password authentication.
        print_info "Testing SSH key authentication..."

        if ! ssh \
            -o PreferredAuthentications=publickey \
            -o PasswordAuthentication=no \
            -o PubkeyAuthentication=yes \
            root@$ip 'true'
        then
            print_error "SSH key authentication failed!"
            print_error "NOT changing sshd configuration."
            exit 1
        fi

        print_success "SSH key authentication works"

        print_info "Hardening sshd..."

        ssh root@$ip 'cat > /etc/ssh/sshd_config.d/99-homelab-hardening.conf' <<'EOF'
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PubkeyAuthentication yes
  PermitRootLogin prohibit-password
  EOF

        ssh root@$ip 'sshd -t'
        ssh root@$ip 'systemctl reload sshd'
        print_success "SSH hardened on $host"

        print_info "Verifying SSH still works..."
        ssh \
            -o PreferredAuthentications=publickey \
            -o PasswordAuthentication=no \
            root@$ip 'true'

        print_success "$host configured successfully"
    done
''
