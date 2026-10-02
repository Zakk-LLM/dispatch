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

Dispatch itself is an exception to the single-writer shortcut: edit it in a separate worktree
or pinned copy, never the checkout the running fleet executes. For the checkout behind
`~/.claude/skills/dispatch`, install a complete new directory and atomically rename a replacement
symlink over the old link only when no job runs from it. Do not update live scripts in place.
See [incident recovery](troubleshooting.md#the-wrapper-died-without-a-report).

## Merging

Review each branch on its own, then integrate deliberately:

Follow the [worker contract](review-gate.md#worker-contract) for Git ownership, artifact scope, targeted checks and `not run`.

```sh
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --diff main   # branch diff plus uncommitted work
"$DISPATCH_SKILL/scripts/merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --final-check "pytest -q"                                   # full suite once on the combined tree
```


`merge.sh` prints status, untracked files and the complete staged set, including files staged
earlier. It stages tracked changes and literal reviewed new files selected with `--include label:path`.
If new files exist and none are included, it fails with their list unless `--ignore-untracked`
is explicit. `--artifact-check CMD` enforces repository policy on the staged set.
A staging or policy failure stops before commit. The helper checks the expected branch, staged
tree and resulting commit parent/tree. Optional `--push REMOTE` publishes the checked target and
requires its remote head to match. Local integration does not publish without this option.

`merge.sh` and mutating `worktrees.sh` operations take one lock per Git common directory,
resolved by `git rev-parse`. They refuse unfinished Git operations and live workers.
`worktrees.sh --rebase` requires clean, already committed output; it never stages files.
Failed rebase or checks roll back the integration target, not the worker commits or remote refs.

## Cleanup

Worktrees, branches, and their build output persist until removed:

```sh
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --list
"$DISPATCH_SKILL/scripts/worktrees.sh" "$RUN" --remove-merged main
```

Both removal modes attempt every eligible worktree and delete its branch. `--remove-merged`
keeps unmerged branches; `--remove-all` also deletes unmerged branches. Dirty/live worktrees
and Git failures cause non-zero exit without preventing other eligible removals.

## Permission interaction

See the [worker contract](review-gate.md#worker-contract) for Git and artifact access boundaries.

Submodules are the known exception: git documents incomplete support for multiple superproject
checkouts, so a submodule-heavy repository needs a plain clone per agent instead.
