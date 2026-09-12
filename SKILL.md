---
name: dispatch
description: Drive the omp, Codex, or OpenCode CLI as a fleet of worker agents while you stay the orchestrator and reviewer. Use when a task is large enough to split across parallel workers — feature implementation, refactors, bug hunts, test writing, documentation drafting, research, data collection, or multi-file audits — or whenever the user asks to delegate work to one of these engines. You write the plan, dispatch scoped agents, supervise, review every diff yourself, and own the commit, merge, and deploy steps that workers are never allowed to touch. omp's `read-only` grants no `bash`, so an audit that must run a check does not belong on that profile. Codex's `read-only` sandbox runs any command while the kernel blocks writes, so an auditor can execute the checks it judges by. opencode's `read-only` is plan mode and runs no commands; `inspect` is the profile that runs tests and linters.
---

# Dispatch orchestration

Workers write; you plan, supervise, review, and ship. Workers never commit, never push, never
deploy, and never decide that their own output is acceptable.

One run directory, tiers by difficulty, dependency ordering, bounded waiting, an evidence-based
review gate, and atomic integration are shared across all three engines.

## Relations

- Depends on: nothing.
- Upstream: `zakk-workflow` and `zakk-maintain` send dispatch here.
- Hands off to: `zakk-review` for judging what a worker returns and `zakk-workflow` for landing it and the completion report, when they are installed. Without them, the review section below is the gate.

The old skill names `omp`, `codex`, and `opencode` mean this skill with the corresponding
`--engine` value.

## Choosing the engine

| Engine | Read-only semantics | Give it |
|---|---|---|
| `omp` | `read-only` withholds `bash` and every write tool | review and research that need no command execution |
| `codex` | `read-only` runs commands while the kernel blocks writes | audits whose reviewer must execute tests or gates |
| `opencode` | `read-only` is plan mode; `inspect` runs commands | planning in `read-only`, tests and linters in `inspect` |

Read `references/engines/<engine>.md` before choosing its tier, profile, flags, or limits.

## What delegating buys you

**Context.** A worker explores in its own context window and returns a bounded result. File
reads, searches, failed commands, and dead ends stay outside the orchestrator's context.

**Cost per unit of difficulty.** Each task runs at the cheapest tier that can do it, so
mechanical work does not consume frontier reasoning by default.

**Independence.** A worker starts without your reasoning history. That makes a separately
specified worker useful for a second opinion instead of another pass over the same assumptions.

**Durability.** Each unit has a run directory, event log, result, and resumable engine identity.
The run directory preserves enough state to review or continue after interruption.

## What it costs you

Every worker requires a precise spec and one review pass paid by you. Dispatch adds process
startup, context priming, and integration work; parallelism does not reduce review obligations.
Engine-specific confinement, output validation, cost reporting, and resume behavior differ, so
selecting an engine is part of the task design rather than a cosmetic flag.

## Preflight

Set `DISPATCH_SKILL` to this skill's directory, then inspect the selected engine before dispatch:

```sh
"$DISPATCH_SKILL/scripts/agent.sh" --engine <e> --help
"$DISPATCH_SKILL/scripts/agents.sh" --list
"$DISPATCH_SKILL/scripts/capacity.sh" --engine <e> medium
```

The cap protects two pools. Codex and OpenCode share `AGENT_MAX_AGENTS` (default 5); omp uses
its own slot namespace and `OMP_MAX_AGENTS`. The process list includes registered and manually
started agents from every engine. A process started by hand holds no admission lock, so inspect
the list instead of trusting free slots alone.

Those limits do not measure review capacity. Keep about three review-bearing agents in flight;
raise concurrency only for uniform mechanical work whose review can be batched. `capacity.sh`
also considers cores, available memory, and load. Machine-local caps, tier bindings, and the soft
ceiling live in `${XDG_CONFIG_HOME:-~/.config}/agent-orchestration.env`.

## When not to use this

