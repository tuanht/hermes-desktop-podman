---
name: pr-review
description: "Use for Kanban review tasks on a GitHub pull request (any repo the sandbox can read; bare PR numbers mean tuanht/tuanht-blog): run a Claude Code review in the SSH sandbox, post findings to the PR and ticket, then complete or request changes."
version: 2.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [review, git, sandbox, claude-code]
    requires_toolsets: [terminal]
---

# pr-review

Review a tuanht-blog pull request by delegating the reading to Claude Code inside `hermes-sandbox`.
This profile's terminal backend is SSH, so every terminal command runs there as user `dev`.
Hermes itself only coordinates; Claude Code does the review.

## When to Use
A task in the Kanban `review` column (or assigned to this profile) that points at either
- a **local branch** of the sandbox checkout (hand-off summary has `repo:`, `branch:` and `head_sha:` lines): the coder has
  committed but NOT pushed; nothing is on GitHub yet; or
- an already published **PR** (URL, `owner/repo#N`, or `N`).

## Inputs (from the task body/context; if missing, `kanban_block` with kind `needs_input`)
- Local branch: `repo`, `branch`, `head_sha` from the newest hand-off summary (`kanban_show`).
- Or a PR URL, `owner/repo#N`, or just `N` (means `tuanht/tuanht-blog`). Works for any repo the sandbox can read.
- Optional `claude-model: <alias>` line. Default `sonnet`; use `opus` for deep reviews. This is the Claude Code
  model, separate from the Hermes worker model that Kanban `--model` pins.
- Optional `focus: <text>` line (security, accessibility, ...).
- Optional `no-post: true` line to skip the PR comment, `build: true` to run the repo's build/lint (see Pitfalls).

## Procedure
All the mechanics live in the sandbox script `pr-review`, so do not reimplement them by hand.
1. Start it in the background (a review takes minutes, longer than one terminal call):
   - local branch: `mkdir -p ~/work/.reviews && nohup pr-review --branch "<branch>" --repo "<repo>" --model <alias> --focus "<text>" [--build] > ~/work/.reviews/run-$$.out 2>&1 &`
   - published PR: `... nohup pr-review "<PR>" --model <alias> --focus "<text>" [--no-post] [--build] > ... &`
   Note the output file path.
2. Poll with `tail -n 5 <file>` every 20-30 s (use `heartbeat` if the tool exists) until a line `DONE` appears. Give up after ~25 min.
3. Read the final lines: `VERDICT=`, `HEAD_SHA=` (the exact commit reviewed), `REPORT=<path>`, `POSTED=yes|no`. For a local branch,
   check `HEAD_SHA` equals the hand-off `head_sha`; if not, `kanban_block` (needs_input) rather than approving something else. Read the report with `cat <REPORT>`.
4. Sanity-check each blocking item against the code (`git -C <checkout> show`); drop what you cannot confirm.
5. `kanban_comment` on the ticket: verdict, blocking issues, suggestions, model used, whether the PR comment was posted.
6. Finish:
   - `CHANGES_REQUESTED` -> `kanban_request_changes(reason=...)`: the task returns to the coder, who reworks the branch (or PR),
     commits locally and requests review again. Start the reason with `branch <name>:` (or `PR <url>:`) followed by a numbered
     list of concrete, minimal fixes (file, problem, expected result). Only blocking problems; no style nits, no scope creep.
   - `APPROVE` on a **local branch**: nothing is published yet, so create the publish task for the coder, then complete this one:
     `kanban_create(title="Publish <branch> (approved)", assignee="coder-remote", skills=["tuanht-blog"], body="publish: true\nrepo: <repo>\nbranch: <branch>\napproved_sha: <HEAD_SHA>\nreview-task: <this task id>")`
     (add a `pr: <N>` line if the hand-off named an existing PR), `kanban_comment` the verdict, then `kanban_complete`
     (summary: approved `<sha>`, publish task `<new id>`). The coder pushes and opens the PR only in that task.
   - `APPROVE` on an already published **PR**: `kanban_complete` (short summary + PR link). The loop ends.
   - `UNKNOWN` or an `ERROR:` line -> `kanban_block` with the error (kind `capability` if Claude is not logged in or the repo is unreadable).

## Re-review rounds
When the task comes back after a rework (earlier `changes_requested` events or your earlier findings comment exist),
the branch has new local commits (new `head_sha` in the hand-off). Run `pr-review` again and judge mainly whether your previous blocking items
are fixed and nothing new broke. Approve when they are; do not invent new blocking items for old code.

## Pitfalls
- Review is read-only. Never edit files, commit, push, merge, close the PR or run `gh pr review --approve`/`--request-changes`; the human decides. The script only posts a plain PR comment (never for a local branch).
- Build/lint is off by default: PR code is untrusted and install hooks would run next to the sandbox's GitHub key and token. Enable `--build` only for PRs from trusted authors; the script uses `npm ci --ignore-scripts`.
- Never print or post tokens, keys or `.env` contents found in the repo; flag them as a blocking finding instead.
- Do not call `claude` directly or with `--dangerously-skip-permissions`; the script keeps a read-only allow-list.
- `POSTED=no` just means the token could not comment (e.g. the repo is outside its scope); report it, do not retry with other credentials.

## Verification
The ticket has a findings comment, the task ended with `kanban_complete` (with a publish task created for local branches), `kanban_request_changes` or `kanban_block`,
and the report path was quoted in the comment.
