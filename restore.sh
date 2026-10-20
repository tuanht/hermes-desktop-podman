#!/usr/bin/env bash
# Restore a ./backup.sh directory onto this machine. See MIGRATION.md.
# Usage: ./restore.sh BACKUP_DIR
# Run it twice if needed: the first run only places hermes.env and then asks you to run ./install.sh.
set -euo pipefail

VOLUMES=(hermes-data hermes-sandbox-home hermes-sandbox-hostkeys)
ENV_FILE="$HOME/.config/hermes/hermes.env"
SRC="${1:?usage: $0 BACKUP_DIR}"

for f in hermes.env "${VOLUMES[@]/%/.tar}"; do
    [[ -f "$SRC/$f" ]] || { echo "missing $SRC/$f" >&2; exit 1; }
done

# The env file must exist before install.sh, which never overwrites it.
if [[ ! -f "$ENV_FILE" ]]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    install -m 600 "$SRC/hermes.env" "$ENV_FILE"
    echo "==> Installed $ENV_FILE"
fi

if ! podman volume exists hermes-data; then
    echo "Volumes not found. Edit the PublishPort IP in quadlet/hermes.pod, run ./install.sh, then rerun this script." >&2
    exit 1
fi

echo "==> Stopping services"
systemctl --user stop hermes-sandbox.service hermes.service

for v in "${VOLUMES[@]}"; do
    echo "==> Importing $v"
    podman volume import "$v" "$SRC/$v.tar"
done

echo "==> Starting services"
systemctl --user start hermes.service hermes-sandbox.service
echo "==> Done. Verify: podman exec hermes hermes profile list"
