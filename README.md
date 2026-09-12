# omp Orchestration Skill

English | [繁體中文](README.zh-TW.md)

The routing table for the whole skill set — which skill to read for which task — lives in [zakk-workflow's README](https://github.com/Zakk-LLM/zakk-workflow#boundaries-with-the-sibling-skills).

A skill for driving a fleet of omp (oh-my-pi) workers from an orchestrating agent that keeps
planning, supervision, review, and shipping for itself. Third sibling of
[codex-orchestration](https://github.com/Zakk-LLM/codex-orchestration) and
[opencode-orchestration](https://github.com/Zakk-LLM/opencode-orchestration): same run
directory, same tiers, same review gate, same atomic integration, a different engine.

The division of labor is fixed. Workers produce code and drafts only. The orchestrator reads the
real diff, runs the tests, and writes the verdict; commits, merges, and releases stay with it.

## Requirements

- omp 17 or newer with a working provider
- Python 3.11 or newer
- Bash

## Install

```bash
git clone <repository-url> omp-orchestration
cd omp-orchestration
./install.sh
```

| Agent | Location |
|---|---|
| Claude | `~/.claude/skills/omp` |
| Codex | `${CODEX_HOME:-~/.codex}/skills/omp` |
| OpenCode | `~/.config/opencode/skills/omp` |
| omp | `${OMP_CONFIG_DIR:-~/.omp/agent}/skills/omp` |

## What this engine changes

**A real cost figure.** Every assistant message carries `usage.cost` in dollars, so `meta.json`
records what a run cost. Measured on one fixture: the same one-file fix cost $0.167 on the
flagship model and $0.0047 on the cheap one — a 35× spread that a token count alone hides.

**Tool withholding as the boundary.** `--tools` is an allowlist and a worker cannot call a tool
it was not given: a `read-only` worker has no `write`, `edit`, or `bash` at all.

**Sessions inside the run.** `--session-dir` keeps every session file in `<run>/sessions/`, so a
run directory is self-contained.

**A built-in deadline.** `--max-time` stops the session from the inside; the external `timeout`
is only the backstop.

**Roles as files.** `--role <name>` appends an agent definition from `~/.omp/agent/agents/` to
the system prompt.

**No sandbox**, like opencode: the allowlist is the entire boundary, so untrusted work does not
belong here. **No schema enforcement**: the wrapper appends the contract to the prompt and
validates the answer, exiting 65 on a violation. **No `web_search` in the allowlist**: `read`
accepts URLs, but a worker that must search needs `--permission full`.

## Usage

```bash
RUN=$(scripts/new_run.sh add-auth-cache)
scripts/agents.sh --list          # every engine's agents, machine-wide
scripts/capacity.sh --engine omp medium

scripts/agent.sh --engine omp --run-dir "$RUN" --label cache \
  --cwd /path/to/repo --worktree --permission workspace-write \
  --tier deep --timeout 1800 --stall 300 \
  --prompt-file "$RUN/agents/cache/prompt.md" --schema "$RUN/schema/impl.json"

scripts/dispatch.sh --engine omp --run-dir "$RUN" --jobs "$RUN/jobs.jsonl" --weight medium
scripts/watch.sh "$RUN" --timeout 120 --peek
scripts/verify.sh "$RUN" cache --check "pytest -q"
scripts/merge.sh --run-dir "$RUN" --repo /path/to/repo --into main --check "pytest -q"
```

Every script documents its options under `--help`.

## Permission profiles

| Profile | Tools granted | Use for |
|---|---|---|
| `read-only` | `read, grep, glob, lsp, yield` | research, review, any judgement reachable by reading |
| `workspace-write` | plus `write, edit, bash, ast_edit` | implementation |
| `full` | every tool, MCP included | search-dependent work |
| `bypass` | every tool, approvals off | only in a workspace you would hand a shell to |

Every profile disables approvals, because print mode has nobody to answer a prompt and would
hang until the deadline. The allowlist, not an approval rule, is the boundary.

These profile names are omp's own. `read-only` here is a tool allowlist, not codex's kernel
sandbox, and omp has no `inspect` profile like opencode's — so an audit that must run tests or a
linter goes to `workspace-write` on this engine, or to a sibling.

## Shared with the sibling toolkits

The agent cap protects two different things. A metered engine shares `AGENT_MAX_AGENTS`
(default 5) with its siblings so a rate limit is not blown; omp on a subscription has no such
limit, so it locks its own namespace under `OMP_MAX_AGENTS` and neither starves the metered
engines nor waits behind them — 32 concurrent verified on one machine. That number is not your
review capacity: three agents needing a diff read each is still the working default, and
`AGENT_CONCURRENCY_CEILING` raises the soft ceiling only for uniform work whose review is
batched. Tier-to-model bindings and the cap live in
`${XDG_CONFIG_HOME:-~/.config}/agent-orchestration.env`.

Tiers, dependency ordering, worktree isolation, bounded waiting, deadline warnings, the
regression-scope tool, the review gate, and atomic integration behave as documented in the
siblings. Read [SKILL.md](SKILL.md) and `references/`:

- [references/prompt-template.md](references/prompt-template.md)
- [references/schemas.md](references/schemas.md)
- [references/worktrees.md](references/worktrees.md)
- [references/review-gate.md](references/review-gate.md)
- [references/troubleshooting.md](references/troubleshooting.md)
- [omp engine reference](references/engines/omp.md)
- [omp engine evidence](references/engines/evidence-omp.md)

## Known constraints

- `omp -p` waits on inherited stdin; the wrapper redirects it from `/dev/null`.
- `--tools` accepts a fixed vocabulary; an unknown name aborts the run before it starts.
- Session state is shared, so simultaneous launches are staggered behind a machine-wide lock and
  a `database is locked` failure retries with backoff.
- Two agents writing one checkout overwrite each other; worktrees and `PLAN.md` ownership
  prevent it.

## Checks

`sh scripts/check-all.sh` runs everything this repository can check about itself: the tier
ladder still projects to the agreed values, the description states this engine's read-only
execution boundary, both READMEs keep the note that these profile names do not carry to the
siblings, the worker prompt template still carries every evidence rule, and every
shell script parses. The controls that follow break each of those on a
temporary copy to prove the checks can still fail. CI runs the same command.

## License

MIT
