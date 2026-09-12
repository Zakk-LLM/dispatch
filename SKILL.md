---
name: omp
description: Drive the omp (oh-my-pi) CLI as a fleet of worker agents while you stay the orchestrator and reviewer. Use when a task is large enough to split across parallel workers — feature implementation, refactors, bug hunts, test writing, documentation drafting, research, multi-file audits — or whenever the user asks to delegate work to omp. You write the plan, dispatch scoped agents, supervise, review every diff yourself, and own the commit, merge, and deploy steps that workers are never allowed to touch. Sibling of the `codex` and `opencode` skills: same workflow, same run directory, different engine. omp's `read-only` grants no `bash`, so an audit that must run a check does not belong on this engine. Codex's `read-only` sandbox runs any command while the kernel blocks writes. OpenCode's `read-only` is plan mode and runs no commands; use `inspect` when an audit must execute checks.
---

# omp Orchestration

omp writes; you plan, supervise, review, and ship. Workers never commit, never push, never
deploy, and never decide that their own output is acceptable.

Same design as the `codex` and `opencode` skills — one run directory, tiers by difficulty,
dependency ordering, bounded waiting, an evidence-based review gate, atomic integration — with
omp as the engine. Only the engine-specific parts are marked below.

## Relations

- Depends on: nothing.
- Parallel: `codex` and `opencode` are the same design on other engines. Pick one per run.
- Hands off to: `zakk-review` for judging what a worker returns and `zakk-workflow` for landing it and the completion report, when they are installed. Without them, the review section below is the gate.
- Upstream: `zakk-workflow` and `zakk-maintain` send dispatch here.

## What omp gives you that the others do not

**A real cost figure.** Every assistant message carries `usage.cost` in dollars, so `meta.json`
records what a run actually cost rather than a token count you have to price yourself. Measured:
the same one-file fix cost $0.167 on the flagship and $0.0047 on the cheap model — a 35× spread
that is invisible without this number.

**Tool withholding as the boundary.** `--tools` is an allowlist, and a worker cannot call a tool
it was not given. A `read-only` worker has no `write`, `edit`, or `bash` at all, which is
stronger than a permission rule that says no.

**Sessions inside the run.** `--session-dir` puts every session file in `<run>/sessions/`, so a
run directory is self-contained and a resume needs no global state.

**A built-in deadline.** `--max-time` stops the session cleanly from the inside; the external
`timeout` is only the backstop for a hang.

**Roles as files.** `--role <name>` appends an agent definition from `~/.omp/agent/agents/` to
the system prompt, so a worker persona lives in one reusable file.

## What it costs you

**No sandbox.** Like opencode and unlike codex, there is no OS-level confinement: the tool
allowlist is the entire boundary. Do not run untrusted work.

**No schema enforcement.** Print mode cannot force a shape. The wrapper appends the schema to
the prompt and validates the answer afterwards, exiting 65 and recording `schema_error` when it
does not parse.

**Search is not in the allowlist.** `--tools` accepts `read, grep, glob, lsp, yield, write,
edit, bash, ast_edit` and a few experiment tools; there is no `web_search` among them. The
`read` tool does take a URL, so a restricted worker can still fetch a page it is given, but a
worker that must *search* needs `--permission full`, where MCP search tools are available.

## Preflight

```sh
omp --version || echo "omp not installed — stop and tell the user"
"$OMP_SKILL/scripts/agents.sh" --list      # every engine's agents, machine-wide
omp models | head                              # models this config can actually reach
```

The agent cap exists to protect two different things, and they separate here. A metered engine
shares `AGENT_MAX_AGENTS` (default 5) with its siblings so a rate limit is not blown; an engine
with no such limit — omp on a subscription — locks its own slot namespace under
`OMP_MAX_AGENTS` instead, so it cannot starve the metered ones and is not starved by them.
Verified at 32 concurrent on one machine.

