---
name: blog-review
description: "Use for Kanban review tasks on tuanht-blog pull requests: run Claude Code review in the SSH sandbox, post findings to the PR and ticket, then approve or request changes."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [review, git, blog, sandbox, claude-code]
    requires_toolsets: [terminal]
---

# blog-review

Review a tuanht-blog pull request by delegating the reading to Claude Code inside `hermes-sandbox`.
This profile's terminal backend is SSH, so every terminal command runs there as user `dev`.
Hermes itself only coordinates; Claude Code does the review.

## When to Use
A task in the Kanban `review` column (or assigned to this profile) that points at a tuanht-blog PR or branch.

## Inputs (from the task body/context; if missing, `kanban_block` with kind `needs_input`)
- PR URL, `owner/repo#N`, or just `N` (means `tuanht/tuanht-blog`). Works for any repo the sandbox can read.
- Optional `claude-model: <alias>` line. Default `sonnet`; use `opus` for deep reviews. This is the Claude Code
  model, separate from the Hermes worker model that Kanban `--model` pins.
- Optional `focus: <text>` line (security, accessibility, ...).
- Optional `no-post: true` line to skip the PR comment, `build: true` to run the repo's build/lint (see Pitfalls).

## Procedure
All the mechanics live in the sandbox script `blog-review`, so do not reimplement them by hand.
1. Start it in the background (a review takes minutes, longer than one terminal call):
   `mkdir -p ~/work/.reviews && nohup blog-review "<PR>" --model <alias> --focus "<text>" [--no-post] [--build] > ~/work/.reviews/run-$$.out 2>&1 &`
   Note the output file path.
2. Poll with `tail -n 5 <file>` every 20-30 s (use `heartbeat` if the tool exists) until a line `DONE` appears. Give up after ~25 min.
3. Read the final lines: `VERDICT=`, `REPORT=<path>`, `POSTED=yes|no`. Read the report with `cat <REPORT>`.
4. Sanity-check each blocking item against the code (`git -C <checkout> show`); drop what you cannot confirm.
5. `kanban_comment` on the ticket: verdict, blocking issues, suggestions, model used, whether the PR comment was posted.
6. Finish: `VERDICT=APPROVE` -> `kanban_complete` (short summary + PR link). `CHANGES_REQUESTED` ->
   `kanban_request_changes(reason=...)`. `UNKNOWN` or an `ERROR:` line -> `kanban_block` with the error
   (kind `capability` if Claude is not logged in or the repo is unreadable).

## Pitfalls
- Review is read-only. Never edit files, commit, push, merge, close the PR or run `gh pr review --approve`/`--request-changes`; the human decides. The script only posts a plain PR comment.
- Build/lint is off by default: PR code is untrusted and install hooks would run next to the sandbox's GitHub key and token. Enable `--build` only for PRs from trusted authors; the script uses `npm ci --ignore-scripts`.
- Never print or post tokens, keys or `.env` contents found in the repo; flag them as a blocking finding instead.
- Do not call `claude` directly or with `--dangerously-skip-permissions`; the script keeps a read-only allow-list.
- `POSTED=no` just means the token could not comment (e.g. the repo is outside its scope); report it, do not retry with other credentials.

## Verification
The ticket has a findings comment, the task ended with `kanban_complete`, `kanban_request_changes` or `kanban_block`,
and the report path was quoted in the comment.
