Read this page for OpenCode tasks that depend on tier, variant, timeout, permission, or agent behavior.

You need not read it for shared orchestration steps that do not depend on OpenCode-specific flags or profiles.

# OpenCode engine reference

### 4. Pick the tier, the permission profile, and the limits

| `--tier` | `--variant` | use for | `--timeout` |
|----------|-------------|---------|-------------|
| `cheap` | `low` | mechanical edits, renames, formatting, extraction | 300–600 |
| `standard` | `medium` | default: a contained feature, docs, tests for one module | 900–1800 |
| `deep` | `high` | changes across several files, non-obvious bugs, refactors | 1800–3600 |
| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–5400 |
| `max` | `max` | one problem a `frontier` agent already failed twice; never a default | 3600–5400 |

**Hard ceiling: 5400 seconds (90 minutes) for any worker.** A worker still running past that is treated as suspect, non-essential work — repeated full gate runs, ablation of every hunk, a sixth version of the report — and is killed on sight, not waited for; every extra round re-reads the whole context and burns tokens by the hour. You finish from what is in its worktree: commit by theme, push, let CI be the gate. Cap the verification in the spec itself: one full gate run, two or three ablations of the hunks that matter, one report, and the sentence "do not repeat a full round".


A tier always sets the variant, and sets the model only when `OPENCODE_TIER_<TIER>_MODEL` is
exported. Both halves of a tier are configurable, so the ladder is data rather than code: `OPENCODE_TIER_<TIER>_MODEL` binds the model and `OPENCODE_TIER_<TIER>_VARIANT` overrides the variant. Set both in the machine-local env file and no job has to carry `--variant` by hand — a ladder that needs a flag on every dispatch is a ladder that will be forgotten on one.

Both halves matter, and they divide the ladder cleanly: below `deep` the **model**
changes, above it the **variant** does. A cheap model costs an order of magnitude less per token
than a flagship, and a read-only worker reads far more than it writes, so the input price is the
bill. Most of a run belongs on the cheap model at low variant, and promoting a task is a decision
rather than a default. `--model provider/model` and
`--variant` override a tier for one agent, and `--agent <preset>` carries a whole role — model,
temperature, tools, permissions — in one name.

| `--permission` | agent mode | grants | use for |
|----------------|------------|--------|---------|
| `read-only` | `plan` | reading tools and inspection commands only; no write tool exists | reading code, answering questions, planning |
| `inspect` (default) | `build` | every command except destructive and history-changing git; the edit tool is denied | audits, reviews, running tests and linters |
| `workspace-write` | `build` | the same commands, plus editing | all implementation |
| `full` | `build` | everything except history-changing git | rare, and only with the user's approval |
| `bypass` | `build` | everything, git included, plus `--auto` | a workspace you would hand a shell to |

Pick by what the task must *do*, not by how cautious it sounds. The mistake this table exists to
prevent: an auditor dispatched `read-only` cannot run the tests it is judging by, and the run is
wasted. Measured twice — a `read-only` worker denied `python3` spent 25 minutes retrying, and a
`plan`-mode worker with bash allowed still refused, answering "not run in plan mode" because its
own prompt tells it planning does not execute. `inspect` exists for exactly that job.

Two honest limits. First, `inspect` denies the *edit tool*, not writing: a shell command can
still create a file, which is why the review gate compares the changed files against the
declared scope instead of trusting the profile. Second, opencode has no sandbox at all, so none
of these is a containment boundary — on codex, `--sandbox read-only` blocks writes in the kernel
while still letting commands run, and that guarantee has no equivalent here.

`--allow-cmd PATTERN` adds one more permitted command to any profile, which is the right lever
when a `read-only` agent needs exactly one tool: `--allow-cmd "python3 */chinese_lint.py*"` beats
promoting the whole run to `inspect`.

The agent mode is the second boundary and the stronger one. `plan` has no write, edit, or patch
tool at all: measured with `edit: allow` in force, a plan agent still could not modify a file and
reported that it was blocked. `--agent` overrides the default when a named preset fits better.

