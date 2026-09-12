#!/usr/bin/env sh
# Everything this repository can check about itself. Exit non-zero if any check fails.
# Run it before committing.
set -u
cd "$(dirname "$0")/.." || exit 2
ENGINE=omp
fail=0
skipped=0

# Exit 1 is a finding; exit 2 is a check that could not run on this machine. Conflating them
# happened in a sibling repository and pinned the whole gate red everywhere but the author's
# box for twenty runs. A check that cannot run must say so, but it is neither a finding nor a
# pass, and the closing count keeps a partial run from reading like full coverage.
run() {
  printf '%s\n' "--- $1"
  name=$1
  shift
  # Store the status before testing it: after `if "$@"; then ... fi`, `$?` is the status of
  # the if, not of the command.
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    skipped=$((skipped + 1))
    printf '    SKIP %s: this check could not run here\n' "$name"
  else
    fail=1
  fi
}

run "contract-entry" python3 scripts/check-contract.py entry SKILL.md README.md README.zh-TW.md
run "contract-omp" python3 scripts/check-contract.py engine omp references/engines/omp.md
run "contract-codex" python3 scripts/check-contract.py engine codex references/engines/codex.md
run "contract-opencode" python3 scripts/check-contract.py engine opencode references/engines/opencode.md
run "contract-template" python3 scripts/check-contract.py template references/prompt-template.md
run "shell-syntax" sh scripts/check-shell-syntax.sh

# The controls run here rather than in a sweep somebody remembers. They buy the one fact none
# of the checks above establishes: that those checks can still fail. Every break happens on a
# temporary copy, so no tracked file is touched.
if [ "${1:-}" != "--fast" ]; then
  run "controls" sh scripts/self-test.sh "$ENGINE"
fi

if [ "$fail" -ne 0 ]; then
  printf '%s\n' "a check found something"
  exit 1
fi
if [ "$skipped" -ne 0 ]; then
  printf 'everything that ran passed; %d could not run here, so this is not full coverage\n' "$skipped"
  exit 0
fi
printf '%s\n' "all checks passed"
