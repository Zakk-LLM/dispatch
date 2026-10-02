# omp engine reference

Read this page for omp tasks that depend on tier, thinking, timeout, permission, or tool-access behavior.
You need not read it for shared orchestration steps that do not depend on omp-specific flags or profiles.

## What omp gives you that the others do not

**A real cost figure.** Every assistant message carries `usage.cost` in dollars, so `meta.json`
records what a run actually cost rather than a token count you have to price yourself. Measured:
the same one-file fix cost $0.084 on the flagship and $0.0024 on the cheap model — a 35× spread
that is invisible without this number.

**Tool withholding as the boundary.** `--tools` is an allowlist, and a worker cannot call a tool
it was not given. A `read-only` worker has no `write`, `edit`, or `bash` at all, which is
stronger than a permission rule that says no.

**Sessions inside the run.** `--session-dir` puts every session file in `<run>/sessions/`, so a
run directory is self-contained and a resume needs no global state.

The internal `--max-time` limit stops a session cleanly. The shared recovery runner also
enforces the original job deadline across attempts, including backoff.

**Roles as files.** `--role <name>` appends an agent definition from `~/.omp/agent/agents/` to
the system prompt, so a worker persona lives in one reusable file.

## What it costs you

**No sandbox.** Like opencode and unlike codex, there is no OS-level confinement: the tool
allowlist is the entire boundary. Do not run untrusted work.

**No schema enforcement.** Print mode cannot force a shape. The wrapper appends the schema to
the prompt and validates the answer afterwards, exiting 65 and recording `schema_error` when it
does not parse.

**The result may arrive through `yield`.** Some models (Kimi K3) submit the review with the
`yield` tool and end with no assistant text. The wrapper takes the last non-progress `yield`
payload as the result unless assistant text follows it: a lone string field becomes the text,
anything else is written as JSON.

**Search is not in the allowlist.** `--tools` accepts `read, grep, glob, lsp, yield, write,
edit, bash, ast_edit` and a few experiment tools; there is no `web_search` among them. The
`read` tool does take a URL, so a restricted worker can still fetch a page it is given, but a
worker that must *search* needs `--permission full`, where MCP search tools are available.

| `--tier` | `--thinking` | use for | `--timeout` |
|----------|--------------|---------|-------------|
| `cheap` | `low` | mechanical edits, renames, formatting, extraction | 300–600 |
| `standard` | `medium` | default: a contained feature, docs, tests for one module | 900–1800 |
| `deep` | `high` | changes across several files, non-obvious bugs, refactors | 1800–3600 |
| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–5400 |
| `max` | `max` | one problem a `frontier` agent already failed twice | 3600–5400 |

See [timeout and shutdown](../../SKILL.md#timeout-and-shutdown) for the 5400-second ceiling and guards.
Follow the [worker contract](../review-gate.md#worker-contract) for Git ownership, artifact scope, targeted checks and `not run`.


A tier always sets the thinking level, and sets the model when `OMP_TIER_<TIER>_MODEL` is bound.

Which half of the ladder to climb first is a question about your models, not a rule. A mid-tier
model at maximum thinking is often better *and* cheaper than a top-tier model at moderate
thinking, and when that holds the tiers should exhaust the thinking levels on the mid model
before paying for the top one. Test it before assuming either way: dispatch the same hard task
twice, once at each configuration, compare the results against something checkable, and compare
`usage.cost`. Bind the answer in `OMP_TIER_<TIER>_MODEL` and leave this file provider-neutral.

Both halves of a tier are configurable, so the ladder is data rather than code: `OMP_TIER_<TIER>_MODEL` binds the model and `OMP_TIER_<TIER>_THINKING` overrides the thinking. Set both in the machine-local env file and no job has to carry `--thinking` by hand — a ladder that needs a flag on every dispatch is a ladder that will be forgotten on one.

### Quota-aware routing

A provider can run out, and `omp usage -j` reports each authenticated provider's live limits —
`usedFraction`, `status`, and `limitReached` per window — so the ladder can move off a provider
*before* it hard-stops instead of after. Bind a second ladder in the same env file with
`OMP_TIER_<TIER>_FALLBACK_MODEL` and `OMP_TIER_<TIER>_FALLBACK_THINKING`; then, before a batch,
read the primary provider's `usedFraction` and route by it. Below a comfortable fraction every
tier runs primary. As it climbs, drop the *cheap* tiers to the fallback first, so the remaining
quota is spent only where the stronger provider earns it. Past the warning fraction (or
`limitReached`), run every tier on the fallback until the window resets. The wrapper already applies the last step on its own: a tier whose
primary provider is at or past `OMP_FALLBACK_AT` (default 0.9) or `limitReached` resolves to its
fallback binding, with the report cached for two minutes. The graded shift below that threshold
is your call: resolve the model and thinking per worker and pass them with `--model`/`--thinking`. Prefer the primary while it has
headroom — the fallback is a weaker bench, not a co-equal. When the fallback serves the same models on a pay-per-use upstream, skip the graded shift: raise `OMP_FALLBACK_AT` close to 1 so every tier stays on the subscription until it is nearly spent, then moves at once. This keeps the file provider-neutral:
which providers are primary and fallback, and the exact fractions, are data in the env, not
names here.

Explicit `--model provider/model` bypasses tier quota routing. For a configured mirror, use
`--model codex-relay/gpt-6.1-sol` or `--model codex-relay/gpt-6-astra`; the relay has no luna.
Runtime fallback pairs belong in the machine-local env file, not this routing table.
See [shared recovery](../troubleshooting.md#rate-limits-or-auth-failures) for bounded same-session
recovery after a quota or transient failure, preserved deadlines and the opt-out flag.

What does not change: a read-only worker's bill is almost all input, so the cheapest model at
low thinking is right for most of a run, and promoting a task is a decision rather than a
default.

| `--permission` | tools granted | use for |
|----------------|---------------|---------|
| `read-only` | `read, grep, glob, lsp, yield` | research, review, any judgement reachable by reading |
| `workspace-write` | plus `write, edit, bash, ast_edit` | implementation |
| `full` | every tool, MCP included | search-dependent work, with care |
| `bypass` | every tool, approvals off | only in a workspace you would hand a shell to |

Every profile runs with approvals disabled, because a print-mode run has nobody to answer a
prompt and would sit until the deadline. That is exactly why the allowlist, not an approval
rule, is the boundary.
See the [worker contract](../review-gate.md#worker-contract) for Git ownership and artifact scope.

These profile names are omp's own. `read-only` here is a tool allowlist, not codex's kernel
sandbox, and omp has no `inspect` profile like opencode's — so an audit that must run tests or
a linter goes to `workspace-write` on this engine, or to a sibling. Reusing a sibling's mental
model of the same name is how a research agent ends up unable to run the check it was sent to
run.
