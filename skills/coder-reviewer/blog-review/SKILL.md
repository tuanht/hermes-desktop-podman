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

## Inputs (from the task body/context; ask via `kanban_block` kind `needs_input` if missing)
- PR number/URL or branch name. Repo: `tuanht/tuanht-blog`, checkout: `/home/dev/work/tuanht-blog`.
- Optional line `claude-model: <alias>` in the task body. Default is `sonnet`. Use `opus` for deep reviews.
  This is the Claude Code model, separate from the Hermes worker model that Kanban `--model` pins.
- Optional `focus:` line (e.g. security, accessibility, performance) to steer the review.

## Procedure
1. Prepare the repo: `cd /home/dev/work/tuanht-blog && git status --short` (stop if dirty), `git fetch origin --prune`.
   If missing, clone `git@github.com:tuanht/tuanht-blog.git` first.
2. Check out the PR head: `gh pr checkout <n>` when `gh auth status` is OK, else `git checkout <branch>`.
   Find the base with `gh pr view <n> --json baseRefName -q .baseRefName` or the repo's default branch.
3. Run the build/lint scripts the repo documents, and keep the results for the report.
4. Run a read-only Claude Code review (replace `$M` with the model alias, `$BASE` with the base branch):

   ```bash
   claude -p --model "$M" --permission-mode plan \
     --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)" \
     "Review the changes in 'git diff origin/$BASE...HEAD' for correctness, regressions, security, accessibility, readability and test/build impact. Task focus: <focus or none>. Output: 1) verdict APPROVE or CHANGES_REQUESTED, 2) blocking issues with file:line, 3) non-blocking suggestions, 4) what you checked. Do not modify files." \
     > /tmp/review.md
   ```

   Use a generous terminal timeout; long reviews are normal. If Claude Code is not logged in, block the task
   with kind `capability` and say to run `claude` once in the sandbox.
5. Read `/tmp/review.md`. Sanity-check blocking claims against the code yourself; drop anything you cannot confirm.
6. Post the findings:
   - Kanban: `kanban_comment` with the verdict, blocking issues, suggestions, build/lint results, and the model used.
   - Pull request: `gh pr comment <n> --body-file /tmp/review.md` (comments only).
7. Finish:
   - No blocking issues: `kanban_complete` with a short summary (verdict, model used, PR link).
   - Blocking issues: `kanban_request_changes(reason=...)` listing them concisely.

## Pitfalls
- Review is read-only. Never edit files, commit, push, merge, close the PR or run `gh pr review --approve`/`--request-changes`; the human decides.
- Never print or post tokens, keys or `.env` contents found in the repo; flag them as a blocking finding instead.
- Do not use `--dangerously-skip-permissions`. Keep the allow-list above.
- If `gh` is not authenticated, skip the PR comment and say so in the Kanban comment.

## Verification
The Kanban ticket has a findings comment, the PR has the same comment (when `gh` works), and the task ended with
`kanban_complete` or `kanban_request_changes`. `git status` in the checkout is clean.
