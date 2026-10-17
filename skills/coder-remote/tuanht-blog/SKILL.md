---
name: tuanht-blog
description: "Use for any code-change task on the tuanht-blog repo: delegate the coding to Claude Code in the SSH sandbox via claude-implement, then hand the PR to code-reviewer."
version: 2.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [git, blog, sandbox, claude-code]
    requires_toolsets: [terminal]
---

# tuanht-blog

You are the coordinator. **Claude Code writes the code**, inside `hermes-sandbox`, through the script
`claude-implement`. You do not edit repo files yourself with `write_file`/`patch`/shell redirects, and you do not
write the implementation with your own model. The terminal backend is SSH, so terminal commands already run in
the sandbox as user `dev`.

## When to Use
Any task that changes the tuanht-blog repository (`git@github.com:tuanht/tuanht-blog.git`, checkout `/home/dev/work/tuanht-blog`).

## Inputs (from the ticket)
- The ticket body is the spec. Keep it verbatim.
- Optional `implement-model: <alias>` line (default `sonnet`, `opus` for hard tasks). `build: true` allows Claude to run
  `npm ci` / `npm run` (default off). Optional `branch:` line, else derive `task/<short-slug>` from the title.
- `claude-model:` and `focus:` lines are for the reviewer; leave them in the ticket.

## Procedure
1. Check auth: `ssh -T git@github.com`. Without a greeting, `kanban_block` (kind `capability`) and stop.
2. Write the spec to a file in the sandbox: `mkdir -p ~/work/.tasks` then write the full ticket body (goal,
   requirements, out of scope) to `~/work/.tasks/<task-id>.spec.md`. Use a heredoc via the terminal tool.
3. Start the implementer in the background (it takes minutes):
   `nohup claude-implement tuanht/tuanht-blog --branch task/<slug> --spec-file ~/work/.tasks/<task-id>.spec.md --model <alias> --title "<ticket title>" [--build] > ~/work/.tasks/<task-id>.out 2>&1 &`
4. Poll `tail -n 5 ~/work/.tasks/<task-id>.out` every 20-30 s (call `heartbeat` if available) until a line `DONE`. Give up after ~40 min.
5. Read the final lines:
   - `ERROR:` line -> `kanban_block` with that error (kind `needs_input` for a dirty checkout or existing branch, `capability` for auth/push problems).
   - `PR_URL=...` -> success. Else if `COMPARE_URL=...` was printed, `gh pr create` failed: report that URL for a manual PR.
6. Read the generated PR description (`SUMMARY=<path>`) and check it matches the spec. If it clearly does not, say so in the hand-off; do not fix the code yourself.
7. Hand off for review. Do NOT complete the task and do NOT merge:
   `kanban_request_review(summary="<PR URL + files changed + what Claude reported as verified>", reviewer="code-reviewer")`.

## Pitfalls
- Never write or patch repo files with Hermes tools, and never run `git commit`/`git push` yourself; if `claude-implement` fails, report it.
- Never force-push or push to the default branch. Never create a `main` branch.
- Never print, copy or commit private keys, `.env` files or tokens.
- Re-running with an existing branch name fails by design; choose a new slug and say so in the summary.
- Hermes provider API keys are not available in the sandbox; Claude Code there uses its own login and model (`--model`).

## Verification
The ticket ends in `review` assigned to `code-reviewer`, and its summary contains the PR URL.
