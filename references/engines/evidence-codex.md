# Evidence behind the defaults

Collected by three `read-only` research agents dispatched with this skill, then checked against
the local Codex 0.147 installation, and later re-audited by two more agents against the source
archive. Vendor claims are labeled as such. Figures from development runs are marked as
observations: their run directories were deleted during cleanup, so they are reproducible by
re-running rather than by opening a retained artifact.

## When fan-out helps and when it hurts

- Anthropic reports a lead-plus-workers configuration beating a single agent by 90.2% on its
  internal research evaluation, with two-level parallelism cutting wall time on complex queries
  by up to 90%. It also states that breadth-first research fits multi-agent work while
  dependency-heavy coding with shared context often does not. Vendor measurement.
  <https://www.anthropic.com/engineering/multi-agent-research-system>
- A controlled study across 180 configurations under fixed token budgets reports centralized
  multi-agent coordination improving parallelizable analysis by 80.9%, while every multi-agent
  topology degraded sequential planning by 39–70%, with returns turning negative once the
  single-agent baseline was already strong.
- Cost: agents use roughly 4× the tokens of chat, multi-agent research roughly 15×. Anthropic's
  guidance scales worker count to query complexity rather than using a fixed fan-out.

Consequence in this skill: fan out on decomposable, breadth-first work; keep one agent for
sequential or shared-context work; treat three review-bearing agents as the working default.

## Parallel writers on one repository

- A study of co-active agent-authored pull requests found textual conflicts in 41.7% of
  cross-agent pairs against 19.8% for same-agent pairs; about 42% of conflicted files carried
  structural conflicts. A separate simulation over 107K agent-authored merges found 27.67%
  conflicting.
- Git documents worktrees as separate working files, HEAD, and index over a shared object
  store, with incomplete support for multiple superproject checkouts of submodules.
  <https://git-scm.com/docs/git-worktree>

Consequence: `--worktree` for every write-capable agent in a fan-out, plain clones for
submodule-heavy repositories, and file ownership assigned in `PLAN.md` regardless.

## Supervision and early termination

- Production agent platforms expose plan progress, tool activity, token usage, and session logs,
  and allow correcting a running agent after the current tool call or stopping it while keeping
  pushed commits.
- Recommended auto-stop conditions: budget exhaustion, repeated identical failure, forbidden
  file overlap, and no progress within a deadline.

Consequence: `--stall` interrupts a silent worker, `NOTES.md` corrects a running one, and
`meta.json` separates a failed command from a failed turn.

## Verification

- OpenAI's CriticGPT work reports critiques preferred over baseline in 63% of comparisons on
  naturally occurring bugs, with human-plus-critic beating unaided humans in over 60% while
  hallucinating fewer bugs than the model alone.
- Anthropic reports an evaluator agent driving the real application and finding concrete wiring
  and route-order bugs, while also noting that evaluator tuning was needed and deeper bugs still
  escaped.

Consequence: deterministic checks first, then an independent critic with a fresh context whose
findings are candidates, not verdicts.

## Codex CLI 0.147 mechanics

Read from the 0.147 source archive and confirmed against the installed binary.

- `codex exec resume` takes sandbox, working directory, model, and workspace roots from the new
  invocation; nothing is inherited from the original run. Root options belong before the
  `resume` subcommand — verified by running `codex exec -C dir -s read-only … resume <thread>`.
- Resume replays the saved thread as input. A one-line follow-up on a long research thread was
  metered at over 300K input tokens (development observation, run directory not retained), so continuations are budgeted, never assumed free.
- No supported channel exists for sending input into a running `codex exec`; stdin is consumed
  to EOF at start, and SIGINT maps to a graceful turn interrupt. The experimental
  `codex app-server` exposes `turn/steer` and `turn/interrupt` for genuinely steerable work.
- `--output-schema` is forwarded unvalidated by the CLI; the API enforces object root, all
  properties required, `additionalProperties: false`, no `allOf`/`oneOf`/`if`/`not`, 10 levels
  of nesting, 5,000 properties, and 120,000 schema characters. The wrapper pre-checks these.
- JSONL event types are `thread.started`, `turn.started`, `turn.completed`, `turn.failed`,
  `item.started`, `item.updated`, `item.completed`, and `error`. A top-level `error` is a
  notification, not a verdict: reconnect notices use it while the turn keeps running, so
  terminal status comes from `turn.failed` or a non-zero process exit. Item payloads include
  `command_execution` with exit codes and `file_change` with paths. An interrupted turn emits no
  terminal event, so process exit is also checked.
- Adopted since: config profiles, exposed as `--profile` and the `profile` job key.
- Useful but unadopted: `--strict-config` for version drift, execpolicy `.rules` as a deterministic command guard (preview), a dedicated
  `CODEX_HOME` for namespace isolation, and `--ephemeral` when no resume is needed.

## Dispatch overhead, measured

The same one-word task ("reply READY", no tools used) was metered at roughly 20K input tokens
through `codex exec` and roughly 8K through `opencode run` on the same provider and account.
That gap is the engines' base instruction sets, and it is paid on every dispatch before the task
begins. It changes two things:

- The floor cost per agent is engine-specific, so a fan-out of many tiny agents is proportionally
  more expensive on codex than on opencode.
- The tier choice matters more, not less, for small tasks: 20K input tokens costs $0.10 on a
  flagship priced at $5 per million and $0.004 on a cheap model at $0.20 per million.

Consequence: batch trivial work into fewer agents rather than dispatching one per item, and keep
mechanical work on the cheap tier where the fixed overhead is nearly free.

Gaps the research could not close: no published production comparison of worktree versus
container isolation cost, no measurement of orchestrator review time as worker count grows, and
no confirmed JSONL shape for a service-side schema rejection.
