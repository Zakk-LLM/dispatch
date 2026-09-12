#!/usr/bin/env bash
# List or clean up the git worktrees a run created.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: worktrees.sh <run-dir> --list
       worktrees.sh <run-dir> --diff [BASE]         (default BASE: main)
       worktrees.sh <run-dir> --drift [BASE]
       worktrees.sh <run-dir> --rebase [BASE]
       worktrees.sh <run-dir> --remove-merged BASE
       worktrees.sh <run-dir> --remove-all

--drift reports how far each branch has fallen behind BASE and whether its agent is still
running. --rebase moves the finished ones onto BASE, committing their pending work first, and
never touches a worktree whose agent is live.

--remove-merged deletes only worktrees whose branch is already contained in BASE, so
unmerged work is never thrown away. --remove-all refuses while a worktree has uncommitted
changes; commit or discard them first.
EOF
}

case "${1:-}" in -h|--help|"") usage; exit 0 ;; esac
RUN=$1; ACTION=${2:-}; ARG=${3:-}
[ -n "$ACTION" ] || { usage >&2; exit 2; }
[ -d "$RUN/worktrees" ] || { echo "no worktrees under $RUN"; exit 0; }

FIRST_WT=$(find "$RUN/worktrees" -mindepth 1 -maxdepth 1 -type d -print -quit)
[ -n "$FIRST_WT" ] || { echo "no worktrees under $RUN"; exit 0; }
REPO=$(git -C "$FIRST_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
[ -n "$REPO" ] || { echo "cannot resolve the worktree repository" >&2; exit 1; }

branch_for() {
  local wt=$1 branch
  branch=$(python3 - "$RUN" "$wt" <<'PY'
import json, os, pathlib, sys
run, worktree = pathlib.Path(sys.argv[1]), os.path.realpath(sys.argv[2])
for path in sorted((run / "agents").glob("*/meta.json")):
    try:
        meta = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    if os.path.realpath(str(meta.get("cwd") or "")) == worktree and meta.get("worktree_branch"):
        print(meta["worktree_branch"])
        break
PY
)
  [ -n "$branch" ] || branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  printf '%s\n' "$branch"
}

case "$ACTION" in
  --list)
    git -C "$REPO" worktree list | grep -F "$RUN/worktrees" || echo "(none registered)"
    ;;
  --diff)
    BASE=${ARG:-main}
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      branch=$(branch_for "$wt")
      printf '\n=== %s vs %s ===\n' "$branch" "$BASE"
      git -C "$REPO" diff --stat "$BASE...$branch" 2>/dev/null || echo "(branch missing)"
      # Agents are forbidden from committing, so their work is usually still uncommitted.
      git -C "$wt" diff --stat HEAD | sed 's/^/  uncommitted: /'
      git -C "$wt" status --porcelain --untracked-files=all | grep '^??' | sed 's/^??/  untracked:/'
    done
    ;;
  --drift|--rebase)
    BASE=${ARG:-main}
    git -C "$REPO" rev-parse --verify "$BASE" >/dev/null 2>&1 || {
      echo "unknown base: $BASE" >&2; exit 2; }
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      branch=$(branch_for "$wt")
      behind=$(git -C "$REPO" rev-list --count "$branch..$BASE" 2>/dev/null || echo 0)
      # agents.sh owns process identity and the all-engine scan.
      live=$("$(cd "$(dirname "$0")" && pwd)/agents.sh" --cwd-live "$(cd "$wt" && pwd)")
      if [ "${behind:-0}" = 0 ]; then
        printf '%-28s up to date with %s\n' "$branch" "$BASE"
        continue
      fi
      if [ "$ACTION" = --drift ]; then
        printf '%-28s %s commit(s) behind %s  agent-running=%s\n' "$branch" "$behind" "$BASE" "$live"
        continue
      fi
      if [ "$live" = yes ]; then
        printf '%-28s SKIPPED: agent still running; tell it through NOTES.md and rebase after it exits\n' "$branch"
        continue
      fi
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        git -C "$wt" add -A && git -C "$wt" commit -q -m "$name: agent work before rebase onto $BASE" || {
          printf '%-28s FAILED to commit pending work\n' "$branch"; continue; }
      fi
      if git -C "$wt" rebase "$BASE" >/dev/null 2>&1; then
        printf '%-28s rebased onto %s — re-run its acceptance checks\n' "$branch" "$BASE"
      else
        git -C "$wt" rebase --abort 2>/dev/null
        printf '%-28s CONFLICT rebasing onto %s; resolve by hand\n' "$branch" "$BASE"
      fi
    done
    ;;
  --remove-merged)
    [ -n "$ARG" ] || { echo "--remove-merged needs a base branch" >&2; exit 2; }
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      branch=$(branch_for "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "keep $branch: uncommitted changes"; continue
      fi
      if git -C "$REPO" merge-base --is-ancestor "$branch" "$ARG" 2>/dev/null; then
        git -C "$REPO" worktree remove "$wt" && git -C "$REPO" branch -d "$branch" \
          && echo "removed $branch"
      else
        echo "keep $branch: not merged into $ARG"
      fi
    done
    ;;
  --remove-all)
    for wt in "$RUN"/worktrees/*/; do
      [ -d "$wt" ] || continue
      name=$(basename "$wt")
      branch=$(branch_for "$wt")
      if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "refusing $branch: uncommitted changes" >&2; continue
      fi
      git -C "$REPO" worktree remove "$wt" && echo "removed worktree $branch"
    done
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
