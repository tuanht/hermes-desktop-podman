#!/usr/bin/env bash
# Installs the Hermes rootless Quadlet (official image) and enables it to start at boot.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/quadlet"
UNIT_DIR="$HOME/.config/containers/systemd"
ENV_DIR="$HOME/.config/hermes"
ENV_FILE="$ENV_DIR/hermes.env"
IMAGE="docker.io/nousresearch/hermes-agent:latest"

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }

mkdir -p "$UNIT_DIR" "$ENV_DIR"

# Create the env file once with random secrets; never overwrite an existing one.
if [[ ! -f "$ENV_FILE" ]]; then
    rnd() { head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c "$1"; }
    sed -e "s/^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=.*/HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(rnd 24)/" \
        -e "s/^HERMES_DASHBOARD_BASIC_AUTH_SECRET=.*/HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(rnd 32)/" \
        "$SRC_DIR/hermes.env.example" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Created $ENV_FILE with generated dashboard credentials."
fi

# Retire the old unofficial desktop image setup, if present (volume is left untouched).
if systemctl --user cat hermes-desktop.service >/dev/null 2>&1; then
    systemctl --user stop hermes-desktop.service || true
fi
rm -f "$UNIT_DIR/hermes-desktop.container"

podman pull "$IMAGE"

install -m 0644 "$SRC_DIR/hermes.volume" "$UNIT_DIR/hermes.volume"
install -m 0644 "$SRC_DIR/hermes.container" "$UNIT_DIR/hermes.container"

# Keep user services running after boot without an interactive login.
loginctl enable-linger "$USER"

systemctl --user daemon-reload

# First-time setup wizard writes API keys into the data volume (interactive, runs once).
if ! podman volume exists hermes-data; then
    systemctl --user start hermes-volume.service
    echo "Running first-time setup wizard..."
    podman run -it --rm -v hermes-data:/opt/data:Z "$IMAGE" setup
fi

# Quadlet units are generated; boot start comes from [Install] WantedBy, so no 'enable'.
systemctl --user restart hermes.service
systemctl --user --no-pager status hermes.service || true
