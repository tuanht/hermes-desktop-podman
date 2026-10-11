# hermes-desktop

Hermes Agent with a desktop and headed browser, run from `neoplanetz/hermes-desktop-docker`
under rootless Podman, managed by a systemd user Quadlet that starts at boot without a login.

## Layout

- `quadlet/hermes-desktop.container` — Quadlet unit (source of truth)
- `quadlet/hermes.env.example` — secret template
- `install.sh` — installs the unit, creates the secret file once, starts the service

## Install

```bash
./install.sh
```

The script creates `~/.config/hermes-desktop/hermes.env` (mode 600) with a random `HERMES_PASSWORD`
on first run, copies the unit to `~/.config/containers/systemd/`, enables linger for the user, and starts the service.

## Access (loopback only)

| Surface | Address | Login |
|---|---|---|
| NoVNC | http://127.0.0.1:6080/vnc.html | VNC password |
| VNC | 127.0.0.1:5901 | VNC password |
| RDP | 127.0.0.1:3390 | `hermes` / `HERMES_PASSWORD` |
| Dashboard | http://127.0.0.1:9119 | `hermes` / `HERMES_PASSWORD` |

The CDP port 9222 is inside the container only and is not published.

## Operate

```bash
systemctl --user status hermes-desktop.service
systemctl --user restart hermes-desktop.service
journalctl --user -u hermes-desktop.service -f
podman logs -f hermes-desktop
```

Update the image: `podman pull docker.io/neoplanetz/hermes-desktop-docker:latest` then restart the service.

Data lives in the named volume `hermes-home` (mounted at `/home/hermes`).

## Notes

- Quadlet units are generated, so there is no `systemctl enable`. Boot start comes from `WantedBy=default.target` plus linger.
- `Init=` is not supported by this Podman's Quadlet, so `--init` is passed via `PodmanArgs=`.

## Derived image (`image/Containerfile`)

The unit runs `localhost/hermes-desktop-custom:latest`, built on top of `neoplanetz/hermes-desktop-docker`. It adds:

1. The Telegram Python package (`python-telegram-bot==22.6`) into the Hermes venv.
2. Node/npm copied to `/opt/node` and linked into `/usr/local/bin`, so the `hermes` user can run them. Plus a prebuilt TUI (`HERMES_TUI_DIR`) for dashboard Chat.
3. A non-fatal launch of `hermes gateway run` from the entrypoint, so Telegram comes back after a container recreate.

Rebuild after pulling a new base image: `podman build -t localhost/hermes-desktop-custom:latest -f image/Containerfile image/`, then `./install.sh`.

The volume mounts with `:Z` because SELinux MCS labels on the named volume otherwise block the container from reading its own home directory.
