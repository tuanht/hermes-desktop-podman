#!/usr/bin/env bash
# Installs the hermes-desktop rootless Quadlet and enables it to start at boot.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/quadlet"
UNIT_DIR="$HOME/.config/containers/systemd"
ENV_DIR="$HOME/.config/hermes-desktop"
ENV_FILE="$ENV_DIR/hermes.env"

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }

mkdir -p "$UNIT_DIR" "$ENV_DIR"

# Create the env file once with a random password; never overwrite an existing one.
if [[ ! -f "$ENV_FILE" ]]; then
    pw="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
    sed "s/^HERMES_PASSWORD=.*/HERMES_PASSWORD=$pw/" "$SRC_DIR/hermes.env.example" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Created $ENV_FILE with a generated HERMES_PASSWORD."
fi

# Build the derived image (Telegram + Node/TUI fixes) if it is not present yet.
if ! podman image exists localhost/hermes-desktop-custom:latest; then
    podman build -t localhost/hermes-desktop-custom:latest -f "$(dirname "$SRC_DIR")/image/Containerfile" "$(dirname "$SRC_DIR")/image"
fi

install -m 0644 "$SRC_DIR/hermes-desktop.container" "$UNIT_DIR/hermes-desktop.container"

# Keep user services running after boot without an interactive login.
loginctl enable-linger "$USER"

systemctl --user daemon-reload
# Quadlet units are generated; boot start comes from [Install] WantedBy, so no 'enable'.
systemctl --user restart hermes-desktop.service
systemctl --user --no-pager status hermes-desktop.service || true
