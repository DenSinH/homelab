#!/usr/bin/env bash
set -euo pipefail

# init-host.sh — de-clone a NixOS LXC container spun up from a shared template.
#
# What it does:
#   1. Rotates SSH host keys (the template's keys are shared across every clone).
#   2. Regenerates /etc/machine-id (also shared post-clone; used by systemd/D-Bus/DHCP).
#   3. Derives an age recipient from the new ed25519 host key (no separate
#      age keypair to generate, store, or rotate).
#   4. Prints the SSH public key and age recipient for you to register.
#
# Run once, as root, right after the container is reachable.
# Re-running requires --force (rotating again invalidates anything already
# encrypted to the previous age recipient / anyone pinning the old host key).

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root" >&2
  exit 1
fi

HOSTNAME="$(hostname)"
SSH_DIR="/etc/ssh"
MARKER="/etc/ssh/.init-host-rotated"

if [[ -e "$MARKER" && "${1:-}" != "--force" ]]; then
  echo "Already rotated on $(cat "$MARKER"). Pass --force to redo." >&2
  exit 1
fi

echo "== Removing cloned SSH host keys ==" >&2
rm -f "$SSH_DIR"/ssh_host_*_key "$SSH_DIR"/ssh_host_*_key.pub

echo "== Generating fresh host keys ==" >&2
systemctl restart sshd-keygen.service

chown root:root "$SSH_DIR"/ssh_host_*_key
chmod 600 "$SSH_DIR"/ssh_host_*_key
chmod 644 "$SSH_DIR"/ssh_host_*_key.pub

# No sshd restart needed: this host uses socket-activated OpenSSH
# (sshd.socket -> per-connection sshd@.service instances), which read
# host keys fresh from disk on every new connection. The next SSH
# connection automatically gets the new key.

echo "== Regenerating machine-id ==" >&2
rm -f /etc/machine-id
systemd-machine-id-setup >/dev/null

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER"

SSH_PUB_LINE="$(cat "$SSH_DIR/ssh_host_ed25519_key.pub")"

echo "== Deriving age recipient from ed25519 host key ==" >&2
if command -v ssh-to-age >/dev/null 2>&1; then
  AGE_PUB="$(ssh-to-age -i "$SSH_DIR/ssh_host_ed25519_key.pub")"
else
  AGE_PUB="$(nix run --extra-experimental-features 'nix-command flakes' nixpkgs#ssh-to-age -- -i "$SSH_DIR/ssh_host_ed25519_key.pub")"
fi

cat <<EOF

============================================================
 Host initialized: $HOSTNAME
============================================================

SSH host public key (register in your NixOS config / known_hosts):

  $SSH_PUB_LINE

Age recipient (register in .sops.yaml):

  $AGE_PUB

.sops.yaml snippet:

  keys:
    - &host_$HOSTNAME $AGE_PUB
  creation_rules:
    - path_regex: hosts/$HOSTNAME/.*\.yaml\$
      key_groups:
        - age:
            - *host_$HOSTNAME
            - *admin   # your existing admin/operator key anchor

NixOS config for this host (sops-nix — no separate age key file needed,
it's derived from the ed25519 host key at activation time):

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

============================================================
EOF