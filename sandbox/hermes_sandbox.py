"""Helpers shared by claude-implement and pr-review (installed next to them in /usr/local/bin)."""
import os
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
DEFAULT_REPO = "tuanht/tuanht-blog"


class Fail(Exception):
    """A fatal error that the calling script reports in its own machine-readable trailer."""


def setup_log(log: Path) -> None:
    """Send stdout and stderr (also of child processes) to the terminal and append them to `log`, like `exec > >(tee -a log) 2>&1`."""
    sys.stdout.flush()
    sys.stderr.flush()
    tee = subprocess.Popen(["tee", "-a", str(log)], stdin=subprocess.PIPE)
    os.dup2(tee.stdin.fileno(), 1)
    os.dup2(tee.stdin.fileno(), 2)
    tee.stdin.close()
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
    _TEE.append(tee)


_TEE: list[subprocess.Popen] = []


def finish(code: int) -> "None":
    """Flush, let tee drain, exit."""
    sys.stdout.flush()
    sys.stderr.flush()
    if _TEE:
        os.close(1)
        os.close(2)
        _TEE[0].wait()
    os._exit(code)


def say(*parts: str) -> None:
    print(*parts, flush=True)


def run(*cmd: str, quiet: bool = False, err_null: bool = False, cwd=None, input: str | None = None) -> subprocess.CompletedProcess:
    """Run a command with output going straight to our stdout/stderr (so it reaches the log).
    quiet=True captures stdout and discards it; err_null=True discards stderr."""
    sys.stdout.flush()
    return subprocess.run(
        cmd, cwd=cwd, input=input, text=True,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if err_null else None,
    )


def out(*cmd: str, merge_stderr: bool = False, cwd=None) -> tuple[int, str]:
    """Run a command and return (returncode, stdout with trailing newlines stripped, like `$(...)`).
    stderr is discarded unless merge_stderr, in which case it is folded into the output (`2>&1`)."""
    p = subprocess.run(
        cmd, cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
    )
    return p.returncode, p.stdout.rstrip("\n")


def git(*args: str, **kw) -> subprocess.CompletedProcess:
    return run("git", *args, **kw)


def git_ok(*args: str) -> bool:
    return subprocess.run(("git", *args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def git_out(*args: str) -> str:
    return out("git", *args)[1]


def tail(text: str, n: int) -> str:
    return "\n".join(text.splitlines()[-n:])


def say_tail(text: str, n: int) -> None:
    """Print the last n lines of `text`, nothing at all if it is empty (like `... | tail -n N`)."""
    if text:
        say(tail(text, n))


def default_branch() -> str:
    """Name of origin's default branch ('' if unknown), as seen in the current repo."""
    ref = git_out("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    return ref[len("origin/"):] if ref.startswith("origin/") else ref


def ensure_checkout(directory: Path, repo: str, clone_error: str) -> None:
    """Clone `repo` into `directory` if needed, chdir into it, and require a clean tree."""
    if not (directory / ".git").is_dir():
        if run("git", "clone", f"git@github.com:{repo}.git", str(directory)).returncode:
            raise Fail(clone_error)
    try:
        os.chdir(directory)
    except OSError:
        raise Fail("no checkout")


def require_clean(directory: Path, message: str) -> None:
    if git_out("status", "--porcelain"):
        raise Fail(message.format(dir=directory))


def run_claude(model: str, permission_mode: str, tools: str, prompt: str, dest: Path, seconds: int) -> int:
    """`timeout SECONDS claude -p` with the prompt on stdin (--allowedTools is variadic and would swallow a
    trailing prompt argument), stdout to `dest`, and the last 20 stderr lines relayed to our stderr."""
    sys.stdout.flush()
    with open(dest, "w") as f:
        p = subprocess.run(
            ["timeout", str(seconds), "claude", "-p", "--model", model, "--permission-mode", permission_mode,
             "--allowedTools", tools],
            input=prompt + "\n", text=True, stdout=f, stderr=subprocess.PIPE,
        )
    if p.stderr.strip("\n"):
        print(tail(p.stderr, 20), file=sys.stderr, flush=True)
    return p.returncode


def nonempty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0
