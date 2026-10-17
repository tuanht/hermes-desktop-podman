# hermes-desktop

Official [Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/docker) image
(`nousresearch/hermes-agent`) run under rootless Podman, managed by systemd user Quadlets
that start at boot without a login. One container runs the gateway and the dashboard together.

## Layout

- `quadlet/hermes.container` — container unit (source of truth)
- `quadlet/hermes.volume` — named volume `hermes-data`, mounted at `/opt/data`
- `quadlet/hermes.env.example` — secret template
- `quadlet/hermes-sandbox.{container,volume}`, `quadlet/hermes.network` — Ubuntu dev sandbox for the `coder-remote` profile, and the shared network
- `sandbox/` — Containerfile (Ubuntu 24.04: sshd, git, Claude Code, Node 22, Python, Go, build tools)
- `install.sh` — installs units, creates the secret file once, runs first-time setup, starts the service

## Install

```bash
./install.sh
```

On first run the script creates `~/.config/hermes/hermes.env` (mode 600) with random dashboard
credentials, pulls the image, installs the units, enables linger, runs the interactive
`hermes setup` wizard once (writes API keys into the volume), and starts `hermes.service`.
It also removes the old `hermes-desktop` unit if present; the old `hermes-home` volume is left alone.

## Access (loopback only)

| Surface | Address | Login |
|---|---|---|
| Dashboard | http://127.0.0.1:9119 | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` in `hermes.env` |
| Gateway API / health | http://127.0.0.1:8642 | `API_SERVER_KEY` if the API server is enabled |

## Operate

```bash
systemctl --user status hermes.service
systemctl --user restart hermes.service
journalctl --user -u hermes.service -f
podman logs -f hermes
podman exec -it hermes /opt/hermes/.venv/bin/hermes      # interactive CLI
podman run -it --rm -v hermes-data:/opt/data:Z docker.io/nousresearch/hermes-agent setup   # rerun wizard
```

Upgrade: `podman pull docker.io/nousresearch/hermes-agent:latest && systemctl --user restart hermes.service`
(config migrations run automatically with backups). The unit also has `AutoUpdate=registry`, so
`podman auto-update` works if you enable `podman-auto-update.timer` for the user.

## coder-remote profile (SSH backend)

`install.sh` builds `localhost/hermes-sandbox`, runs it as `hermes-sandbox.service` on the `hermes`
network (no published ports), and creates the Hermes profile `coder-remote` with
`terminal.backend=ssh` pointing at `dev@hermes-sandbox`, cwd `/home/dev/work`. The key pair lives in
`~/.config/hermes/coder-remote/`; the private key is copied into the profile at
`/opt/data/profiles/coder-remote/ssh/`. Re-running the script is idempotent.

```bash
podman exec -it -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes /opt/hermes/.venv/bin/hermes -p coder-remote chat
podman exec -it -u dev hermes-sandbox claude     # one-time Claude Code login (kept in hermes-sandbox-home)
podman exec -it -u dev hermes-sandbox bash       # shell in the sandbox
```

Hermes provider keys are never forwarded to the remote host; Claude Code authenticates inside the sandbox.
Messaging channels are not cloned into the profile; configure them with `hermes -p coder-remote setup`.
Rebuild the image by rerunning `./install.sh`.

## Notes

- Quadlet units are generated, so there is no `systemctl enable`. Boot start comes from `WantedBy=default.target` plus linger.
- Never run two gateway containers against the same data volume.
- The dashboard binds 0.0.0.0 inside the container, so auth is mandatory; ports are published on 127.0.0.1 only.
- The volume mounts with `:Z` for SELinux; a named volume avoids SQLite WAL problems seen with VM-backed bind mounts.
- `ShmSize=1g` is for the Playwright browser tools.
