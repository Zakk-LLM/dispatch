Read this page for Codex tasks that depend on tier, effort, timeout, sandbox, or profile behavior.

You need not read it for shared orchestration steps that do not depend on Codex-specific flags or profiles.

# Codex engine reference

### 5. Pick effort, sandbox, and timeout

Use the tables here to preserve the tier, sandbox, and timeout contract. Read
[references/tiers.md](references/tiers.md) for selection rules, overrides, and boundaries.

| `--tier` | effort | use for |
|----------|--------|---------|
| `cheap` | `low` | mechanical edits, renames, formatting, boilerplate, extracting known facts |
| `standard` | `medium` | default: a contained feature, a README, tests for existing code |
| `deep` | `high` | changes spanning several files, non-obvious bugs, behavior-preserving refactors |
| `frontier` | `xhigh` | architecture decisions, concurrency and performance work, ambiguous requirements |
| `max` | `max` | one problem a `frontier` agent already failed twice; never a default |

| sandbox | grants | use for |
|---------|--------|---------|
| `read-only` | runs any command, but the kernel blocks every write | research, audits, review, running tests and linters |
| `workspace-write` | writes under `--cwd` plus each `--add-dir` | all implementation work |
| `danger-full-access` | unrestricted | never without the user's explicit approval in this session |

| task shape | effort | `--timeout` |
|------------|--------|-------------|
| single-file mechanical edit, fact extraction | `low` | 300–600 |
| contained feature, README, tests for one module | `medium` | 900–1800 (default 1800) |
| change across several files, bug hunt with repro | `high` | 1800–3600 |
| architecture, concurrency, performance, vague spec | `xhigh` | 3600–5400 |
| the hardest single problem in the run | `max` | 3600–5400 |

# Picking effort, sandbox, and timeout

Difficulty decides both the reasoning depth and the model. `--tier` sets them together, so the
cheap work stays cheap without a decision per flag (the tier table itself stays in
`SKILL.md`, step 5, where the contract check reads it):

A tier always sets the reasoning effort. It sets the model only when the matching binding
exists: export `CODEX_TIER_CHEAP_MODEL`, `CODEX_TIER_STANDARD_MODEL`, `CODEX_TIER_DEEP_MODEL`,
`CODEX_TIER_FRONTIER_MODEL`, or `CODEX_TIER_MAX_MODEL` to bind one. Without a binding every tier
runs the model from the Codex config, so the cost separation is effort-only until they are set.

Both halves of a tier are configurable, so the ladder is data rather than code: `CODEX_TIER_<TIER>_MODEL` binds the model and `CODEX_TIER_<TIER>_EFFORT` overrides the effort. Set both in the machine-local env file and no job has to carry `--effort` by hand — a ladder that needs a flag on every dispatch is a ladder that will be forgotten on one.

Both halves matter, and they divide the ladder cleanly: below `deep` the **model** changes, above
it the **effort** does. A cheap model can cost an order of magnitude less per token than a
flagship, and research is where that lands hardest — a read-only worker reads far more than it
writes, so the input price is the bill. `--model` or `--effort` overrides a tier for one agent,
and `--profile <name>` layers a Codex config profile, which is the tidier place to keep a whole
worker role: model, effort, and storage in one named file.

Rate the task, not its importance. Most work in a run is `cheap` or `standard`; a run where
everything is `deep` is a run that was never triaged. When unsure, dispatch `cheap` first: a
failed cheap attempt costs less than an unnecessary deep one, and its output usually sharpens
the spec for the retry.

Sandbox is the permission boundary and defaults to the most restrictive option that can do
the job (the profile table is in `SKILL.md`, step 5):

`read-only` here is stronger and more permissive at once than a permission list: a worker may
run `pytest`, a linter, or anything else, and the sandbox stops the writes rather than the
commands. That is why an auditor belongs in `read-only` on this engine — it can execute the
checks it judges by without being able to change the tree. The opencode sibling has no
equivalent and needs its `inspect` profile instead.

`--network` grants *shell* network access, and only under `workspace-write` — the read-only
sandbox has no network permission at all, so `curl` and package installers cannot work there.
Codex's built-in web search is a different thing: it is server-side, on by default, and works
in every sandbox, which is why a `read-only` research agent can still search. Add
`--approve-for-me` when a worker legitimately needs to escalate a command instead of failing,
and grant write access to the smallest directory that contains the agent's files.

`--timeout` is a runaway guard, not a schedule, and it scales with the task — not with your
patience. A big task on a short timeout is the worst combination available: the wrapper kills
the worker mid-edit, and you inherit a half-applied change with no final report.

Estimate from the work, then roughly triple it, up to the ceiling: a worker spends most of its wall-clock reading
the repository and running commands, not generating text.

**Hard ceiling: 5400 seconds (90 minutes) for any worker.** A worker still running past that is treated as suspect, non-essential work — repeated full gate runs, ablation of every hunk, a sixth version of the report — and is killed on sight, not waited for; every extra round re-reads the whole context and burns tokens by the hour. You finish from what is in its worktree: commit by theme, push, let CI be the gate. Cap the verification in the spec itself: one full gate run, two or three ablations of the hunks that matter, one report, and the sentence "do not repeat a full round".


## Troubleshooting

## The agent never returns

`codex exec` inherits stdin. With a terminal or an open pipe on stdin it prints
`Reading additional input from stdin...` and waits forever. `codex_agent.sh` feeds the prompt
file on stdin, which closes at EOF; a hand-written invocation needs `< /dev/null` when the
prompt is an argument.

