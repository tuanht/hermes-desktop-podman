---
name: tuanht-blog
description: "Use for any task on the tuanht-blog repo (git@github.com:tuanht/tuanht-blog.git): clone/update it in the SSH sandbox, edit, commit, push."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [git, blog, sandbox]
    requires_toolsets: [terminal]
---

# tuanht-blog

Work on the blog repo inside the `hermes-sandbox` container. The `coder-remote` profile's terminal
backend is SSH, so every terminal command already runs there as user `dev`.

## When to Use
Any task that reads, changes, builds or publishes the tuanht-blog repository.

## Environment
- Repo: `git@github.com:tuanht/tuanht-blog.git`, checked out at `/home/dev/work/tuanht-blog`.
- Tools in the sandbox: git, Node 22 + npm, Python 3, Go, build-essential, ripgrep, Claude Code (`claude`).
- Git identity and the GitHub key (`~/.ssh/id_ed25519_github`, a deploy key with write access) are preconfigured.
- Run everything through the terminal tool. Do not use the Hermes container's own filesystem.

## Procedure
1. Check auth: `ssh -T git@github.com`. A greeting means OK. On "Permission denied", stop and report
   that the deploy key is missing or lacks write access. Do not try other keys or HTTPS tokens.
2. Get the repo:
   - missing: `cd /home/dev/work && git clone git@github.com:tuanht/tuanht-blog.git`
   - present: `cd /home/dev/work/tuanht-blog && git status --short` (stop if dirty and not yours), then `git pull --ff-only`.
3. Learn the project before changing it: read `README*`, `package.json`/build config, and the layout.
   Reuse the repo's own scripts (build, lint, preview) rather than inventing commands.
4. Make changes on a branch named `task/<short-slug>` cut from the repo's default branch.
5. Verify with the repo's build/lint/test scripts. Report their result honestly, including failures.
6. Commit with a clear message, then `git push -u origin task/<short-slug>`.
7. Report: branch name, commit hashes, files changed, verification result.

## Pitfalls
- Never force-push, rewrite history, or push directly to the default branch unless the task says so explicitly.
- Never create a `main` branch; use whatever default branch the repo already has.
- Never print, copy or commit private keys, `.env` files or tokens.
- Don't run `npm install` globally or as root; install project dependencies locally in the repo.
- Hermes provider API keys are not available in the sandbox; Claude Code there uses its own login.

## Verification
`git status` is clean, `git log origin/<branch> -1` matches local HEAD, and the report lists the pushed branch.
