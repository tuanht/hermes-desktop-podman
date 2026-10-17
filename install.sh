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

for u in hermes.volume hermes.container hermes.network \
         hermes-sandbox.volume hermes-sandbox.container; do
    install -m 0644 "$SRC_DIR/$u" "$UNIT_DIR/$u"
done

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
systemctl --user --no-pager status hermes.service hermes-sandbox.service || true

# coder-remote profile: SSH terminal backend pointing at the sandbox. Idempotent.
HX=(podman exec -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes /opt/hermes/.venv/bin/hermes)
for _ in $(seq 30); do podman exec hermes true 2>/dev/null && break; sleep 1; done
if ! "${HX[@]}" profile list 2>/dev/null | grep -qw coder-remote; then
    "${HX[@]}" profile create coder-remote --clone
fi
PROFILE_DIR=/opt/data/profiles/coder-remote
podman exec -u hermes hermes mkdir -p -m 700 "$PROFILE_DIR/ssh"
podman exec -i -u hermes hermes sh -c "cat > $PROFILE_DIR/ssh/id_ed25519 && chmod 600 $PROFILE_DIR/ssh/id_ed25519" < "$KEY_DIR/id_ed25519"
podman exec -i -u hermes hermes sh -c "
    f=$PROFILE_DIR/.env; touch \$f
    sed -i '/^TERMINAL_SSH_\(HOST\|USER\|PORT\|KEY\)=/d' \$f
    cat >> \$f" <<ENVEOF
TERMINAL_SSH_HOST=hermes-sandbox
TERMINAL_SSH_USER=dev
TERMINAL_SSH_PORT=22
TERMINAL_SSH_KEY=$PROFILE_DIR/ssh/id_ed25519
ENVEOF
# Project skills (skills/<name>/SKILL.md) go into the coder-remote profile only.
for f in "$(dirname "$SRC_DIR")"/skills/*/SKILL.md; do
    name="$(basename "$(dirname "$f")")"
    dest="$PROFILE_DIR/skills/software-development/$name"
    podman exec -u hermes hermes mkdir -p "$dest"
    podman exec -i -u hermes hermes sh -c "cat > $dest/SKILL.md" < "$f"
done
"${HX[@]}" -p coder-remote config set terminal.backend ssh
"${HX[@]}" -p coder-remote config set terminal.cwd /home/dev/work
# Local LLM: host Ollama (listens on 0.0.0.0:11434) reached via host.containers.internal.
# qwen3.5:9b (Q4_K_M) fits fully in 16GB VRAM at the full 262144 context (~11GB, 100% GPU).
# Pull it first on the host: ollama pull qwen3.5:9b
"${HX[@]}" -p coder-remote config set model.provider custom
"${HX[@]}" -p coder-remote config set model.base_url http://host.containers.internal:11434/v1
"${HX[@]}" -p coder-remote config set model.default qwen3.5:9b
"${HX[@]}" -p coder-remote config set model.context_length 262144
