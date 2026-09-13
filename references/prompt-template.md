# Task spec template

One file per agent, written to `<run>/agents/<label>/prompt.md`. The worker starts with no
memory of your conversation: everything it needs must be in this file. Keep it under roughly
80 lines; beyond that the constraints start competing with each other.

```markdown
# Task: <one line, the outcome>

## Context
<Why this exists, in two or three sentences. Name the entry point, the caller, and the
consumer of what you are asking for. Paste the exact repository conventions that apply —
the worker cannot see the project instructions you are following.>

## Scope
Read: <paths the worker may read>
Write: <exact files or directories the worker may modify or create>
Out of scope: <adjacent things it must leave alone>

## Skills
Read `<absolute path>/SKILL.md` before starting and follow it. <One line naming what it
governs, e.g. all Chinese text in this task.>

## Requirements
1. <testable statement>
2. <testable statement>

## Live notes
Before each step, and again before your final report, run `cat <run>/agents/<label>/NOTES.md`
and follow everything it contains. That file changes while you work; the newest entry wins,
and it overrides this spec where they conflict. Apply a new requirement to work you already
finished. Do this even when it looks redundant.

## Acceptance criteria
- <command that must pass, e.g. `pytest tests/test_cache.py -q`>
- <observable behavior>

## Verification you must perform
Run every acceptance command yourself and report each one with its exact invocation and exit
code. Do not report success from reading the code. List anything you could not verify and why.
State `blocked` rather than inventing a way around a requirement that contradicts the code.

## Regression check
<Paste the output of `impact.sh --repo <repo> --format md` here.>

Check only what your change can plausibly break, and find it mechanically rather than by
reading the repository:

1. Run the tests listed above plus the acceptance commands. Nothing else.
2. When the list is empty or you changed a signature, find callers with one search
   (`git grep -n -w '<symbol>'`) and read only the call sites it returns.
3. Run the full suite only when the scope above says shared surface was touched, or when a
   targeted run is impossible.
4. Stop when the listed checks pass. Do not open files for reassurance, do not re-read your own
   diff, and do not audit code you did not change.

Report each command with its exit code, and state plainly what you did not check. An honest
"callers in `x.py` were not exercised by any test" is worth more than a broad scan.

## Environment (only for cloud or background workers)
- Network: needed / not needed. Secrets visible by name: … External systems it may write to: …
- Data that must not leave the machine: …
- Setup file, tool versions, and the smallest command that proves the environment works: …
Missing any of these means least privilege or local read-only, never "grant everything".

## Prohibitions
- Do not run `git commit`, `git push`, `git rebase`, `git checkout`, or any git command that
  changes history or the index.
- Do not modify files outside the Write scope.
- Do not add, upgrade, or remove dependencies.
- Do not weaken, skip, or delete an existing test to make the suite pass.
- Do not create documentation, examples, or scripts that were not requested.
- If a requirement is impossible or contradicts the code, stop and report it instead of
  inventing an alternative.

## Report
<Either: "Final message must be JSON matching the supplied schema."
 Or: an explicit list of what the prose answer must contain.>
```

## Rules that decide whether the output is usable

- **Make acceptance criteria executable.** "Works correctly" produces a worker's opinion; a
  command that must pass produces evidence you can re-run.
- **Fence the write scope by path.** Parallel workers with overlapping scopes overwrite each
  other, and nothing detects it until review.
- **Paste, do not reference.** A worker cannot read your session's instruction files, style
  rules, or earlier discussion. The one exception is a file it can open itself: a skill under
  `~/.omp/agent/skills`, or an `AGENTS.md` inside its `--cwd`. Give the absolute
  path and say to read it; drop the `## Skills` block when no installed skill applies.
- **Demand executed evidence, not a verdict.** A worker that says "verified" with no command
  and no exit code has reported nothing, and the review gate treats it that way.
- **Say what to do when blocked.** Without the last prohibition, a blocked worker invents a
  plausible substitute and reports success.
- **Ask for the diff to stay minimal** when touching existing code: no reformatting, no
  renames, no drive-by cleanups. Otherwise review cost explodes.
- **Keep the live-notes block and write the absolute path into it.** It is the only channel
  into a running worker; without it, a correction costs a whole run. Drop the block only for
  agents that finish in under a minute, where nothing can arrive in time anyway.

## Fix-round spec

Resumed threads keep the whole earlier conversation, so a fix spec is short and states
findings as facts:

```markdown
# Fix round <n>

Review findings on your previous change:

1. `src/cache.py:42` — the lock is released before the write completes, so two callers can
   interleave. Move the release after the flush.
2. `tests/test_cache.py:18` — the test asserts the call count, not the stored value, so the
   bug above passes. Assert the stored value.

Same scope and prohibitions as before. Fix exactly these two items and change nothing else.
Report what you changed per item.
```

## Research spec differences

For `read-only` research agents, replace Requirements with the questions, and add:

```markdown
## Evidence rules
- Every claim carries a source: a file path with a line number, a command with its output, or
  a URL you actually fetched.
- Report "not found" rather than inferring. Do not fill gaps with general knowledge.
- Separate what the source states from what you conclude from it.
- A number is a claim, and it needs the command that produced it standing next to it, in a
  form the reviewer can re-run. `wc -c` counts bytes and `wc -m` counts characters; for CJK
  text they differ by about two and a half times, so which one you ran is part of the number.
- When two documents state different numbers for the same measurement, and the thing measured
  is reachable from your tools, measure it. Report which document is wrong, not that they
  disagree. A contradiction you leave unresolved hands the reviewer the same work you were
  dispatched to do, and a read-only auditor with `grep` and the repository has no excuse for
  it. If the source is genuinely out of reach, say which command would settle it.
```
