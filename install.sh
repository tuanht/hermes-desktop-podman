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

# SSH key pair for the coder-remote profile; the public half is mounted into the sandbox.
KEY_DIR="$ENV_DIR/coder-remote"
mkdir -p "$KEY_DIR"
if [[ ! -f "$KEY_DIR/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C hermes-coder-remote -f "$KEY_DIR/id_ed25519"
fi
install -m 0644 "$KEY_DIR/id_ed25519.pub" "$KEY_DIR/authorized_keys"

podman build -t localhost/hermes-sandbox:latest "$(dirname "$SRC_DIR")/sandbox"

# Transmission MCP server image, built from its own repo (skipped if the checkout is missing).
MCP_SRC="${TRANSMISSION_MCP_DIR:-$HOME/Projects/transmission-mcp}"
if [[ -d "$MCP_SRC" ]]; then
    podman build -t localhost/transmission-mcp:latest "$MCP_SRC"
    WITH_TRANSMISSION_MCP=1
else
    echo "Skipping transmission-mcp: $MCP_SRC not found." >&2
fi

for u in hermes.volume hermes.container hermes.network hermes.pod \
         hermes-sandbox.volume hermes-sandbox.container; do
    install -m 0644 "$SRC_DIR/$u" "$UNIT_DIR/$u"
done
if [[ -n "${WITH_TRANSMISSION_MCP:-}" ]]; then
    install -m 0644 "$SRC_DIR/transmission-mcp.container" "$UNIT_DIR/transmission-mcp.container"
fi

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
systemctl --user restart hermes-sandbox.service hermes.service
[[ -z "${WITH_TRANSMISSION_MCP:-}" ]] || systemctl --user restart transmission-mcp.service
systemctl --user --no-pager status hermes.service hermes-sandbox.service || true

# Profiles using the SSH sandbox as terminal backend. Idempotent.
HX=(podman exec -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes /opt/hermes/.venv/bin/hermes)
for _ in $(seq 30); do podman exec hermes true 2>/dev/null && break; sleep 1; done

# Profiles are Hermes distributions (profiles/<name>/distribution.yaml, config.yaml, skills/).
# Machine-specific SSH settings stay here; the distribution carries only portable config.
setup_ssh_profile() {
    local profile="$1" dir="/opt/data/profiles/$1" src="$(dirname "$SRC_DIR")/profiles/$1" tmp="/tmp/dist-$1"
    podman exec hermes rm -rf "$tmp"
    podman cp "$src" "hermes:$tmp"
    # --force installs over an existing profile (user data kept) and also converts profiles
    # created before they were distributions; `profile update` would fail on those and needs the source dir kept.
    "${HX[@]}" profile install "$tmp" --name "$profile" --force --yes
    podman exec hermes rm -rf "$tmp"
    podman exec -u hermes hermes mkdir -p -m 700 "$dir/ssh"
    podman exec -i -u hermes hermes sh -c "cat > $dir/ssh/id_ed25519 && chmod 600 $dir/ssh/id_ed25519" < "$KEY_DIR/id_ed25519"
    podman exec -i -u hermes hermes sh -c "
        f=$dir/.env; touch \$f
        sed -i '/^TERMINAL_SSH_\(HOST\|USER\|PORT\|KEY\)=/d' \$f
        cat >> \$f" <<ENVEOF
TERMINAL_SSH_HOST=hermes-sandbox
TERMINAL_SSH_USER=dev
TERMINAL_SSH_PORT=22
TERMINAL_SSH_KEY=$dir/ssh/id_ed25519
ENVEOF
}

setup_ssh_profile coder-remote
setup_ssh_profile code-reviewer

# Transmission MCP skill. The server itself is registered by hand (dashboard or config.yaml):
#   mcp_servers: {transmission: {url: http://127.0.0.1:8650/mcp}}
if [[ -n "${WITH_TRANSMISSION_MCP:-}" ]]; then
    podman exec hermes rm -rf /opt/data/skills/transmission-download
    podman cp "$(dirname "$SRC_DIR")/skills/transmission-download" hermes:/opt/data/skills/transmission-download
    podman exec hermes chown -R hermes:hermes /opt/data/skills/transmission-download
fi
