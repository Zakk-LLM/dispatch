# Evidence behind the defaults

Measured against opencode 1.18 on one machine and one provider while building this skill.
Anything not measured here is inherited from the sibling skills. Figures come from development
runs whose directories were not retained, so they are reproducible by re-running rather than by
opening an artifact.

## The engine's contract

- `opencode run --format json` emits JSONL with `step_start`, `text`, `tool_use`, `step_finish`,
  and `error`. The session id is on every event, including error events, so a failed run stays
  resumable.
- `step_finish` carries `tokens` (input, output, reasoning, cache) and a `cost` field.
- Tool calls arrive as `tool_use` events whose `part.tool` names the tool; `apply_patch` names
  its target files inside the patch text rather than in a path field.
- Print mode waits on inherited stdin: a probe with stdin open produced no output for four
  minutes before its timeout, while the same prompt with stdin closed answered in seconds.

## The permission model

`OPENCODE_CONFIG_CONTENT` **merges** with the user's config rather than replacing it: a run
carrying only a `permission` block still resolved the provider, models, and MCP servers from the
user's own file. That is what makes a per-run boundary possible without touching their config.

`plan` mode is the stronger boundary. With `edit: allow` in force, a plan agent still could not
modify a file and reported that it was blocked, because plan has no write tool at all. read-only
therefore defaults to plan and gets two independent boundaries.

opencode defaults `doom_loop` and `external_directory` to `ask`. An `ask` in a non-interactive
run has nobody to answer it and hangs until the deadline, so both are pinned by the wrapper.

## Model reachability

A model listed in the config is not necessarily served by the account behind it: `codex-mini-latest`
returned `not supported by any configured account in this group` several seconds into a paid
dispatch. `opencode models` belongs in preflight.

## Dispatch overhead

A one-word reply with no tool use metered at roughly 8K input tokens, the lowest of the three
engines, against roughly 20K for `codex exec` and 16.6K for `omp -p` on the same account.

## Concurrency

Four simultaneous launches lose to a busy SQLite database. Starts are serialized behind a
machine-wide lock and a lock failure retries with backoff; verified afterwards with four
dispatches fired at once reaching four distinct sessions, all exiting 0. The agent cap is shared
with the codex and omp toolkits.
