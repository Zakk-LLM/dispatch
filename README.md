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
 ├─ define structure (package structure, data, deployment shape, frontend directories)
 │    └─▶ zakk-architecture ──interface values──▶ web-ui
 │              └─ Must produce three documents: design language (web-ui) / architecture
 │                 (this skill) / workflow (zakk-workflow)
 ├─ one change (fix, feature, documentation, skill change)
 │    └─▶ zakk-maintain
 │          ├─ 1. Write the plan as a file ──approve──▶ another mind
 │          ├─ 2. Write a specification from the approved plan ──dispatch──▶ dispatch --engine omp | codex | opencode
 │          ├─ 3. Judge the diff ──▶ zakk-review; reviewer performs ablation, gates, and differential checks;
 │          │   then dispatch an uninformed cold reader
 │          └─ 4. Land and report ──▶ zakk-workflow (branch, commit, pull request, completion report)
 └─ any Chinese ──▶ chinese-skill (cross-cutting: every skill reads it; reread after compaction,
    restoration, or task switching)
```
<!-- /skill-map -->

## Flow

<!-- skill-flow -->
```text
Entry: work is large enough to split among parallel workers, or the user asks to delegate
 │
 ├─ Choose engine:
 │     omp      read-only withholds bash and writes → review and research needing no commands
 │     codex    read-only runs commands; the kernel blocks writes → audits that must run tests or gates
 │     opencode read-only is planning mode; inspect runs commands → plan in read-only, test/lint in inspect
 ├─ Preflight: agent.sh --engine <e> --help / agents.sh --list / capacity.sh --engine <e>
 ├─ When not to use it: do small tasks yourself; reserve gpt-6 for plan review, major cold reads,
 │  and cross-crate implementation
 │
 ├─ 1. Create the run directory
 ├─ 2. Split by file ownership; declare order (PLAN.md; one worktree per writer; skip dependent work on failure)
 ├─ 3. Write task specifications (scope fence, executable acceptance, live-notes, prohibitions;
 │  paste regression scope from impact.sh)
 ├─ 4. Pick engine, tier, profile, and limits
 ├─ 5. Dispatch
 ├─ 6. Supervise without idling (wait for notifications; cap at 90 minutes)
 ├─ 7. Review — never delegate: agent report is a claim; only commands you ran are evidence;
 │  read diff, enforce scope, run every acceptance criterion, and use negative controls
 ├─ 8. Fix rounds and continuation (resume the same engine; restart if context is small or premise wrong)
 └─ 9. Integrate, then ship: merge.sh atomically; rollback on conflict, failed rebase, or failed check;
       run the full suite here; you perform irreversible steps and ask before external actions
Exit: merged result ──▶ zakk-workflow for landing and report
```
<!-- /skill-flow -->

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
