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
- `Exec=gateway run` plus `HERMES_DASHBOARD=1` runs gateway and dashboard together under s6-overlay; do not override the entrypoint, and never run a second gateway on the same volume.
