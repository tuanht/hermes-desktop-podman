---
name: tuanht-blog
description: "Use for any code-change task on the tuanht-blog repo: delegate the coding to Claude Code in the SSH sandbox via claude-implement (commit locally), get it reviewed by code-reviewer, and publish the PR only after approval."
version: 3.0.0
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

**Nothing is pushed until the reviewer approves.** Work is committed locally on a branch; the reviewer reads that
local branch; only then does a publish task push it and open the PR.

## When to Use
Any task that changes the tuanht-blog repository (`git@github.com:tuanht/tuanht-blog.git`, checkout `/home/dev/work/tuanht-blog`).

## Inputs (from the ticket)
- The ticket body is the spec. Keep it verbatim.
- Optional `implement-model: <alias>` line (default `sonnet`, `opus` for hard tasks). `build: true` allows Claude to run
  `npm ci` / `npm run` (default off). Optional `branch:` line, else derive `task/<short-slug>` from the title.
- `claude-model:` and `focus:` lines are for the reviewer; leave them in the ticket.
- Which of the three jobs below applies:
  - the ticket has a line `publish: true` (created by the reviewer after approval) -> **C. Publish**;
  - the task context shows a reviewer's requested changes (a `changes_requested` reason, usually the newest comment),
    a `pr: <N>` line, or a human comment asks for changes to an existing branch/PR -> **B. Rework**;
  - otherwise -> **A. New work**.

## A. New work
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
   - `ERROR:` -> `kanban_block` with that error (kind `needs_input` for a dirty checkout or existing branch, `capability` for auth problems).
   - `BRANCH=`, `COMMITS=<1 or more>` and `HEAD_SHA=<sha>` -> success, continue. There is NO PR yet; that is intended.
5. Read the generated PR description (`cat` the file named by `SUMMARY=`) and check it matches the ticket. If it clearly does not, say so in the hand-off; do not fix the code yourself.
6. Hand off, **only now and only if you have a `HEAD_SHA=` line**:
   `kanban_request_review(summary="repo: tuanht/tuanht-blog\nbranch: <branch>\nhead_sha: <sha>\n<files changed + what Claude reported as verified>", reviewer="code-reviewer")`.
   The `repo`, `branch` and `head_sha` lines are mandatory: the reviewer reads the local branch from them.
   Do NOT complete the task, do NOT push, do NOT open a PR.

## B. Rework (reviewer asked for changes, or a human gave feedback)
The loop: you implement -> `kanban_request_review` -> `code-reviewer` approves, or calls `kanban_request_changes`,
which hands the task back to you with the reason. You rework and request review again, until the reviewer approves.
Rework is also local: **commit, do not push.**

1. Find the branch (your earlier hand-off, or a `branch:` line) or the PR number (a `pr: <N>` line).
2. Spec = the newest reviewer reason or human comment, verbatim (not the original ticket body):

   ```bash
   claude-implement tuanht/tuanht-blog --branch <branch> --continue --model <alias> --spec-file - --background <<'SPEC'
   <the newest changes_requested reason / feedback comment, verbatim>
   SPEC
   ```

   If the feedback concerns an already-open PR, write `--pr <N>` in place of `--branch <branch> --continue`; the script
   takes the PR's own branch. It still only commits locally. Poll as in A.3-A.4; success is `COMMITS=` 1 or more and a new `HEAD_SHA=`.
3. `kanban_request_review` as in A.6, with the new `head_sha` and a summary of what changed this round.
4. After **5 rework rounds** on one branch, stop looping: `kanban_block` (kind `needs_input`) with a summary of the
   disagreement so a human decides.

## C. Publish (only after the reviewer approved)
The reviewer creates a task with `publish: true`, `repo`, `branch` (or `pr`), and `approved_sha`. Run exactly:

```bash
claude-implement tuanht/tuanht-blog --branch <branch> --publish --expect-sha <approved_sha> --background
```

(use `--pr <N>` instead of `--branch <branch>` when the task has a `pr:` line). Poll the log to `DONE`. The script
refuses unless the branch head equals `approved_sha`, so it can never publish unreviewed commits. On `ERROR:` ->
`kanban_block` (do not work around it). On `PR_URL=` -> `kanban_complete` with the PR URL in the summary. That is the whole task.

## Pitfalls
- Never write or patch repo files with Hermes tools, and never run `git commit`/`git push`/`gh pr create` yourself; only `claude-implement` does.
- Push and PR creation happen **only** in job C, **only** after the reviewer approved. Never push in jobs A/B. After approval,
  no further commits: late ideas go in a ticket comment for the human.
- Never force-push or push to the default branch. Never create a `main` branch.
- Never print, copy or commit private keys, `.env` files or tokens.
- Re-running `--branch` without `--continue` on an existing branch fails by design.
- Never claim the work started, finished or passed unless a log line shows it.
- Hermes provider API keys are not available in the sandbox; Claude Code there uses its own login and model (`--model`).

## Verification
- A/B: the ticket sits in `review` assigned to `code-reviewer`, and its summary has `branch` and `head_sha`.
- C: the ticket is `done` and its summary contains the PR URL.
