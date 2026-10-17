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
- `skills/<profile>/<name>/SKILL.md` — project skills, installed into that profile only (`coder-remote/tuanht-blog`, `coder-reviewer/blog-review`)
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

### Local LLM (host Ollama)

The `coder-remote` profile uses the Ollama server on the host (`OLLAMA_HOST=0.0.0.0:11434`)
through `http://host.containers.internal:11434/v1` (provider `custom`). Model: `qwen3.5:9b`,
which fits fully in 16GB VRAM at the full 262144 context (~11GB, 100% GPU). `install.sh`
sets `model.provider/base_url/default/context_length` idempotently. To switch models, pull
one on the host (`ollama pull <name>`) and run
`hermes -p coder-remote config set model.default <name>` inside the container.
Larger models (e.g. `qwen3-coder:30b`, 18.5GB) spill to CPU at max context.

### GitHub access from the sandbox

The sandbox pushes with its own key, kept in the `hermes-sandbox-home` volume (not created by `install.sh`).
Create it once (skips if present), then print the public key:

```bash
podman exec -u dev hermes-sandbox bash -c '[ -f ~/.ssh/id_ed25519_github ] || ssh-keygen -q -t ed25519 -N "" -C hermes-sandbox -f ~/.ssh/id_ed25519_github'
podman exec -u dev hermes-sandbox cat /home/dev/.ssh/id_ed25519_github.pub
```

Add it on GitHub as a **deploy key with write access** on each repo (Settings → Deploy keys), or as an
account SSH key (broader access). Then check with `podman exec -u dev hermes-sandbox ssh -T git@github.com`.
One-time sandbox config: `~/.ssh/config` with `Host github.com`, `IdentityFile ~/.ssh/id_ed25519_github`,
`IdentitiesOnly yes`; `ssh-keyscan github.com >> ~/.ssh/known_hosts`; and `git config --global user.name/user.email`.

### Opening pull requests with `gh`

A deploy key can push branches but cannot call the GitHub API, so PRs need a token. The sandbox image
ships the GitHub CLI (`gh`); give it a **fine-grained personal access token** limited to the one repo.

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Resource owner: your account. Expiration: short (e.g. 30–90 days).
3. Repository access: **Only select repositories** → `tuanht-blog`.
4. Repository permissions: **Pull requests: Read and write**, **Contents: Read and write** (`gh` reads repo metadata with Metadata, which is added automatically). Leave everything else at *No access*. No account permissions.
5. Generate, copy the token (shown once), then store it in the sandbox. Paste it when prompted; it is kept in the `hermes-sandbox-home` volume (`~/.config/gh/hosts.yml`), never in this repo:

```bash
podman exec -it -u dev hermes-sandbox gh auth login --hostname github.com --git-protocol ssh --with-token
podman exec -u dev hermes-sandbox gh auth status
podman exec -u dev hermes-sandbox gh pr list -R tuanht/tuanht-blog   # sanity check
```

Git pushes keep using the SSH deploy key; the token is only for `gh` API calls (`gh pr create`, `gh pr comment`).
Rotate by generating a new token and rerunning the login command; revoke it on GitHub to cut access.
The token is readable by anything running as `dev` in the sandbox, which is why it is scoped to a single repo.

### Reviewer profile (`coder-reviewer`)

Same SSH sandbox and key as `coder-remote`, own skill `blog-review`. Flow: a ticket lands in the Kanban
**review** column assigned to `coder-reviewer` (`kanban.review_dispatch: true`); the gateway dispatcher
starts the worker, which runs a read-only `claude -p` review in the sandbox, comments on the ticket and the PR
(`gh pr comment`, never approve/merge), then ends with `kanban_complete` or `kanban_request_changes`.
An implementer can hand over with `hermes kanban request-review <id> --reviewer coder-reviewer`.

```bash
hermes kanban assign <id> coder-reviewer                       # or drag to Review and assign in the dashboard
```

**Which model?** There are two separate models. Kanban `--model/--provider` (and `kanban set-model <id> <model>`)
pins the *Hermes worker* (the coordinator). The *Claude Code* review model defaults to `sonnet` and is chosen by a
`claude-model: opus` line in the ticket body (aliases `sonnet`, `opus`, `haiku`, or a full model id); the skill passes it as
`claude --model`. Optional `focus: security` steers the review. The reviewer's Hermes model is inherited from the
default profile; change it with `hermes -p coder-reviewer config set model.default <model>`.

```bash
hermes kanban create "Review PR 12" --assignee coder-reviewer --skill blog-review --body $'PR: https://github.com/tuanht/tuanht-blog/pull/12\nclaude-model: opus\nfocus: accessibility'
```

### Skills and Kanban tasks

`skills/coder-remote/tuanht-blog/SKILL.md` holds the blog workflow (clone/pull, branch, verify, push).
`install.sh` copies `skills/<profile>/*/SKILL.md` into `/opt/data/profiles/<profile>/skills/software-development/`.
Edit the file in this repo and rerun `./install.sh` (or `/reload-skills`). Tasks then stay short:

```bash
podman exec -u hermes -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes /opt/hermes/.venv/bin/hermes \
  kanban create "Clone tuanht-blog and report its stack" --skill tuanht-blog
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
