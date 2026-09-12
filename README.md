# Dispatch Orchestration Skill

English | [繁體中文](README.zh-TW.md)

The routing table for the whole skill set — which skill to read for which task — lives in [zakk-workflow's README](https://github.com/Zakk-LLM/zakk-workflow#boundaries-with-the-sibling-skills).

Dispatch drives omp, Codex, or OpenCode workers while the orchestrator retains planning,
supervision, review, commits, merges, and releases. Every engine uses the same run directory,
difficulty tiers, dependency ordering, review gate, and atomic integration. The selected engine
keeps its own access boundary, model controls, event format, timeout behavior, and resume IDs.
Python 3.11 or newer and Bash are required, together with at least one configured engine CLI.

<!-- skill-map -->
## Map

```text
a task arrives
 ├─ structure ────▶ zakk-architecture ──interface values──▶ web-ui
 ├─ one change ───▶ zakk-maintain ─┬─ plan, land, gates, report ─▶ zakk-workflow
 │                                ├─ judge the diff ───────────▶ zakk-review ─▶ zakk-workflow
 │                                └─ dispatch ─────────────────▶ dispatch --engine omp | codex | opencode
 └─ any Chinese ──▶ chinese-skill (cross-cutting, read by every skill)
```
<!-- /skill-map -->

## Choose an engine

| Engine | Read-only semantics | Give it |
|---|---|---|
| omp | `read-only` has no `bash` or write tools. These profile names are omp's own. | Reading, research, and review that run no checks |
| Codex | `read-only` runs commands while the kernel blocks writes; the name does not carry to the siblings. | Audits that must execute tests, linters, or gates |
| OpenCode | `read-only` is plan mode; use `inspect` to run commands. These profile names are opencode's own. | Planning in `read-only`; tests and linters in `inspect` |

Read `references/engines/<engine>.md` before choosing that engine's tier, profile, flags, or
limits. Worker output remains a claim: the orchestrator reads the real diff, runs the checks,
and writes the verdict.

## Install

```bash
git clone <repository-url> dispatch
cd dispatch
./install.sh
```

The default creates links for Claude, Codex, OpenCode, omp, and the shared
`~/.agents/skills/dispatch` location. Use `./install.sh --copy`, `--status`, or `--uninstall` for
the corresponding lifecycle operation; pass target names to limit the operation.

## Check

```bash
sh scripts/check-all.sh
```

This command checks the shared entry contract, all three engine tables, the worker prompt
evidence rules, shell syntax, mixed-engine behavior, and installer lifecycle controls.

## License

MIT
