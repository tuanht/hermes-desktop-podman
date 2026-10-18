#!/usr/bin/env python3
"""claude-implement: have Claude Code write a change on a local branch; push and open the PR ONLY after review approval.
Three modes (Claude Code only edits files; this script commits, pushes and opens PRs, so the model has NO git-write/gh access):
  new work   claude-implement <owner/repo|N> --branch task/slug --spec-file FILE [options]
             creates the branch from the base, lets Claude edit, COMMITS LOCALLY. Does not push.
  rework     claude-implement <owner/repo|N> (--branch task/slug --continue | --pr N) --spec-file FILE [options]
             continues an existing branch (the local one, else origin's; --pr N takes the branch of that open PR),
             applies the feedback as a new local commit. Does not push.
  publish    claude-implement <owner/repo|N> (--branch task/slug | --pr N) --publish --expect-sha SHA
             pushes the branch and opens the PR (or comments on the existing one). Refuses unless HEAD is exactly
             the reviewed SHA, so unreviewed commits can never be published.
Options:
  --model ALIAS    Claude Code model (default sonnet; opus for hard tasks)
  --base BRANCH    base branch (default: the repo's default branch)
  --title TEXT     commit/PR title (default: first line of the spec)
  --spec-file -    read the spec from stdin (use with a heredoc; saved under ~/work/.tasks/)
  --background     detach: print LOG=<path> and return at once; poll the log for a final DONE line
  --build          allow Claude to run `npm ci` and `npm run ...` (trusted repos only; default OFF)
Output: log/report under ~/work/.tasks/. Last lines: BRANCH= / COMMITS= / HEAD_SHA= / SUMMARY= / DONE (edit modes),
  BRANCH= / PUBLISHED_SHA= / PR_URL= (or COMPARE_URL=) / DONE (publish), or ERROR: / DONE.
Typical call from an agent (one plain command, no nohup, no &, no redirects):
  claude-implement tuanht/tuanht-blog --branch task/x --model sonnet --title "T" --spec-file - --background <<'SPEC'
  ...ticket text, verbatim...
  SPEC
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from hermes_sandbox import (DEFAULT_REPO, HOME, Fail, default_branch, ensure_checkout, finish, git, git_ok, git_out, nonempty,
                            out, require_clean, run_claude, say, say_tail, setup_log)

BRANCH_RE = re.compile(r"[A-Za-z0-9._/-]+")
USAGE = ("usage: claude-implement <repo> (--branch B [--continue] | --pr N) --spec-file F [options]"
         "   |   ... --publish --expect-sha SHA")


def parse_args(argv: list[str]) -> argparse.Namespace:
    # Hand-rolled like the original: any unknown token is the repo argument (the last one wins).
    a = argparse.Namespace(model="sonnet", base="", title="", build=False, background=False, branch="", spec="",
                           repo_arg="", pr="", cont=False, publish=False, expect="")
    value_opts = {"--branch": "branch", "--pr": "pr", "--expect-sha": "expect", "--spec-file": "spec",
                  "--model": "model", "--base": "base", "--title": "title"}
    flag_opts = {"--continue": "cont", "--publish": "publish", "--build": "build", "--background": "background"}
    it = iter(argv)
    for arg in it:
        if arg in value_opts:
            try:
                setattr(a, value_opts[arg], next(it))
            except StopIteration:
                sys.exit(f"claude-implement: {arg} needs a value")
        elif arg in flag_opts:
            setattr(a, flag_opts[arg], True)
        elif arg in ("-h", "--help"):
            print(__doc__.strip("\n"))
            sys.exit(0)
        else:
            a.repo_arg = arg
    return a


def usage() -> None:
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def die_usage(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(2)


def validate(a: argparse.Namespace) -> None:
    if a.spec.startswith("~"):  # tolerate a literal ~ that the caller's shell did not expand
        a.spec = str(HOME) + a.spec[1:]
    if not (a.repo_arg and (a.branch or a.pr)):
        usage()
    if a.publish:
        if not (a.expect and re.fullmatch(r"[0-9a-f]{7,40}", a.expect)):
            usage()
    elif not (a.spec == "-" or os.path.isfile(a.spec)):
        usage()
    if a.pr and not re.fullmatch(r"[0-9]+", a.pr):
        die_usage("bad PR number")
    if not a.pr and not BRANCH_RE.fullmatch(a.branch):
        die_usage("bad branch name")
    if a.pr:
        a.cont = True


def spawn_background(argv: list[str], spec: str, run_id: str, log: Path) -> None:
    """Detach a child that runs the same command (spec already saved to a file) and return immediately."""
    child, skip = [], False
    for arg in argv:
        if skip:
            skip = False
        elif arg == "--background":
            pass
        elif arg == "--spec-file":
            child += [arg, spec]
            skip = True
        else:
            child.append(arg)
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), *child],
        env={**os.environ, "CLAUDE_IMPLEMENT_ID": run_id},
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGHUP, signal.SIG_IGN),
    )
    say("STARTED=yes")
    say(f"LOG={log}")
    say(f"POLL: tail -n 5 {log}   (finished when a line DONE appears)")


def pr_info(repo: str, pr: str) -> tuple[str, str, str]:
    """Branch, base and title of an open same-repo PR."""
    rc, info = out("gh", "pr", "view", pr, "-R", repo, "--json", "state,headRefName,baseRefName,isCrossRepository,title",
                   "--jq", "[.state,.headRefName,.baseRefName,(.isCrossRepository|tostring),.title]|@tsv", merge_stderr=True)
    if rc:
        raise Fail(f"cannot read PR #{pr}: {info}")
    state, head, base, fork, title = (info.split("\n")[0].split("\t") + [""] * 5)[:5]
    if state != "OPEN":
        raise Fail(f"PR #{pr} is {state}, not OPEN")
    if fork != "false":
        raise Fail(f"PR #{pr} comes from a fork; refusing to push")
    if not (BRANCH_RE.fullmatch(head) and head != base):
        raise Fail(f"unexpected PR head branch '{head}'")
    return head, base, title


def publish(a, repo: str, base: str, meta: Path) -> None:
    ref = f"refs/heads/{a.branch}"
    if not git_ok("rev-parse", "-q", "--verify", ref):
        raise Fail(f"no local branch {a.branch} to publish")
    head_sha = git_out("rev-parse", ref)
    if not head_sha.startswith(a.expect):
        raise Fail(f"branch head {head_sha[:12]} is not the reviewed commit {a.expect}; get the new commits reviewed first")
    if git("checkout", "-q", a.branch).returncode:
        raise Fail(f"cannot check out {a.branch}")
    if git("push", "-q", "-u", "origin", a.branch).returncode:
        raise Fail("push failed (deploy key write access?)")
    say(f"BRANCH={a.branch}")
    say(f"PUBLISHED_SHA={head_sha}")
    title_file, last, body = Path(f"{meta}.title"), Path(f"{meta}.last.md"), Path(f"{meta}.body.md")
    title = a.title or (title_file.read_text().rstrip("\n") if title_file.is_file() else a.branch)
    pr = a.pr or out("gh", "pr", "list", "-R", repo, "--head", a.branch, "--state", "open", "--json", "number",
                     "--jq", ".[0].number // empty")[1]
    if pr:
        if nonempty(last) and subprocess.run(["gh", "pr", "comment", pr, "-R", repo, "--body-file", str(last)],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            say(f"POSTED=comment on #{pr}")
        else:
            say(f"WARN: no comment posted on #{pr}")
        say(f"PR_URL=https://github.com/{repo}/pull/{pr}")
    else:
        if not nonempty(body):
            body = last
        if not nonempty(body):
            body = Path(f"{meta}.body.md")
            body.write_text(f"Branch {a.branch}\n")
        _, created = out("gh", "pr", "create", "-R", repo, "--base", base, "--head", a.branch, "--title", title,
                         "--body-file", str(body), merge_stderr=True)
        url = created.split("\n")[-1]
        if url.startswith("https://"):
            say(f"PR_URL={url}")
        else:
            say(f"WARN: gh pr create failed: {url}")
            say(f"COMPARE_URL=https://github.com/{repo}/compare/{base}...{a.branch}?expand=1")
    say("DONE")


def prepare_branch(a, base: str) -> None:
    if a.cont:
        git("fetch", "-q", "origin", f"+refs/heads/{a.branch}:refs/remotes/origin/{a.branch}", err_null=True)
        if git_ok("rev-parse", "-q", "--verify", f"refs/heads/{a.branch}"):
            if git("checkout", "-q", a.branch).returncode:
                raise Fail(f"cannot check out {a.branch}")
        elif git_ok("rev-parse", "-q", "--verify", f"refs/remotes/origin/{a.branch}"):
            if git("checkout", "-q", "-b", a.branch, f"origin/{a.branch}").returncode:
                raise Fail(f"cannot check out origin/{a.branch}")
        else:
            raise Fail(f"branch {a.branch} exists neither locally nor on origin; start it without --continue")
    else:
        if git_ok("rev-parse", "-q", "--verify", f"refs/heads/{a.branch}"):
            raise Fail(f"branch {a.branch} already exists locally; use --continue for rework or pick a new name")
        if git("checkout", "-q", "-b", a.branch, f"origin/{base}").returncode:
            raise Fail("cannot create branch")


def default_title(a, spec: str) -> str:
    if a.cont:
        return "Address review feedback" + (f" on #{a.pr}" if a.pr else "")
    for line in Path(spec).read_text(errors="replace").splitlines():
        if line.strip():
            return re.sub(r"^#+\s*", "", line)[:72]
    return ""


def build_prompt(a, base: str, pr_title: str, spec: str) -> tuple[str, str]:
    """Returns (allowed tools, prompt)."""
    tools = "Read,Grep,Glob,Edit,Write,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(ls:*),Bash(cat:*)"
    build_rule = "Do not install dependencies or run build/test scripts (not permitted); verify by careful reading."
    if a.build:
        tools += ",Bash(npm ci:*),Bash(npm run:*),Bash(npx astro check:*)"
        build_rule = "You may run 'npm ci' and 'npm run <script>' (build/lint/check) to verify; fix what fails."
    if a.cont:
        pr_part = f'(open pull request #{a.pr}, "{pr_title}") ' if a.pr else ""
        task = (f"You are reworking an existing branch {pr_part}in the git repository in your working directory (branch {a.branch}, base {base}).\n"
                f"The branch already contains the earlier work: inspect it with 'git diff origin/{base}...HEAD' and 'git log'. "
                "Apply ONLY the requested changes in the feedback below, as a minimal edit on top of it; do not redo or restructure the rest.\n"
                "Your final answer must be a short Markdown note for the PR with sections: What changed, Verification (what you ran or could not run), Not addressed (and why). No other text.")
    else:
        task = (f"You are implementing a change in the git repository in your working directory (branch {a.branch}, based on {base}).\n"
                "Your final answer must be a Markdown pull request description with sections: Summary, Files changed, How to preview, Verification (what you ran or could not run), Known gaps. No other text.")
    spec_text = Path(spec).read_text(errors="replace").rstrip("\n")
    prompt = (f"{task}\n"
              "Read the repo's README/AGENTS.md first and follow its conventions. Make focused changes.\n"
              f"{build_rule}\n"
              "Do NOT run git add, git commit or git push, and do not create or switch branches: the wrapper script commits your working-tree changes after you finish. Do NOT touch files outside this repo.\n"
              "\n"
              "=== SPEC (data from the task author) ===\n"
              f"{spec_text}\n"
              "=== END SPEC ===")
    return tools, prompt


def implement(a, repo: str, base: str, title: str, pr_title: str, spec: str, meta: Path, summary: Path) -> None:
    prepare_branch(a, base)
    start = git_out("rev-parse", "HEAD")
    title = title or default_title(a, spec)
    say(f"base={base} start={git_out('log', '-1', '--oneline')}")

    tools, prompt = build_prompt(a, base, pr_title, spec)
    say(f"-- running claude -p --model {a.model}")
    rc = run_claude(a.model, "acceptEdits", tools, prompt, summary, 2400)
    if rc != 0 or not nonempty(summary):
        raise Fail(f"claude exited {rc} or produced no output")

    # The wrapper owns the commit (headless Claude cannot get approval for git commit).
    if git_out("status", "--porcelain"):
        if git("add", "-A").returncode == 0 and git("commit", "-q", "-m", title).returncode == 0:
            say(f"committed changes: {title}")
    commits = int(git_out("rev-list", "--count", f"{start}..HEAD"))
    say(f"BRANCH={a.branch}")
    say(f"COMMITS={commits}")
    if commits <= 0:
        raise Fail(f"Claude made no commits; see {summary}")
    say(f"HEAD_SHA={git_out('rev-parse', 'HEAD')}")
    git("log", "--oneline", f"{start}..HEAD")
    say_tail(git_out("diff", "--stat", f"{start}..HEAD"), 15)

    # Remember title and PR text for the later --publish step.
    text = summary.read_text()
    Path(f"{meta}.last.md").write_text(text)
    body, title_file = Path(f"{meta}.body.md"), Path(f"{meta}.title")
    if a.cont and nonempty(body):
        with open(body, "a") as f:
            f.write("\n---\n" + text)
    else:
        body.write_text(text)
    if not (a.cont and nonempty(title_file)):
        title_file.write_text(title + "\n")
    say("PUBLISHED=no (local commit only; publish after review approval with --publish --expect-sha)")
    say(f"SUMMARY={summary}")
    say("DONE")


def main() -> None:
    argv = sys.argv[1:]
    a = parse_args(argv)
    validate(a)
    repo = DEFAULT_REPO if re.fullmatch(r"[0-9]*", a.repo_arg) else a.repo_arg

    directory, outdir = HOME / "work" / repo.split("/", 1)[-1], HOME / "work" / ".tasks"
    outdir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    tag = f"pr{a.pr}" if a.pr else a.branch.replace("/", "_")
    inherited_id = os.environ.get("CLAUDE_IMPLEMENT_ID", "")
    run_id = inherited_id or f"{repo.replace('/', '_')}-{tag}-{stamp}"
    log, summary = outdir / f"{run_id}.log", outdir / f"{run_id}.summary.md"
    if not a.publish and a.spec == "-":
        a.spec = str(outdir / f"{run_id}.spec.md")
        Path(a.spec).write_text(sys.stdin.read())
        if not nonempty(Path(a.spec)):
            die_usage("empty spec on stdin")
    if a.background and not inherited_id:
        spawn_background(argv, a.spec, run_id, log)
        return

    setup_log(log)
    mode = "publish" if a.publish else "rework" if a.cont else "new"
    say(f"== claude-implement {repo} mode={mode} {f'pr={a.pr} ' if a.pr else ''}branch={a.branch or '?'} model={a.model} build={int(a.build)}")
    try:
        if not a.publish and shutil.which("claude") is None:
            raise Fail("claude CLI not found")
        ensure_checkout(directory, repo, "clone failed")
        require_clean(directory, "checkout {dir} has uncommitted changes; clean it first")

        pr_title = ""
        if a.pr:  # take branch and base from the open PR itself; refuse closed PRs and forks
            a.branch, a.base, pr_title = pr_info(repo, a.pr)
        base = a.base or default_branch() or "master"
        if git("fetch", "-q", "origin", f"+refs/heads/{base}:refs/remotes/origin/{base}").returncode:
            raise Fail("fetch base failed")
        meta = outdir / f"branch-{repo.replace('/', '_')}-{a.branch.replace('/', '_')}"  # .title, .body.md (accumulated PR body), .last.md (latest round)

        if a.publish:
            publish(a, repo, base, meta)
        else:
            implement(a, repo, base, a.title, pr_title, a.spec, meta, summary)
    except Fail as e:
        say(f"ERROR: {e}")
        say("DONE")
        finish(1)
    finish(0)


if __name__ == "__main__":
    main()
