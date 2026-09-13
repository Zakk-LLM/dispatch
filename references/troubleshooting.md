# Failure modes

## The agent never returns

`omp -p` waits on inherited stdin, so `agent.sh --engine omp` passes the prompt as an argument and
redirects stdin from `/dev/null`.

omp does have an internal deadline: the wrapper passes `--max-time` from `--timeout`, and the
external `timeout` fires 60 seconds later as the backstop for a process that ignores its own
limit.
Exit code 124 or 137 means the wrapper killed it; `meta.json` reports `timed_out: true`, or
`stalled: true` when `--stall` fired instead.

A repeated timeout is a decomposition problem, not a timeout-value problem.

## `database is locked` when several agents start at once

omp keeps session state in a shared store, and four processes reaching it in the same instant lose
to a busy database. `agent.sh --engine omp` serializes launches machine-wide behind a short hold
(`AGENT_START_STAGGER`, default 2 seconds) so a fan-out ramps in, and retries a launch that died
on a lock with quadratic backoff (`AGENT_LOCK_RETRIES`, default 4). A retry is only attempted
when the run produced no real events: a lock error happens before the model does anything, so
repeating it repeats nothing, while retrying a run that had started working would duplicate it.
Each failed attempt's stderr is kept as `stderr.attempt-<n>.log`.

Verified: four simultaneous dispatches now all reach distinct sessions and exit 0.

## The run hangs with no events at all

An approval prompt will do this: print mode has nobody to answer it. Every profile therefore
runs with `--approval-mode yolo`, and the boundary comes from `--tools` instead — a worker
cannot call a tool it was not given.

## `Unknown tool in --tools`

The allowlist accepts exactly `read, grep, glob, lsp, yield, write, edit, bash, ast_edit` plus
the experiment tools and any MCP tool names. `web_search` is not among them; a worker that must
search needs `--permission full`, while one that only fetches a known URL can use `read`, which
accepts URLs as well as paths.

## `Model "..." is not supported by any configured account`

The config lists a model the account behind the provider does not serve. The error arrives
several seconds into a paid dispatch, so `omp models <provider>` belongs in preflight.

## A clean exit with an unusable result

Check `meta.json.schema_error`. The engine cannot enforce a schema, so a worker can finish
successfully and still answer in prose. That is a failed run: re-dispatch with a flatter schema
or drop the schema and read the prose yourself.

## A worker used a tool it should not have

Check `meta.json.sandbox` against the tools in `events.jsonl`. Withholding beats denying, so if
a tool appears that the profile excludes, the profile was not the one that ran — look for an
explicit `--tools` or `--permission full` in the dispatch line.

## The agent wrote nothing

Check in this order:

1. `meta.json` → `exit_code`, `timed_out`
2. `stderr.log` → auth, network, or config failures
3. `events.jsonl` → `tool_use` entries whose state is `error`, usually a permission denial
4. the profile: `read-only` denies edits, and webfetch needs `--network`

## The result contradicts the diff

Normal and expected. A worker's summary reports intent, not outcome. Only `git diff` and the
test run are evidence. When they disagree, the summary is wrong.

## Two agents fought over one file

Overlapping write scopes, and nothing detects it at dispatch time. Recover by keeping one
version, reverting the other, and re-dispatching with disjoint scopes. Prevent it with
`--worktree` per write-capable agent, plus file ownership assigned in `PLAN.md` before anything
is dispatched. See [worktrees.md](worktrees.md).

## A worktree cannot be created

`--worktree` needs `--cwd` to be a git repository, and the branch name `omp/<name>` must be
free unless the worktree is being reused deliberately. A leftover worktree from an aborted run
blocks reuse of the same path: `worktrees.sh <run> --list` shows what is registered, and
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

## A job with side effects was rejected

A worker whose approval was refused, whose guardrail fired, or whose acceptance failed keeps its run directory, worktree, and last state exactly as they are; nothing is cleaned up until the orchestrator has read them. Only the orchestrator restarts the work, either as a new job with a corrected spec or with an explicit `--resume` of the same thread. A worker never retries itself or rewrites its own goal to get past the refusal — that is the drift `REFLECT` exists to catch.

## Cost control

`status.sh` totals the token usage per run. When output tokens run high for the value
returned, the usual causes are an effort level above what the task needs, a spec so vague the
worker explores the repository first, or a missing schema letting it write an essay.