`codex exec` also has no internal time limit, so every invocation is wrapped in `timeout`. Exit
code 124 or 137 means the wrapper killed it — `meta.json` reports `timed_out: true`.

A repeated timeout is a decomposition problem, not a timeout-value problem. Split the task and
re-dispatch.

## `database is locked` when several agents start at once

Codex keeps session state in SQLite, and four processes reaching it in the same instant lose
to a busy database. `codex_agent.sh` serializes launches machine-wide behind a short hold
(`AGENT_START_STAGGER`, default 2 seconds) so a fan-out ramps in, and retries a launch that died
on a lock with quadratic backoff (`AGENT_LOCK_RETRIES`, default 4). A retry is only attempted
when the run produced no real events: a lock error happens before the model does anything, so
repeating it repeats nothing, while retrying a run that had started working would duplicate it.
Each failed attempt's stderr is kept as `stderr.attempt-<n>.log`.

Verified: four simultaneous dispatches now all reach distinct sessions and exit 0.

## `error: unexpected argument '-C' found`

The option was placed after the `resume` subcommand. Every option is a root option and belongs
before it: `codex exec -C dir -s mode --json -o out resume <thread> -`.

The same ordering matters semantically, not just syntactically. A resumed run inherits nothing
from the original — sandbox, working directory, model, and workspace roots all come from the
new invocation — so an omitted flag silently falls back to the config default instead of the
worker's original policy. `codex_agent.sh` repeats the full policy on every resume.

## A resumed agent cost far more than expected

Resume replays the entire thread as input. A single follow-up question on a long research
thread was metered at over 300K input tokens. Continue a thread for the context it holds, not
out of habit: when the context is small or reconstructible from the workspace, a fresh agent
with a precise spec is cheaper and carries no stale assumptions.

## The agent went quiet

`--stall SEC` interrupts a worker that has emitted no event for that long, which catches a hung
command or a retry loop long before the wall-clock timeout. `meta.json` reports `stalled: true`
so it is distinguishable from a genuine overrun. Check the last `command_execution` in
`events.jsonl` to see what it hung on.

There is no supported way to send input into a running `codex exec` — stdin is consumed at
start, and SIGINT is the only signal it interprets, as a graceful turn interrupt. Corrections
travel through `NOTES.md` (see the live-notes mechanism) or a fix round.

## `not inside a trusted directory` / git repo errors

`--skip-git-repo-check` is always passed by the script. Codex may still refuse to write in a
directory the user has not trusted; the user resolves that with `codex` interactively once, or
by adding the path under `[projects]` in their Codex config. Do not work around it by escalating
the sandbox.

## The agent wrote nothing

Check in this order:

1. `meta.json` → `exit_code`, `timed_out`
2. `stderr.log` → auth, network, or config failures
3. `events.jsonl` → `command_execution` entries with non-zero exits, usually a sandbox denial
4. the sandbox: writing outside `--cwd` needs `--add-dir`; network access needs `--network`

## The result contradicts the diff

Normal and expected. A worker's summary reports intent, not outcome. Only `git diff` and the
test run are evidence. When they disagree, the summary is wrong.

## Two agents fought over one file

Overlapping write scopes, and nothing detects it at dispatch time. Recover by keeping one
version, reverting the other, and re-dispatching with disjoint scopes. Prevent it with
`--worktree` per write-capable agent, plus file ownership assigned in `PLAN.md` before anything
is dispatched. See [worktrees.md](worktrees.md).

## A worktree cannot be created

`--worktree` needs `--cwd` to be a git repository, and the branch name `codex/<name>` must be
free unless the worktree is being reused deliberately. A leftover worktree from an aborted run
blocks reuse of the same path: `codex_worktrees.sh <run> --list` shows what is registered, and
`--remove-merged <base>` removes only what has already landed.

## The worker committed anyway

The prohibition block was missing or diluted. Recover with `git reset --soft HEAD~1`, review the
staged content, and decide yourself. Never leave `git commit` unmentioned in a spec that runs
with `workspace-write`.

## Rate limits or auth failures

`stderr.log` shows them plainly. Lower concurrency to two agents, and re-dispatch the failed
labels only. The completed agents' results stay valid — never restart a whole run for one
failed agent.

## Reading the event log

`events.jsonl` is one JSON object per line:

- `thread.started` → `thread_id`, needed for `--resume`
- `item.completed` with `type: "command_execution"` → the exact command, output, and exit code
- `item.completed` with `type: "agent_message"` → intermediate narration
- `turn.completed` → `usage` token counts

Filter instead of reading the whole file:

```sh
python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    i=e.get("item",{})
    if i.get("type")=="command_execution":
        print(i.get("exit_code"), i.get("command"))' <run>/agents/<label>/events.jsonl
```

## Reflection cannot judge the route

Repeated `CANNOT_JUDGE` means the inquiry lacks authoritative words. Put the maintainer's exact
correction in `<run>/maintainer.md`; do not ask the reflector to infer it.

## A reflection report is an error

For `reflect-<n>.error`, read `<run>/reflect/<label>-<n>/agents/reflector/events.jsonl`.
The failed inquiry is recorded and is never re-dispatched automatically.

## Cost control

`codex_status.sh` totals the token usage per run. When output tokens run high for the value
returned, the usual causes are an effort level above what the task needs, a spec so vague the
worker explores the repository first, or a missing schema letting it write an essay.
