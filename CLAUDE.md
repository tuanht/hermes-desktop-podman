# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Deployment config, not an application: runs `neoplanetz/hermes-desktop-docker` (Hermes Agent + XFCE desktop + headed CDP browser) under rootless Podman as a systemd user Quadlet that starts at boot via linger. There is no build system, test suite, or linter. See `README.md` for access ports and operations.

## Commands

```bash
./install.sh                                   # build image if missing, install unit, enable linger, (re)start service
podman build -t localhost/hermes-desktop-custom:latest -f image/Containerfile image/   # rebuild derived image (needed after base image pull or Containerfile edits; install.sh only builds when the image is absent)
systemctl --user restart hermes-desktop.service
journalctl --user -u hermes-desktop.service -f
podman logs -f hermes-desktop
```

## Architecture

- `quadlet/hermes-desktop.container` is the source of truth for the unit. `install.sh` copies it to `~/.config/containers/systemd/`; editing the installed copy is overwritten on the next install. After changing it, rerun `./install.sh` (does daemon-reload + restart).
- Quadlet units are generated, so never `systemctl enable`; boot start comes from `[Install] WantedBy=default.target` plus `loginctl enable-linger`.
- `Init=` is unsupported by this Podman's Quadlet, so `--init` goes through `PodmanArgs=`.
- Secrets: `~/.config/hermes-desktop/hermes.env` (mode 600) is created once by `install.sh` from `quadlet/hermes.env.example` with a random `HERMES_PASSWORD` and is never overwritten. It lives outside the repo.
- State lives in the named volume `hermes-home` mounted at `/home/hermes` with `:Z` (SELinux MCS labels otherwise block the container from reading its home). Ports publish on 127.0.0.1 only; host RDP is 3390 -> container 3389; CDP 9222 is intentionally unpublished.
- The unit runs `localhost/hermes-desktop-custom:latest`, built from `image/Containerfile` on top of the upstream image. The Containerfile patches the base image at build time, some by string-replacing files (`/entrypoint.sh`, `tools/browser_tool.py`) with `assert s.count(anchor) == 1`. If the build fails on one of those asserts after a base image update, the upstream text changed and the anchor/patch must be updated. The patches: Telegram package into the Hermes venv, Node/npm relocated to `/opt/node` for the non-root `hermes` user, prebuilt TUI with `HERMES_TUI_DIR` (also exported via `/etc/profile.d` because the entrypoint uses `su -` which drops ENV), a non-fatal `hermes gateway run` launch injected before the `# NoVNC` marker in the entrypoint, and a `browser_vision` fix that puts the real screenshot path in the model-visible text.
