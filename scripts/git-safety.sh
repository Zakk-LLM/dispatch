# Orchestrator-only Git operations shared by integration and worktree maintenance.
git_idle() {
  local repo=$1 marker path
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    path=$(git -C "$repo" rev-parse --path-format=absolute --git-path "$marker") || return 1
    [ ! -e "$path" ] || { echo "unfinished Git operation in $repo: $marker" >&2; return 1; }
  done
  [ -z "$(git -C "$repo" ls-files -u)" ] || { echo "unmerged index in $repo" >&2; return 1; }
}
lock_repository() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  exec {REPO_LOCK}>"$common/dispatch.lock" || return 1
  flock -n "$REPO_LOCK" || { echo "another Git collector owns $common" >&2; return 1; }
}
