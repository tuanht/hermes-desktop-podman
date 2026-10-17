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

# Profiles using the SSH sandbox as terminal backend. Idempotent.
HX=(podman exec -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes /opt/hermes/.venv/bin/hermes)
for _ in $(seq 30); do podman exec hermes true 2>/dev/null && break; sleep 1; done

setup_ssh_profile() {
    local profile="$1" desc="$2" dir="/opt/data/profiles/$1" f name dest
    if ! "${HX[@]}" profile list 2>/dev/null | grep -qw "$profile"; then
        "${HX[@]}" profile create "$profile" --clone
    fi
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
    # Project skills (skills/<profile>/<name>/SKILL.md) go into that profile only.
    for f in "$(dirname "$SRC_DIR")/skills/$profile"/*/SKILL.md; do
        [[ -f "$f" ]] || continue
        name="$(basename "$(dirname "$f")")"
        dest="$dir/skills/software-development/$name"
        podman exec -u hermes hermes mkdir -p "$dest"
        podman exec -i -u hermes hermes sh -c "cat > $dest/SKILL.md" < "$f"
    done
    "${HX[@]}" profile describe "$profile" --text "$desc"
    "${HX[@]}" -p "$profile" config set terminal.backend ssh
    "${HX[@]}" -p "$profile" config set terminal.cwd /home/dev/work
    # Default per-command timeout is 60s in .env; raise it so slow git/npm/claude calls are not killed.
    "${HX[@]}" -p "$profile" config set terminal.timeout 600
}

setup_ssh_profile coder-remote "Implements code changes in the SSH dev sandbox."
# Reviewer: picks tasks in the Kanban review column and runs Claude Code in the sandbox.
setup_ssh_profile code-reviewer "Reviews code and pull requests using Claude Code in the SSH dev sandbox."
# Coordinator model only; the review itself runs in Claude Code (sonnet by default, per-ticket override).
"${HX[@]}" -p code-reviewer config set model.default grok-4.6
# Coordinator model only; Claude Code in the sandbox writes the code. A small local model
# (qwen3.5:9b) ignored the skill, pushed the wrong branch and opened a PR, so use a hosted model.
"${HX[@]}" -p coder-remote config set model.provider xai-oauth
"${HX[@]}" -p coder-remote config set model.base_url https://api.x.ai/v1
"${HX[@]}" -p coder-remote config set model.default grok-4.6
"${HX[@]}" -p coder-remote config unset model.context_length