What that number never covers is your review capacity. Thirty agents can run while three can be
reviewed properly, so a high cap belongs to uniform mechanical work whose review is batched, and
the working default stays at about three review-bearing agents in flight. `capacity.sh`
still bounds the answer by cores, free memory, and load, with a soft ceiling of 8 that
`AGENT_CONCURRENCY_CEILING` raises for a run that has earned it.

Machine-local settings — the caps, the tier bindings, the ceiling — live in
`${XDG_CONFIG_HOME:-~/.config}/agent-orchestration.env`, which every wrapper sources.

## When not to use this

Do the work yourself when it is a single obvious edit, a one-file read, or anything you can
finish in less time than writing the spec. Fan out only when the work decomposes; your review
capacity, not the worker count, is the limit — about three review-bearing agents in flight.

Never dispatched, however large the run:

- **Git mechanics** — `worktrees.sh --rebase` and `merge.sh` do them in one command, and
  the spec forbids workers from running them anyway.
- **A fix faster to make than to specify** — a typo, a wrong constant, a one-line guard.
- **Anything you must verify line by line anyway** — review is the expensive half.
- **Running a command to read its output** — you can run it directly.

The test is whether a separate context window earns the spec plus the review: the same rename
across 200 files does, the same rename in three files does not. A dispatched trivial task also
holds a slot the machine cap counts and puts a review ahead of one that mattered.

## Workflow

### 1. Create the run directory

```sh
RUN=$("$OMP_SKILL/scripts/new_run.sh" add-auth-cache)
```

```
<run>/PLAN.md                 decomposition, write scopes, acceptance criteria
<run>/jobs.jsonl              the fan-out, one job per line
<run>/schema/<name>.json      output schemas
<run>/sessions/               omp session files for this run
<run>/worktrees/<label>/      that agent's isolated checkout, branch omp/<label>
<run>/agents/<label>/prompt.md NOTES.md events.jsonl stderr.log result.json|last.txt
                     thread.txt started.json meta.json verify.json
<run>/REVIEW.md               your verdict per agent
```

`OMP_RUNS_DIR` overrides the base; the default is `${XDG_CACHE_HOME:-~/.cache}/omp-runs`. Never
a tmpfs path.

### 2. Decompose, then declare the order

Split by file ownership. A dependent job is not dispatched until its dependencies succeed, and
is skipped when one fails:

```json
{"label": "api",    "tier": "deep",     "permission": "workspace-write", "worktree": true}
{"label": "client", "tier": "standard", "permission": "workspace-write", "worktree": true,
 "depends_on": ["api"]}
```

Order and atomicity are one design: work is only ever built on a state that exists — a
dependency's finished result, or the target's real commit. Unknown labels and cycles are
rejected before anything starts.

### 3. Write the task spec

One file per agent from [references/prompt-template.md](references/prompt-template.md), with the
scope fence, executable acceptance criteria, the live-notes block, and the prohibitions. Paste
the regression scope from `impact.sh --repo <repo> --format md` instead of letting the worker
search for it; each agent runs the targeted tests and the full suite runs once at integration.

### 4. Pick the tier, the profile, and the limits

Tiers are the difficulty ladder, while profiles define the tool boundaries for a worker.
Read [the omp engine page](references/engines/omp.md) for the tables, flags, and limits.

### 5. Dispatch

```sh
"$OMP_SKILL/scripts/dispatch.sh" --engine omp --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" \
  --weight medium --max 4        # --dry-run prints the commands first
```

Engine-specific rules:

- stdin is closed; the prompt is an argument. An inherited stdin would keep the process waiting.
- `--max-time` is omp's own deadline and the wrapper sets it from `--timeout`; the external
  `timeout` fires 60 seconds later as the backstop.
- Starts are staggered behind a machine-wide lock and a launch that dies on `database is locked`
  is retried with backoff, only ever when the run produced no events.
- The session id comes from the first `session` event and lands in `thread.txt`.

