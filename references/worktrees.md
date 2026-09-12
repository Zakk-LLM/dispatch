# Parallel agents on one repository

Two agents writing one checkout overwrite each other, and nothing detects it at dispatch time.
A git worktree gives each write-capable agent its own working files, HEAD, and index while
sharing the object store, so the conflict moves from the filesystem to merge time where it is
visible and reviewable.

Measured context: a study of co-active agent-authored pull requests found textual conflicts in
41.7% of cross-agent pairs against 19.8% for same-agent pairs, and roughly 42% of conflicted
files carried structural conflicts. Isolation does not remove that; it converts silent
clobbering into a merge you can inspect.

## Dispatching into worktrees

```sh
"$DISPATCH_SKILL/scripts/agent.sh" --engine omp --run-dir "$RUN" --label cache \
  --cwd /path/to/repo --worktree --worktree-base main \
  --permission workspace-write --tier deep --timeout 3600 \
  --prompt-file "$RUN/agents/cache/prompt.md"
```

`--worktree` creates `<run>/worktrees/<label>` on branch `omp/<label>` from
`--worktree-base` (default `HEAD`), runs the agent there, and records the branch and base SHA
in `meta.json`. `--worktree NAME` shares one worktree between several agents that must build on
each other — a fix round inherits its parent's worktree by passing the same name.

The agent's spec still declares its write scope. The worktree stops cross-agent clobbering; it
does not stop an agent from editing files that belong to someone else's task.

## When to use it

Use a worktree for every write-capable agent in a fan-out of two or more, and whenever an agent
runs long enough that you want to keep working in the main checkout meanwhile.

Skip it for read-only agents, for a single writer with nothing else running, and when the build
is so expensive that a fresh checkout costs more than serializing the work — each worktree needs
its own dependency install and build output.

## Merging

Review each branch on its own, then integrate deliberately:

Agents are forbidden from committing, so their work is still uncommitted in the worktree: a
branch diff alone shows nothing. Look at the working tree, then let `merge.sh` commit and
integrate it, or commit it yourself first.

```sh
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --diff main   # branch diff plus uncommitted work
"$DISPATCH_SKILL/scripts/merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q"                                          # commits, merges, verifies, rolls back
```

Merge in dependency order, run the tests after each merge rather than only at the end, and when
two branches touch one file, resolve it yourself instead of asking an agent to "fix the
conflict" — the agent that wrote one side cannot see why the other side exists.

## Cleanup

Worktrees, branches, and their build output persist until removed:

```sh
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --list
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --remove-merged main
```

Remove them once the work is merged or abandoned. A run directory full of stale worktrees is
a disk problem on any machine and a snapshot problem on filesystems that snapshot the home
directory.

## Permission interaction

A worktree lives under the run directory, and the agent's `--cwd` is the worktree itself, so a
`workspace-write` profile edits there and nowhere else that matters. Note the difference from an
OS sandbox: nothing physically prevents a permitted shell command from writing outside the
worktree, so the review gate compares the changed files against the declared scope rather than
trusting the boundary.

Submodules are the known exception: git documents incomplete support for multiple superproject
checkouts, so a submodule-heavy repository needs a plain clone per agent instead.
