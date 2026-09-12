#!/usr/bin/env bash
# Dispatch one Codex agent non-interactively and persist every artifact under the run
# directory. Never blocks on stdin; always writes meta.json, even when killed.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: agent.sh --engine codex --run-dir DIR --label NAME (--prompt-file FILE | --prompt TEXT) [options]

Required:
  --run-dir DIR      run directory created by new_run.sh
  --label NAME       agent label; artifacts land in <run-dir>/agents/<label>/
  --prompt-file F    task spec file (preferred)
  --prompt TEXT      inline task spec

Workspace:
  --cwd DIR          workspace root for the agent            (default: $PWD)
  --add-dir DIR      extra writable dir (repeatable)
  --worktree [NAME]  run in a dedicated git worktree of --cwd, branch codex/<name>
  --worktree-base B  branch or commit the worktree starts from  (default: HEAD)
  --allow-stale-base start a worktree from a base that is behind its upstream

Model and limits:
  --tier NAME        difficulty tier: cheap|standard|deep|frontier|max
                     Sets effort and model from CODEX_TIER_<NAME>_EFFORT and
                     CODEX_TIER_<NAME>_MODEL when those are exported.
                     --effort and --model override it.
  --effort LEVEL     low|medium|high|xhigh|max               (default: medium)
  --sandbox MODE     read-only|workspace-write|danger-full-access (default: read-only)
  --model NAME       model override
  --profile NAME     Codex config profile ($CODEX_HOME/<name>.config.toml)
  --timeout SEC      hard wall-clock limit                   (default: 1800)
  --stall SEC        kill when no event arrives for this long (default: off)
  --max-tools N      invalidate a result after more than N completed tools (default: 0, unlimited)

Behavior:
  --schema FILE      JSON Schema; the final message must match it
  --admission MODE   wait|refuse|off - how to handle a full machine (default: wait)
  --resume THREAD    continue an existing thread id
  --network          allow network access and web search
  --approve-for-me   auto-review escalation requests instead of failing them
  --bypass           no sandbox and no approvals at all. Dangerous, never a default, and only
                     for a workspace you would hand a shell to.

Artifacts: prompt.md events.jsonl stderr.log thread.txt meta.json
           result.json (with --schema) or last.txt (without)
EOF
}

RUN_DIR=; LABEL=; PROMPT_FILE=; PROMPT_TEXT=; CWD=$PWD
EFFORT=medium; EFFORT_SET=0; SANDBOX=read-only; SCHEMA=; MODEL=; PROFILE=; TIMEOUT=1800; STALL=0; MAX_TOOLS=0; RESUME=
TIER=
NETWORK=0; APPROVE=0; BYPASS=0; ADD_DIRS=(); WORKTREE=; WORKTREE_BASE=HEAD; ADMISSION=wait; ALLOW_STALE=0
HERE=$(cd "$(dirname "$0")" && pwd)
REG=${CODEX_REGISTRY_DIR:-${XDG_RUNTIME_DIR:-/tmp}/codex-agents}

# Machine-local defaults (tier-to-model bindings, the shared cap) live outside this repository
# so nothing here assumes a provider's lineup. The file is optional.
ENV_FILE=${AGENT_ORCHESTRATION_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestration.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
# Both orchestration toolkits share one machine and one quota, so they share one slot
# directory and one cap. Engine-specific variables still work, but the shared one wins.
SLOTS=${AGENT_SLOTS_DIR:-${XDG_RUNTIME_DIR:-/tmp}/agent-slots}

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --prompt-file) PROMPT_FILE=$2; shift 2 ;;
    --prompt) PROMPT_TEXT=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --add-dir) ADD_DIRS+=("$2"); shift 2 ;;
    --worktree)
      if [ $# -ge 2 ] && case "$2" in --*) false ;; *) true ;; esac; then WORKTREE=$2; shift 2
      else WORKTREE=@label; shift; fi ;;
    --worktree-base) WORKTREE_BASE=$2; shift 2 ;;
    --allow-stale-base) ALLOW_STALE=1; shift ;;
    --tier) TIER=$2; shift 2 ;;
    --effort) EFFORT=$2; EFFORT_SET=1; shift 2 ;;
    --sandbox) SANDBOX=$2; shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --profile) PROFILE=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --stall) STALL=$2; shift 2 ;;
    --max-tools) MAX_TOOLS=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --admission) ADMISSION=$2; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --approve-for-me) APPROVE=1; shift ;;
    --bypass) BYPASS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# A tier is a difficulty statement: the cheapest model and effort that can do the job. Model