### 6. Supervise without idling

```sh
"$OMP_SKILL/scripts/watch.sh" "$RUN" --timeout 120 --peek
```

Exit 0 means agents changed state; 1 means the window is free for work that needs no agent; 2
means the run is finished; 3 means nothing was dispatched. Liveness is the event log's mtime plus
its last event read from the final 4 KB — never the whole log. `EXPIRING` and `QUIET` warn before
the guards fire. Correct a running worker with `note.sh`, which its spec tells it to re-read.

When watch prints `REFLECT`, run the shown `reflect.sh` command once; it is a reminder,
not a pause. The three verdicts and what each asks of you: [references/reflect.md](references/reflect.md).

**Never sit idle.** From the first dispatch to the last review you are either processing a
returned agent or doing work that does not depend on one. A regression you can fix now is fixed
ahead of the queue.

#### Keeping your own context small

The context that needs protecting is yours. A worker's context is disposable — created for one
task, gone with it — so let workers read whatever they need, and never split a task or shorten a
spec to save a worker's context. Only the report is bounded, because that is the part that lands
in you: read `result.json` and `verify.json`, use `status.sh --brief` as the digest, open
`events.jsonl` only when something failed, and refer to artifacts by path instead of quoting
them. Summarize for the user from the diff and the check results, not from the worker's prose.

### 7. Review — the part you never delegate

An agent's report is a claim; a command you ran is evidence.

```sh
"$OMP_SKILL/scripts/verify.sh" "$RUN" impl --check "pytest -q"
```

Read the diff, check every changed file against the declared scope, run each acceptance
criterion, and run a negative control. Check `meta.json.schema_error` and `usage.cost` — a
worker that cost a dollar for a rename was dispatched at the wrong tier. Protocol in
[references/review-gate.md](references/review-gate.md).

### 8. Fix rounds and continuation

```sh
"$OMP_SKILL/scripts/agent.sh" --engine omp --run-dir "$RUN" --label impl-fix1 \
  --resume "$(cat "$RUN/agents/impl/thread.txt")" --cwd /path/to/repo \
  --permission workspace-write --tier deep --prompt-file "$RUN/agents/impl-fix1/prompt.md"
```

Resuming replays the session, so continue one for the context it holds and start fresh when the
context is small, reconstructible, or already proven wrong. A transport failure is reported to
the user with its evidence rather than silently retried.

### 9. Integrate, then ship

```sh
"$OMP_SKILL/scripts/merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q" --rebase
```

Atomic per branch and for the run: any conflict, failed rebase, or failed check returns the
target to the commit the run started from. This is where the full suite belongs. Check drift
first with `worktrees.sh "$RUN" --drift main`. You perform every irreversible step, and
confirm with the user before anything outward-facing.

## References

- [references/prompt-template.md](references/prompt-template.md) — the task spec structure
- [references/schemas.md](references/schemas.md) — result shapes and how they are validated here
- [references/worktrees.md](references/worktrees.md) — isolating parallel writers, merging, cleanup
- [references/review-gate.md](references/review-gate.md) — the anti-optimism review protocol
- [references/troubleshooting.md](references/troubleshooting.md) — failure modes and recovery
- [references/engines/omp.md](references/engines/omp.md) — omp tiers, profiles, flags, and limits
- [references/engines/evidence-omp.md](references/engines/evidence-omp.md) — the measurements behind these defaults
- [references/engines/codex.md](references/engines/codex.md) — Codex tiers, sandboxes, flags, limits, and troubleshooting
- [references/engines/evidence-codex.md](references/engines/evidence-codex.md) — the measurements behind the Codex defaults
- [references/engines/opencode.md](references/engines/opencode.md) — OpenCode tiers, permissions, flags, limits, and troubleshooting
- [references/engines/evidence-opencode.md](references/engines/evidence-opencode.md) — the measurements behind the OpenCode defaults
