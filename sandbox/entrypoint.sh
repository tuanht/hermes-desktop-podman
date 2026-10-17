#!/usr/bin/env bash
# Persist host keys (volume at /etc/ssh/hostkeys) so clients don't see changed-key warnings.
set -euo pipefail
mkdir -p /etc/ssh/hostkeys /run/sshd
[[ -f /etc/ssh/hostkeys/ssh_host_ed25519_key ]] || \
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ssh_host_ed25519_key
# Volume mounts over /home/dev start root-owned on first use.
chown dev:dev /home/dev
exec /usr/sbin/sshd -D -e