Do the work yourself when it is a single obvious edit, a one-file read, or anything you can
finish in less time than writing the spec. Fan out only when work decomposes by ownership or
independent question; a dependency chain usually belongs to one worker.

Never dispatch these, however large the run:

- **Git mechanics** — `worktrees.sh --rebase` and `merge.sh` perform them, and every worker spec forbids them.
- **A fix faster to make than to specify** — a typo, wrong constant, missing import, or one-line guard.
- **Anything you must verify line by line anyway** — review is the expensive half.
- **Running a command to read its output** — run it directly.

The test is whether a separate context window earns the spec plus the review: the same rename
across 200 files does; the same rename in three files does not. A trivial dispatch also occupies
a machine slot and puts another review ahead of work that needed one.

## Workflow

### 1. Create the run directory

```sh
RUN=$("$DISPATCH_SKILL/scripts/new_run.sh" add-auth-cache)
```

```text
<run>/PLAN.md                 decomposition, write scopes, acceptance criteria
<run>/jobs.jsonl              the fan-out, one job per line
<run>/schema/<name>.json      output schemas
<run>/sessions/               engine session files for this run
<run>/worktrees/<label>/      isolated checkout, branch <engine>/<label>
<run>/agents/<label>/prompt.md NOTES.md events.jsonl stderr.log result.json|last.txt
                     thread.txt started.json meta.json verify.json
<run>/REVIEW.md               your verdict per agent
```

`OMP_RUNS_DIR` overrides the base; the default is `${XDG_CACHE_HOME:-~/.cache}/omp-runs`.
Never use a tmpfs path.

### 2. Decompose, then declare the order

Split by file ownership. Record each label, exact write scope, engine, profile, tier, and
dependencies in `PLAN.md`. Give every write-capable agent its own `--worktree`.

A dependent job is not dispatched until its dependencies succeed and is skipped when one fails:

```json
{"label": "api", "engine": "codex", "tier": "deep", "worktree": true}
{"label": "client", "engine": "opencode", "tier": "standard", "worktree": true,
 "depends_on": ["api"]}
```

Unknown labels and cycles are rejected before anything starts. Order and atomicity enforce one
rule: work is built only on a dependency's finished result or the target's real commit.

### 3. Write the task spec

Create one file per agent from [references/prompt-template.md](references/prompt-template.md),
including the scope fence, executable acceptance criteria, live-notes block, and prohibitions.
Paste the regression scope from `impact.sh --repo <repo> --format md` rather than asking a worker
to discover it. Each worker runs targeted checks; the full suite runs once at integration.

### 4. Pick the engine, tier, profile, and limits

Choose from the actual access boundary the task needs, then read the selected operation page:

- [omp](references/engines/omp.md)
- [Codex](references/engines/codex.md)
- [OpenCode](references/engines/opencode.md)

Tier names are shared, but their model, thinking, effort, or variant bindings are engine-specific.
Profile names and resume identifiers are not portable across engines. `--timeout` also has
different outer grace periods. Codex enforces its supported JSON Schema subset; omp and OpenCode
only check that the final result parses as JSON.

### 5. Dispatch

```sh
"$DISPATCH_SKILL/scripts/dispatch.sh" --engine <e> --run-dir "$RUN" \
  --jobs "$RUN/jobs.jsonl" --weight medium --max 4
```

Each JSON job may override `engine`; otherwise it inherits `--engine`. Use `--dry-run` first when
checking a new jobs file. Starts are staggered behind a machine-wide lock, stdin is closed or
consumed to EOF, and each adapter records its engine in run metadata. Read the engine page for
its deadlines, resume semantics, and supported job fields.

### 6. Supervise without idling

```sh
"$DISPATCH_SKILL/scripts/watch.sh" "$RUN" --timeout 120 --peek
```

