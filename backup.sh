#!/usr/bin/env bash
# Back up all Hermes state (volumes + env file) to a directory. See MIGRATION.md.
# Usage: ./backup.sh [DEST_DIR]   (default: ~/hermes-backup-YYYYmmdd-HHMMSS)
set -euo pipefail

VOLUMES=(hermes-data hermes-sandbox-home hermes-sandbox-hostkeys)
SERVICES=(hermes-sandbox.service hermes.service)
ENV_FILE="$HOME/.config/hermes/hermes.env"
DEST="${1:-$HOME/hermes-backup-$(date +%Y%m%d-%H%M%S)}"

umask 077   # the backup holds tokens and SSH keys
mkdir -p "$DEST"

echo "==> Stopping services for a consistent copy"
systemctl --user stop "${SERVICES[@]}"
trap 'echo "==> Starting services"; systemctl --user start hermes.service hermes-sandbox.service' EXIT

for v in "${VOLUMES[@]}"; do
    echo "==> Exporting $v"
    podman volume export "$v" -o "$DEST/$v.tar"
done
cp "$ENV_FILE" "$DEST/hermes.env"

echo "==> Backup written to $DEST (contains secrets; delete after migrating)"
