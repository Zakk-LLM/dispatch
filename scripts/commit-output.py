#!/usr/bin/env python3
"""Commit only tracked changes and explicitly selected new files."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--include", action="append", default=[])
    parser.add_argument("--ignore-untracked", action="store_true")
    parser.add_argument("--artifact-check")
    parser.add_argument("--dry-run", action="store_true")
    opts = parser.parse_args()

    def git(*args, binary=False):
        return subprocess.check_output(["git", "-C", str(opts.worktree), *args], text=not binary)

    def branch():
        if git("symbolic-ref", "--short", "HEAD").strip() != opts.branch:
            raise RuntimeError(f"expected branch {opts.branch} in {opts.worktree}")

    branch()
    parent = git("rev-parse", "HEAD").strip()
    subprocess.run(["git", "-C", str(opts.worktree), "status", "--short", "--untracked-files=all"], check=True)
    untracked = git("ls-files", "--others", "--exclude-standard", "-z", binary=True).split(b"\0")
    for path in filter(None, untracked):
        print(f"untracked (not selected automatically): {os.fsdecode(path)!r}", file=sys.stderr)
    # Explicit selection cannot smuggle an absolute path or a directory's scratch contents.
    for name in opts.include:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or not name or (opts.worktree / path).is_dir():
            raise RuntimeError(f"--include requires one worktree-relative file: {name!r}")
    selected_new = set(map(os.fsencode, opts.include)) & set(filter(None, untracked))
    if any(untracked) and not selected_new and not opts.ignore_untracked:
        raise RuntimeError("untracked files require --include or explicit --ignore-untracked")
    if opts.dry_run:
        print(f"would stage tracked changes and explicit files: {opts.include!r}", file=sys.stderr)
        return 0
    subprocess.run(["git", "-C", str(opts.worktree), "add", "-u", "--"], check=True)
    if opts.include:
        subprocess.run(["git", "-C", str(opts.worktree), "add", "--",
                        *(f":(literal){name}" for name in opts.include)], check=True)
    print("staged set (including previously staged files):", file=sys.stderr)
    subprocess.run(["git", "-C", str(opts.worktree), "diff", "--cached", "--name-status"], check=True)
    if opts.artifact_check:
        subprocess.run(opts.artifact_check, shell=True, executable="/bin/bash", cwd=opts.worktree, check=True)
    tree = git("write-tree").strip()
    if tree == git("rev-parse", "HEAD^{tree}").strip():
        print("no selected changes to commit", file=sys.stderr)
        return 0
    branch()
    if git("rev-parse", "HEAD").strip() != parent:
        raise RuntimeError("worker HEAD changed during staging")
    subprocess.run(["git", "-C", str(opts.worktree), "commit", "-m", opts.message], check=True)
    branch()
    commit = git("rev-parse", "HEAD").strip()
    if git("rev-parse", "HEAD^{tree}").strip() != tree or git("rev-parse", "HEAD^").strip() != parent:
        raise RuntimeError("resulting commit does not match the staged tree and expected parent")
    print(f"verified commit {opts.branch}: {parent} -> {commit}; tree {tree}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print(f"commit stopped: {exc}", file=sys.stderr)
        raise SystemExit(1)
