#!/usr/bin/env bash

set -euo pipefail

cleanup() {
  kill "$SSH_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

ssh -N -L 5900:127.0.0.1:5900 root@offsite-backup.vpn &
SSH_PID=$!

# Give the tunnel a moment to establish
sleep 1

nix shell nixpkgs#virt-viewer -c \
  remote-viewer spice://127.0.0.1:5900