Nothing in a profile may resolve to `ask`. opencode defaults `doom_loop` and `external_directory`
to ask, and either one would stop a non-interactive run dead until the timeout; the wrapper pins
them — `doom_loop` denied so a suspected runaway stops, `external_directory` allowed so a spec
can point a worker at a skill file outside the workspace.

`--network` allows webfetch, which is denied by default in every profile. `--allow-git` removes
the git denials and needs a reason. **Never configure `ask` in a profile** — a non-interactive
run has nobody to answer it and will sit until the timeout kills it.

`--timeout` is a runaway guard: estimate the work, then roughly triple it. `--stall` interrupts a
worker that has emitted no event for that long.

`--schema` appends the schema to the prompt and applies `json.loads` to the final message. It
checks JSON syntax only; OpenCode does not enforce schema conformance.

## The agent never returns

`opencode run` waits on inherited stdin. `oc_agent.sh` passes the prompt as an argument and
redirects stdin from `/dev/null`; without that the process sits with no output until it is
killed — measured at four minutes of nothing before a timeout, against seconds for the same
prompt with stdin closed.

`opencode run` also has no internal time limit, so every invocation is wrapped in `timeout`.
Exit code 124 or 137 means the wrapper killed it; `meta.json` reports `timed_out: true`, or
`stalled: true` when `--stall` fired instead.

A repeated timeout is a decomposition problem, not a timeout-value problem.

## `database is locked` when several agents start at once

opencode keeps session state in SQLite, and four processes reaching it in the same instant lose
to a busy database. `oc_agent.sh` serializes launches machine-wide behind a short hold
(`AGENT_START_STAGGER`, default 2 seconds) so a fan-out ramps in, and retries a launch that died
on a lock with quadratic backoff (`AGENT_LOCK_RETRIES`, default 4). A retry is only attempted
when the run produced no real events: a lock error happens before the model does anything, so
repeating it repeats nothing, while retrying a run that had started working would duplicate it.
Each failed attempt's stderr is kept as `stderr.attempt-<n>.log`.

Verified: four simultaneous dispatches now all reach distinct sessions and exit 0.

## The run hangs with no events at all

A permission profile containing `ask` will do this: the engine waits for an answer that no one
can give in a non-interactive run. The wrapper's profiles only ever use `allow` and `deny`; a
profile from elsewhere must be checked for `ask` before use.

## `Model "..." is not supported by any configured account`

The config lists a model the account behind the provider does not serve. The error arrives as a
404 several seconds into the dispatch, after it has been paid for, so `opencode models` belongs
in preflight rather than in the postmortem.

## A clean exit with an unusable result

Check `meta.json.schema_error`. The engine cannot enforce a schema, so a worker can finish
successfully and still answer in prose. That is a failed run: re-dispatch with a flatter schema
or drop the schema and read the prose yourself.

## The permission profile did not apply

`OPENCODE_CONFIG_CONTENT` merges with the user's config rather than replacing it, so the
provider and models survive. If a denied command still ran, the pattern did not match: opencode
matches shell patterns, and a more specific pattern wins over the wildcard.

## The agent wrote nothing

Check in this order:

1. `meta.json` → `exit_code`, `timed_out`
2. `stderr.log` → auth, network, or config failures
3. `events.jsonl` → `tool_use` entries whose state is `error`, usually a permission denial
4. the profile: `read-only` denies edits, and webfetch needs `--network`

## A worktree cannot be created

`--worktree` needs `--cwd` to be a git repository, and the branch name `opencode/<name>` must be
free unless the worktree is being reused deliberately. A leftover worktree from an aborted run
blocks reuse of the same path: `oc_worktrees.sh <run> --list` shows what is registered, and
`--remove-merged <base>` removes only what has already landed.

## Cost control

`oc_status.sh` totals the token usage per run. When output tokens run high for the value
returned, the usual causes are an effort level above what the task needs, a spec so vague the
worker explores the repository first, or a missing schema letting it write an essay.