Exit 0 means agents changed state; 1 means the window is free for work that needs no agent; 2
means the run is finished; 3 means nothing was dispatched. Liveness comes from the event log's
mtime and final 4 KB. `EXPIRING` and `QUIET` warn before guards fire. Correct a running worker
with `note.sh`, which its spec tells it to re-read.

When watch prints `REFLECT`, run the shown `reflect.sh` command once; it is a reminder,
not a pause. The three verdicts and what each asks of you: [references/reflect.md](references/reflect.md).

**Never sit idle.** From the first dispatch to the last review, process returned work or do work
that does not depend on an agent. Fix an available regression ahead of the queue.

Protect your own context, not the worker's disposable context. Read `result.json` and
`verify.json`, use `status.sh --brief` as the digest, open `events.jsonl` only on failure, and
refer to artifacts by path instead of quoting them.

### 7. Review — the part you never delegate

An agent's report is a claim; a command you ran is evidence.

```sh
"$DISPATCH_SKILL/scripts/verify.sh" "$RUN" impl --check "pytest -q"
```

Read the diff, compare every changed file with the declared scope, run each acceptance criterion,
and run a negative control. Inspect engine-specific metadata such as `schema_error`, usage, or
cost where available. Follow [references/review-gate.md](references/review-gate.md).

### 8. Fix rounds and continuation

```sh
"$DISPATCH_SKILL/scripts/agent.sh" --engine <e> --run-dir "$RUN" --label impl-fix1 \
  --resume "$(cat "$RUN/agents/impl/thread.txt")" --cwd /path/to/repo \
  --permission <profile> --tier deep --prompt-file "$RUN/agents/impl-fix1/prompt.md"
```

Resume only with the same engine. Continue when the thread holds expensive, correct context;
start fresh when context is small, reconstructible, or based on a failed assumption. Report a
transport failure with its evidence rather than silently retrying it.

### 9. Integrate, then ship

```sh
"$DISPATCH_SKILL/scripts/merge.sh" --run-dir "$RUN" --repo /path/to/repo --into main \
  --check "pytest -q" --rebase
```

Integration is atomic per branch and for the run. Any conflict, failed rebase, or failed check
returns the target to the commit where the run started. Run the full suite here. Check drift
first with `worktrees.sh "$RUN" --drift main`. You perform every irreversible step and confirm
with the user before anything outward-facing.

## Common task shapes

- **Feature**: map the code with a read-only worker, then assign write-capable workers by module and worktree.
- **Bug hunt**: use different read-only lenses, confirm findings, then dispatch fixes only for confirmed failures.
- **README or docs**: collect facts, draft separately, then verify every command and factual claim.
- **Research and data collection**: require a source per claim and verify a sample yourself.
- **Migration or sweep**: use identical specs over disjoint file batches and merge in small batches.
- **Audit**: require each finding to state a concrete failure scenario and an acceptance condition.

## References

- [references/prompt-template.md](references/prompt-template.md) — task specification structure
- [references/schemas.md](references/schemas.md) — result shapes and engine-specific validation
- [references/worktrees.md](references/worktrees.md) — parallel writer isolation, integration, and cleanup
- [references/review-gate.md](references/review-gate.md) — evidence-based review protocol
- [references/troubleshooting.md](references/troubleshooting.md) — shared failure modes and recovery
- [references/reflect.md](references/reflect.md) — bounded reflection checkpoint
- [references/engines/omp.md](references/engines/omp.md) — omp tiers, profiles, flags, and limits
- [references/engines/codex.md](references/engines/codex.md) — Codex tiers, sandboxes, flags, and limits
- [references/engines/opencode.md](references/engines/opencode.md) — OpenCode tiers, permissions, flags, and limits
- [references/engines/evidence-omp.md](references/engines/evidence-omp.md) — evidence behind omp defaults
- [references/engines/evidence-codex.md](references/engines/evidence-codex.md) — evidence behind Codex defaults
- [references/engines/evidence-opencode.md](references/engines/evidence-opencode.md) — evidence behind OpenCode defaults