# names stay in the environment, so nothing here assumes a particular provider's lineup.
if [ -n "$TIER" ]; then
  case "$TIER" in
    cheap)    TIER_EFFORT=low ;;
    standard) TIER_EFFORT=medium ;;
    deep)     TIER_EFFORT=high ;;
    frontier) TIER_EFFORT=xhigh ;;
    max)      TIER_EFFORT=max ;;
    *) echo "bad --tier: $TIER (cheap|standard|deep|frontier|max)" >&2; exit 2 ;;
  esac
  # The effort ladder is a default, not a law: a machine where a mid model at a high effort
  # beats a top model at a lower one wants a different shape, and that belongs in the
  # machine-local file rather than in every job's flags.
  TIER_EFFORT_VAR="CODEX_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_EFFORT"
  eval "TIER_OVERRIDE=\${$TIER_EFFORT_VAR:-}"
  [ -n "$TIER_OVERRIDE" ] && TIER_EFFORT=$TIER_OVERRIDE
  [ "$EFFORT_SET" = 1 ] || EFFORT=$TIER_EFFORT
  if [ -z "$MODEL" ]; then
    TIER_VAR="CODEX_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_MODEL"
    eval "MODEL=\${$TIER_VAR:-}"
  fi
fi

[ -n "$RUN_DIR" ] && [ -n "$LABEL" ] || { echo "--run-dir and --label are required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] || [ -n "$PROMPT_TEXT" ] || { echo "--prompt-file or --prompt is required" >&2; exit 2; }
case "$EFFORT" in low|medium|high|xhigh|max) ;; *) echo "bad --effort: $EFFORT" >&2; exit 2 ;; esac
case "$SANDBOX" in read-only|workspace-write|danger-full-access) ;; *) echo "bad --sandbox: $SANDBOX" >&2; exit 2 ;; esac
case "$ADMISSION" in wait|refuse|off) ;; *) echo "bad --admission: $ADMISSION (wait|refuse|off)" >&2; exit 2 ;; esac
case "$LABEL" in */*|.|..) echo "invalid label: $LABEL (no path separators)" >&2; exit 2 ;; esac
case "$MAX_TOOLS" in *[!0-9]*|"") echo "bad --max-tools: $MAX_TOOLS" >&2; exit 2 ;; esac

CWD=$(cd "$CWD" && pwd) || exit 2
OUT="$RUN_DIR/agents/$LABEL"
mkdir -p "$OUT" || exit 2

if [ -n "$PROMPT_FILE" ]; then
  # The orchestrator usually writes the spec straight into the agent directory.
  [ "$PROMPT_FILE" -ef "$OUT/prompt.md" ] || cp "$PROMPT_FILE" "$OUT/prompt.md" || exit 2
else
  printf '%s\n' "$PROMPT_TEXT" > "$OUT/prompt.md"
fi

# Structured Outputs rejects a schema the CLI happily forwards, and the rejection costs a
# whole dispatch, so check the documented subset here.
if [ -n "$SCHEMA" ]; then
  python3 - "$SCHEMA" <<'PY' || exit 2
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"schema is not valid JSON: {e}")
bad = {"allOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas",
       "patternProperties", "oneOf"}
problems, depth_seen = [], 0
def walk(node, path="$", depth=0):
    global depth_seen
    depth_seen = max(depth_seen, depth)
    if not isinstance(node, dict):
        return
    for k in node.keys() & bad:
        problems.append(f"{path}: unsupported keyword {k!r}")
    if node.get("type") == "object":
        props = node.get("properties", {})
        if node.get("additionalProperties") is not False:
            problems.append(f'{path}: needs "additionalProperties": false')
        missing = set(props) - set(node.get("required", []))
        if missing:
            problems.append(f"{path}: every property must be required, missing {sorted(missing)}")
        for name, sub in props.items():
            walk(sub, f"{path}.{name}", depth + 1)
    if "items" in node:
        walk(node["items"], f"{path}[]", depth + 1)
    for sub in node.get("anyOf", []):
        walk(sub, f"{path}|", depth + 1)
    for name, sub in node.get("$defs", {}).items():
        walk(sub, f"$defs.{name}", depth)
if s.get("type") != "object":
    problems.append("$: root must be an object")
walk(s)
if depth_seen > 10:
    problems.append(f"$: nesting depth {depth_seen} exceeds the documented limit of 10")
# The remaining documented limits, checked here so the rejection is free rather than paid for.
text = json.dumps(s)
if len(text) > 120_000:
    problems.append(f"$: schema is {len(text)} characters, over the 120000 limit")
def count(node):
    if not isinstance(node, dict):
        return 0, 0
    props = len(node.get("properties", {}) or {})
    enums = len(node.get("enum", []) or [])
    for sub in list((node.get("properties") or {}).values()) + \
               list((node.get("$defs") or {}).values()) + \
               (node.get("anyOf") or []) + ([node["items"]] if "items" in node else []):
        p, e = count(sub)
        props += p
        enums = max(enums, e)
    return props, enums
n_props, n_enum = count(s)
if n_props > 5000:
    problems.append(f"$: {n_props} properties, over the 5000 limit")
if n_enum > 1000:
    problems.append(f"$: an enum has {n_enum} values, over the 1000 limit")
if problems:
    sys.exit("schema rejected before dispatch:\n  " + "\n  ".join(problems))
PY
fi

# A git worktree gives a write-capable agent its own checkout, so parallel agents cannot
# overwrite each other's files. Conflicts move to merge time, where they are visible.
# Every agent records the exact commit it started from. Without it, a review cannot tell
# whether a diff was written against the tree that is being merged into.
BASE_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null)
BASE_REF=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)

WORKTREE_PATH=; WORKTREE_BRANCH=; WORKTREE_BASE_SHA=
if [ -n "$WORKTREE" ]; then
  [ "$WORKTREE" = "@label" ] && WORKTREE=$LABEL
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || { echo "--worktree needs $CWD to be a git repository" >&2; exit 2; }
  WORKTREE_BRANCH="codex/$WORKTREE"
  WORKTREE_PATH="$RUN_DIR/worktrees/$WORKTREE"
  WORKTREE_BASE_SHA=$(git -C "$CWD" rev-parse --verify "$WORKTREE_BASE" 2>/dev/null)
  [ -n "$WORKTREE_BASE_SHA" ] || { echo "unknown --worktree-base: $WORKTREE_BASE" >&2; exit 2; }
  # Agents must not build on a base that is already behind: the work would be reviewed and
  # merged against a tree nobody is running.
  UPSTREAM=$(git -C "$CWD" rev-parse --abbrev-ref --symbolic-full-name "$WORKTREE_BASE@{upstream}" 2>/dev/null || true)
  if [ -n "$UPSTREAM" ]; then
    BEHIND=$(git -C "$CWD" rev-list --count "$WORKTREE_BASE..$UPSTREAM" 2>/dev/null || echo 0)
    if [ "${BEHIND:-0}" -gt 0 ] && [ "$ALLOW_STALE" = 0 ]; then
      echo "base $WORKTREE_BASE is $BEHIND commit(s) behind $UPSTREAM;" >&2
      echo "update it first, or pass --allow-stale-base if that is intended" >&2
      exit 2
    fi
  fi
  BASE_SHA=$WORKTREE_BASE_SHA
  BASE_REF=$WORKTREE_BASE
  if [ ! -d "$WORKTREE_PATH" ]; then
    mkdir -p "$RUN_DIR/worktrees"
    if git -C "$CWD" show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
      git -C "$CWD" worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH" >&2 || exit 2
    else
      git -C "$CWD" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$WORKTREE_BASE" >&2 || exit 2
    fi
  fi
  CWD=$(cd "$WORKTREE_PATH" && pwd)
fi

if [ -n "$SCHEMA" ]; then RESULT="$OUT/result.json"; else RESULT="$OUT/last.txt"; fi
rm -f "$RESULT" "$OUT/thread.txt"

# Every option is a root option placed before the `resume` subcommand: resume does not inherit
# sandbox, cwd, model, or workspace roots from the original run, and its own parser rejects
# -C and -s outright.
ARGS=(exec --json --skip-git-repo-check -C "$CWD" -o "$RESULT")
[ "$BYPASS" = 1 ] || ARGS+=(-s "$SANDBOX")
ARGS+=(-c "model_reasoning_effort=$EFFORT")
for d in ${ADD_DIRS+"${ADD_DIRS[@]}"}; do ARGS+=(--add-dir "$d"); done
if [ "$NETWORK" = 1 ]; then
  # This grants shell network access, and only under workspace-write: the read-only sandbox has
  # no network permission at all. Codex's built-in web search is a separate, server-side tool
  # that is enabled by default and works in every sandbox, so research agents do not need this.
  if [ "$SANDBOX" = read-only ]; then
    echo "note: --network does not grant shell network access under read-only;" >&2
    echo "      built-in web search still works, use workspace-write for curl or installers" >&2
  fi
  ARGS+=(-c "sandbox_workspace_write.network_access=true")
fi
if [ "$BYPASS" = 1 ]; then
  echo "WARNING: $LABEL runs with no sandbox and no approvals" >&2
  ARGS+=(--dangerously-bypass-approvals-and-sandbox)
  SANDBOX=bypass
elif [ "$APPROVE" = 1 ]; then
  ARGS+=(--approve-for-me)
fi
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
[ -n "$PROFILE" ] && ARGS+=(-p "$PROFILE")
[ -n "$SCHEMA" ] && ARGS+=(--output-schema "$SCHEMA")
[ -n "$RESUME" ] && ARGS+=(resume "$RESUME")
ARGS+=(-)   # prompt arrives on stdin, so no shell quoting can corrupt it

# Slots are flock'd files in a shared directory, so the cap holds across terminals and
# orchestrator sessions that know nothing about each other. The lock is held for the run.
if [ "$ADMISSION" != off ]; then
  mkdir -p "$SLOTS" 2>/dev/null
  MAXA=${AGENT_MAX_AGENTS:-5}
  SLOT_FD=
  WAITED=0
  while [ -z "$SLOT_FD" ]; do
    for i in $(seq 1 "$MAXA"); do
      exec {fd}>"$SLOTS/slot-$i" || continue
      if flock -n "$fd"; then SLOT_FD=$fd; break; fi
      exec {fd}>&-
    done
    [ -n "$SLOT_FD" ] && break
    if [ "$ADMISSION" = refuse ]; then
      echo "no free agent slot: $MAXA already running machine-wide (AGENT_MAX_AGENTS)" >&2
      "$HERE/../../agents.sh" --list >&2
      exit 3
    fi
    [ "$WAITED" = 0 ] && echo "waiting for an agent slot ($MAXA in use machine-wide)" >&2
    sleep 10; WAITED=$((WAITED + 10))
  done
fi

START=$(date +%s)

# Codex keeps session state in SQLite, and several processes reaching it in the same instant
# lose to "database is locked". Starts are serialized machine-wide with a short hold so a
# fan-out ramps in rather than stampeding; the lock covers the launch only.
STAGGER=${AGENT_START_STAGGER:-2}
stagger_start() {
  [ "$STAGGER" -gt 0 ] 2>/dev/null || return 0
  mkdir -p "$SLOTS" 2>/dev/null
  exec {sfd}>"$SLOTS/.start.lock" || return 0
  flock "$sfd" 2>/dev/null || return 0
  sleep "$STAGGER"
  exec {sfd}>&-
}

# A lock error happens before the model does anything, so retrying repeats nothing. A run that
# produced real events is never retried, because that would duplicate work.
locked_without_progress() {
  grep -qiE "database is locked|SQLITE_BUSY|database table is locked" "$OUT/stderr.log" \
       "$OUT/events.jsonl" 2>/dev/null || return 1
  ! grep -qE '"type":"(item\.|turn\.completed)' "$OUT/events.jsonl" 2>/dev/null
}

ATTEMPT=0
MAX_ATTEMPTS=${AGENT_LOCK_RETRIES:-4}
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  stagger_start
  # stdin is the prompt file and nothing else: an inherited terminal stdin makes codex wait
  # forever. SIGINT first, because Codex turns it into a graceful turn interrupt.
  ( cd "$CWD" && timeout --signal=INT --kill-after=30 "$TIMEOUT" \
      codex "${ARGS[@]}" < "$OUT/prompt.md" > "$OUT/events.jsonl" 2> "$OUT/stderr.log" ) &
  CODEX_PID=$!
  sleep 2
  if kill -0 "$CODEX_PID" 2>/dev/null; then break; fi
  # Already finished: reap it once and remember the status, or the final wait would report 127.
  wait "$CODEX_PID"; EARLY=$?
  EARLY_DONE=1; EARLY_CODE=$EARLY
  if [ "$EARLY" = 0 ] || [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ] || ! locked_without_progress; then
    break
  fi
  EARLY_DONE=0
  BACKOFF=$((ATTEMPT * ATTEMPT * 2))
  echo "database locked on attempt $ATTEMPT/$MAX_ATTEMPTS, retrying in ${BACKOFF}s" >&2
  cp "$OUT/stderr.log" "$OUT/stderr.attempt-$ATTEMPT.log" 2>/dev/null
  sleep "$BACKOFF"
done

STALLED=0
if [ "$STALL" -gt 0 ] 2>/dev/null; then
  ( while kill -0 "$CODEX_PID" 2>/dev/null; do
      sleep 30
      LAST=$(stat -c %Y "$OUT/events.jsonl" 2>/dev/null || echo 0)
      NOW=$(date +%s)
      if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -ge "$STALL" ]; then
        echo "stall: no event for $((NOW - LAST))s, interrupting" >> "$OUT/stderr.log"
        touch "$OUT/.stalled"
        kill -INT "$CODEX_PID" 2>/dev/null
        sleep 20; kill -KILL "$CODEX_PID" 2>/dev/null
        exit 0
      fi
    done ) &
  WATCHER=$!
fi

# The tool budget is its own watcher rather than a branch of the stall loop: the stall loop
# only exists when --stall is set, and a bounded inquiry sets no stall. Rescanning the whole
# event file every two seconds is affordable only because a budgeted run is short by
# definition; the hard edge is the recount after exit below, which invalidates the result
# even when the kill here came too late.
if [ "$MAX_TOOLS" -gt 0 ] 2>/dev/null && kill -0 "$CODEX_PID" 2>/dev/null; then
  ( while kill -0 "$CODEX_PID" 2>/dev/null; do
      sleep 2
      COUNT=$(PYTHONPATH="$HERE" python3 -c \
        'from events import scan_tools; import sys; print(len(scan_tools(sys.argv[1], 0)[0]))' \
        "$OUT/events.jsonl")
      if [ "$COUNT" -gt "$MAX_TOOLS" ]; then
        echo "tool budget: $COUNT completions exceeds $MAX_TOOLS, interrupting" >> "$OUT/stderr.log"
        touch "$OUT/.over-budget"
        kill -INT "$CODEX_PID" 2>/dev/null
        sleep 2
        kill -KILL "$CODEX_PID" 2>/dev/null
        exit 0
      fi
    done ) &
  BUDGET_WATCHER=$!
fi

# The deadline is only knowable while the agent runs: meta.json arrives after it is already
# dead. Writing it now lets a supervisor warn before the guard fires instead of after.
STARTED_JSON="$OUT/started.json"
LABEL="$LABEL" CWD="$CWD" TIMEOUT="$TIMEOUT" STALL="$STALL" START="$START" PID="$CODEX_PID" \
  python3 -c 'import json, os, sys
json.dump({"label": os.environ["LABEL"], "engine": "codex", "cwd": os.environ["CWD"],
           "pid": int(os.environ["PID"]), "started_at": int(os.environ["START"]),
           "timeout_s": int(os.environ["TIMEOUT"]), "stall_s": int(os.environ["STALL"]),
           "deadline": int(os.environ["START"]) + int(os.environ["TIMEOUT"])},
          open(sys.argv[1], "w"))' "$STARTED_JSON" 2>/dev/null

# Register the live agent so another window can see what this one is running.
REG_META=$(mktemp)
# Built by a JSON serializer: a label or path containing a quote or backslash would otherwise
# produce invalid JSON and the agent would silently vanish from the machine-wide view.
LABEL="$LABEL" CWD="$CWD" RUN_DIR="$RUN_DIR" TIER="$TIER" EFFORT="$EFFORT" SANDBOX="$SANDBOX" \
  python3 -c 'import json, os, sys
json.dump({k.lower(): os.environ[k] or None
           for k in ("LABEL", "CWD", "RUN_DIR", "TIER", "EFFORT", "SANDBOX")},
          open(sys.argv[1], "w"))' "$REG_META" \
  || echo "warning: could not build registry metadata for $LABEL" >&2
OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --register "$CODEX_PID" "$REG_META" 2>/dev/null
rm -f "$REG_META"
# A signal to the wrapper must reach the worker: otherwise the run is reported finished while
# codex keeps writing to the workspace and keeps holding the admission slot.
cleanup() {
  kill -INT "$CODEX_PID" 2>/dev/null
  [ -n "${WATCHER:-}" ] && kill "$WATCHER" 2>/dev/null
  [ -n "${BUDGET_WATCHER:-}" ] && kill "$BUDGET_WATCHER" 2>/dev/null
  OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --unregister "$CODEX_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ "${EARLY_DONE:-0}" = 1 ]; then CODE=$EARLY_CODE; else wait "$CODEX_PID"; CODE=$?; fi
OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --unregister "$CODEX_PID" 2>/dev/null
[ -n "${WATCHER:-}" ] && kill "$WATCHER" 2>/dev/null
[ -n "${BUDGET_WATCHER:-}" ] && kill "$BUDGET_WATCHER" 2>/dev/null
OVER_BUDGET=0
TOOL_COMPLETIONS=$(PYTHONPATH="$HERE" python3 -c \
  'from events import scan_tools; import sys; print(len(scan_tools(sys.argv[1], 0)[0]))' \
  "$OUT/events.jsonl")
if [ "$MAX_TOOLS" -gt 0 ] && [ "$TOOL_COMPLETIONS" -gt "$MAX_TOOLS" ]; then
  OVER_BUDGET=1
  touch "$OUT/.over-budget"
  CODE=66
fi
[ -f "$OUT/.stalled" ] && { STALLED=1; rm -f "$OUT/.stalled"; }
END=$(date +%s)

python3 - "$OUT" "$LABEL" "$CWD" "$EFFORT" "$SANDBOX" "$CODE" "$((END - START))" \
         "$RESUME" "$STALLED" "$WORKTREE_BRANCH" "$BASE_SHA" "$MODEL" "$BASE_REF" \
         "${PROFILE:-}" "$HERE" "$OVER_BUDGET" <<'PY'
import json, sys, pathlib
(out, label, cwd, effort, sandbox, code, dur, resume, stalled, branch, base_sha,
 model, base_ref, profile, scripts, over_budget) = sys.argv[1:17]
sys.path.insert(0, scripts)
from events import scan_tools
out = pathlib.Path(out)
thread, usage, errors, files, reconnects = None, {}, [], set(), 0
tool_events, _ = scan_tools(out / "events.jsonl", 0)
tool_calls = sum(event["ok"] for event in tool_events)
failed_cmds = len(tool_events) - tool_calls
for line in (out / "events.jsonl").read_text(errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("thread_id"):
        thread = ev["thread_id"]
    if ev.get("type") == "turn.completed":
        usage = ev.get("usage", {})
    # A failed command item is normal exploration, and a top-level `error` may be a retry
    # notice ("Reconnecting... 1/5"), not a terminal failure. Both are counted, not obeyed.
    if ev.get("type") == "error" and str(ev.get("message", "")).startswith("Reconnecting"):
        reconnects += 1
    elif ev.get("type") in ("turn.failed", "error"):
        errors.append(ev)
    item = ev.get("item") or {}
    if item.get("type") == "file_change":
        for ch in item.get("changes", []) or []:
            if isinstance(ch, dict) and ch.get("path"):
                files.add(ch["path"])
if thread:
    (out / "thread.txt").write_text(thread + "\n")
result = out / "result.json" if (out / "result.json").exists() else out / "last.txt"
code = int(code)
meta = {
    "label": label, "engine": "codex", "cwd": cwd, "effort": effort, "sandbox": sandbox, "model": model or None, "profile": profile or None,
    "resumed_from": resume or None, "exit_code": code, "duration_s": int(dur),
    "thread_id": thread, "usage": usage,
    "result_file": str(result) if result.exists() else None,
    "result_bytes": result.stat().st_size if result.exists() else 0,
    "tool_calls": tool_calls,
    "failed_commands": failed_cmds,
    "files_touched": sorted(files),
    "errors": errors[:5],
    "error_count": len(errors),
    "timed_out": code in (124, 137) and stalled != "1",
    "stalled": stalled == "1",
    "over_budget": over_budget == "1",
    "reconnects": reconnects,
    # A run that died with no completed turn after reconnect attempts failed on transport,
    # not on the task: resume it as-is instead of rewriting the spec.
    "transient_failure": bool(code != 0 and reconnects and not usage),
    "worktree_branch": branch or None,
    "base_sha": base_sha or None,
    "base_ref": base_ref or None,
}
(out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({k: meta[k] for k in
      ("label", "exit_code", "duration_s", "thread_id", "result_file",
       "timed_out", "stalled", "transient_failure", "worktree_branch")}, ensure_ascii=False))
PY

exit $CODE
