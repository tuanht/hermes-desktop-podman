# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Deployment config, not an application: runs the official `nousresearch/hermes-agent` image (gateway + dashboard in one container) under rootless Podman as systemd user Quadlets that start at boot via linger. Follows https://hermes-agent.nousresearch.com/docs/user-guide/docker. There is no build system, test suite, or linter. See `README.md` for access ports and operations.

## Commands

```bash
./install.sh                                   # pull image, install units, enable linger, first-time setup wizard, (re)start service
systemctl --user restart hermes.service
journalctl --user -u hermes.service -f
podman logs -f hermes
```

## Architecture

- `quadlet/hermes.container` and `quadlet/hermes.volume` are the source of truth. `install.sh` copies them to `~/.config/containers/systemd/`; editing the installed copies is overwritten on the next install. After changing them, rerun `./install.sh` (does daemon-reload + restart).
- Quadlet units are generated, so never `systemctl enable`; boot start comes from `[Install] WantedBy=default.target` plus `loginctl enable-linger`.
- Secrets: `~/.config/hermes/hermes.env` (mode 600) is created once by `install.sh` from `quadlet/hermes.env.example` with random dashboard basic-auth credentials and is never overwritten. It lives outside the repo.
- State lives in the named volume `hermes-data` (from `hermes.volume`) mounted at `/opt/data` with `:Z`. Ports publish on 127.0.0.1 only (8642 gateway API, 9119 dashboard). Dashboard auth is mandatory because the container binds 0.0.0.0.
- `coder-remote` profile: `hermes-sandbox.container` (image built from `sandbox/` by `install.sh`) shares the `hermes` network with `hermes.container`; `install.sh` creates the profile via `podman exec` and writes `TERMINAL_SSH_*` into the profile `.env` in the volume. Unit file names matter: `Volume=hermes-sandbox.volume` references the Quadlet file, not the volume name.
- Profiles are Hermes distributions: `profiles/<name>/{distribution.yaml,config.yaml,skills/}`. `install.sh` `podman cp`s each into the container and runs `hermes profile install <dir> --name <name>` (or `profile update --force-config` when it exists), so `config.yaml` here is authoritative and overwrites runtime edits on every install. Machine-specific bits (SSH key, `TERMINAL_SSH_*` in the profile `.env`) stay in `setup_ssh_profile` in `install.sh`, never in the distribution. `coder-remote` (implementer) and `code-reviewer` (picks Kanban `review` tasks, runs Claude Code in the sandbox) share the sandbox and SSH key. Both only coordinate: code is written by Claude Code in the sandbox via `sandbox/claude_implement.py`, reviews via `sandbox/pr_review.py` (Python scripts with a shared `hermes_sandbox.py`, baked into the image as the commands `claude-implement` / `pr-review`, so skills call them by those names; push/PR creation stays in the script, never with the model, and happens only after the reviewer approves via `claude-implement --publish --expect-sha`).
- `Exec=gateway run` plus `HERMES_DASHBOARD=1` runs gateway and dashboard together under s6-overlay; do not override the entrypoint, and never run a second gateway on the same volume.
