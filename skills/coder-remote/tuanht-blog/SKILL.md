---
name: tuanht-blog
description: "Use for any code-change task on the tuanht-blog repo: delegate the coding to Claude Code in the SSH sandbox via claude-implement, then hand the PR to code-reviewer."
version: 2.1.0
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
2. Launch. Run exactly ONE terminal command, with the ticket body pasted **verbatim** inside the heredoc (do not
   summarise, reword or add requirements). No `nohup`, no `&`, no redirects, no quotes around the whole command:

   ```bash
   claude-implement tuanht/tuanht-blog --branch task/<slug> --model <alias> --title "<ticket title>" --spec-file - --background <<'SPEC'
   <ticket body, verbatim>
   SPEC
   ```

   Add `--build` only if the ticket has `build: true`. It prints `STARTED=yes` and `LOG=<path>`. If it prints anything
   else, or an error, run `kanban_block` with that output; do not improvise a different launch.
3. Poll: `tail -n 8 <LOG path>` every 20-30 s (call `heartbeat` if available) until a line `DONE` appears. Give up after ~40 min.
   While waiting, do nothing else: no comments claiming success, no review request.
4. Read the final lines:
   - `ERROR:` -> `kanban_block` with that error (kind `needs_input` for a dirty checkout or existing branch, `capability` for auth/push problems).
   - `PR_URL=https://...` -> success, continue.
   - `COMPARE_URL=` but no `PR_URL=` -> the PR was not created: `kanban_block` (kind `needs_input`) and give that URL.
5. Read the generated PR description (`cat` the file named by `SUMMARY=`) and check it matches the ticket. If it clearly does not, say so in the hand-off; do not fix the code yourself.
6. Hand off, **only now and only if you have a `PR_URL=` line**: `kanban_request_review(summary="<PR URL + files changed + what Claude reported as verified>", reviewer="code-reviewer")`.
   Never call it before the PR exists. Do NOT complete the task and do NOT merge.

## Pitfalls
- Never write or patch repo files with Hermes tools, and never run `git commit`/`git push` yourself; if `claude-implement` fails, report it.
- Never force-push or push to the default branch. Never create a `main` branch.
- Never print, copy or commit private keys, `.env` files or tokens.
- Re-running with an existing branch name fails by design; choose a new slug and say so in the summary.
- Never claim the work started, finished or passed unless a log line shows it.
- Hermes provider API keys are not available in the sandbox; Claude Code there uses its own login and model (`--model`).

## Verification
The ticket ends in `review` assigned to `code-reviewer`, and its summary contains the PR URL.
