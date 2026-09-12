#!/usr/bin/env bash
# Dispatch one omp agent non-interactively and persist every artifact under the run directory.
# Never blocks on stdin; always writes meta.json, even when killed.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: agent.sh --engine omp --run-dir DIR --label NAME (--prompt-file FILE | --prompt TEXT) [options]

Required:
  --run-dir DIR      run directory created by new_run.sh
  --label NAME       agent label; artifacts land in <run-dir>/agents/<label>/
  --prompt-file F    task spec file (preferred)
  --prompt TEXT      inline task spec

Workspace:
  --cwd DIR          workspace root for the agent            (default: $PWD)
  --add-dir DIR      extra workspace directory (repeatable)
  --worktree [NAME]  run in a dedicated git worktree of --cwd, branch omp/<name>
  --worktree-base B  branch or commit the worktree starts from  (default: HEAD)
  --allow-stale-base start a worktree from a base that is behind its upstream

Model and limits:
  --tier NAME        difficulty tier: cheap|standard|deep|frontier|max
                     Sets thinking and model from OMP_TIER_<NAME>_THINKING and
                     OMP_TIER_<NAME>_MODEL when those are set.
  --thinking LEVEL   off|minimal|low|medium|high|xhigh|max|auto
  --model NAME       provider/model, or a role reference the omp config defines
  --role NAME        omp agent definition to use as the system prompt (~/.omp/agent/agents)
  --timeout SEC      hard wall-clock limit                   (default: 1800)
  --stall SEC        kill when no event arrives for this long (default: off)
  --max-tools N    invalidate a result after more than N completed tools (default: 0, unlimited)

Permissions (omp has no sandbox; the tool allowlist is the boundary):
  --permission MODE  read-only|workspace-write|full|bypass   (default: read-only)
  --network          allow web_search and web fetching
  --allow-git        do not deny history-changing git commands (dangerous, off by default)

Behavior:
  --schema FILE      JSON Schema the final message must satisfy; validated after the run
  --resume SESSION   continue an existing session id
  --admission MODE   wait|refuse|off - how to handle a full machine (default: wait)

Artifacts: prompt.md events.jsonl stderr.log thread.txt started.json meta.json
           result.json (with --schema) or last.txt (without); sessions live in <run>/sessions/
EOF
}

RUN_DIR=; LABEL=; PROMPT_FILE=; PROMPT_TEXT=; CWD=$PWD
THINKING=; THINKING_SET=0; MODEL=; ROLE=; TIMEOUT=1800; STALL=0; MAX_TOOLS=0; RESUME=
SCHEMA=; TIER=; PERMISSION=read-only; NETWORK=0; ALLOW_GIT=0; ADMISSION=wait
WORKTREE=; WORKTREE_BASE=HEAD; ALLOW_STALE=0; ADD_DIRS=()
HERE=$(cd "$(dirname "$0")" && pwd)
REG=${OMP_REGISTRY_DIR:-${XDG_RUNTIME_DIR:-/tmp}/omp-agents}

# Machine-local defaults (tier-to-model bindings, the shared cap) live outside this repository
# so nothing here assumes a provider's lineup. The file is optional.
ENV_FILE=${AGENT_ORCHESTRATION_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestration.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
# All three toolkits share one machine and one quota, so they share one slot directory and cap.
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
    --thinking) THINKING=$2; THINKING_SET=1; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --role) ROLE=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --stall) STALL=$2; shift 2 ;;
    --max-tools) MAX_TOOLS=$2; shift 2 ;;
    --permission) PERMISSION=$2; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --allow-git) ALLOW_GIT=1; shift ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --admission) ADMISSION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$TIER" ]; then
  case "$TIER" in
    cheap)    TIER_THINKING=low ;;
    standard) TIER_THINKING=medium ;;
    deep)     TIER_THINKING=high ;;
    frontier) TIER_THINKING=xhigh ;;
    max)      TIER_THINKING=max ;;
    *) echo "bad --tier: $TIER (cheap|standard|deep|frontier|max)" >&2; exit 2 ;;
  esac
  # The thinking ladder is a default, not a law: a machine where a mid model at a high thinking
  # beats a top model at a lower one wants a different shape, and that belongs in the
  # machine-local file rather than in every job's flags.
  TIER_THINKING_VAR="OMP_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_THINKING"
  eval "TIER_OVERRIDE=\${$TIER_THINKING_VAR:-}"
  [ -n "$TIER_OVERRIDE" ] && TIER_THINKING=$TIER_OVERRIDE
  [ "$THINKING_SET" = 1 ] || THINKING=$TIER_THINKING
  if [ -z "$MODEL" ]; then
    TIER_VAR="OMP_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_MODEL"
    eval "MODEL=\${$TIER_VAR:-}"
  fi
fi

[ -n "$RUN_DIR" ] && [ -n "$LABEL" ] || { echo "--run-dir and --label are required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] || [ -n "$PROMPT_TEXT" ] || { echo "--prompt-file or --prompt is required" >&2; exit 2; }
case "$PERMISSION" in read-only|workspace-write|full|bypass) ;;
  *) echo "bad --permission: $PERMISSION" >&2; exit 2 ;; esac
case "$ADMISSION" in wait|refuse|off) ;; *) echo "bad --admission: $ADMISSION (wait|refuse|off)" >&2; exit 2 ;; esac
case "$LABEL" in */*|.|..) echo "invalid label: $LABEL (no path separators)" >&2; exit 2 ;; esac
case "$MAX_TOOLS" in *[!0-9]*|"") echo "bad --max-tools: $MAX_TOOLS" >&2; exit 2 ;; esac
[ "$PERMISSION" = bypass ] && echo "WARNING: $LABEL runs with every tool and no approvals" >&2

CWD=$(cd "$CWD" && pwd) || exit 2
OUT="$RUN_DIR/agents/$LABEL"
mkdir -p "$OUT" || exit 2

if [ -n "$PROMPT_FILE" ]; then
  [ "$PROMPT_FILE" -ef "$OUT/prompt.md" ] || cp "$PROMPT_FILE" "$OUT/prompt.md" || exit 2
else
  printf '%s\n' "$PROMPT_TEXT" > "$OUT/prompt.md"
fi

# omp has no sandbox: the tool allowlist is the boundary. Withholding the write tools is a
# stronger guarantee than a permission rule, because the model cannot call what it lacks.
case "$PERMISSION" in
  read-only)       TOOLSET="read,grep,glob,lsp,yield" ;;
  workspace-write) TOOLSET="read,grep,glob,lsp,yield,write,edit,bash,ast_edit" ;;
  full|bypass)     TOOLSET= ;;
esac
# omp's `read` tool takes a URL as well as a path, so a restricted worker reaches the web
# through it. There is no `web_search` in the --tools vocabulary; search arrives through MCP,
# which means a search-dependent worker needs the unrestricted profile.
if [ "$NETWORK" = 1 ] && [ -n "$TOOLSET" ]; then
  echo "note: --network on a restricted profile means URL reads through the read tool;" >&2
  echo "      search tools come from MCP and need --permission full" >&2
fi

WORKTREE_PATH=; WORKTREE_BRANCH=; BASE_SHA=; BASE_REF=
BASE_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null)
BASE_REF=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$WORKTREE" ]; then
  [ "$WORKTREE" = "@label" ] && WORKTREE=$LABEL
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || { echo "--worktree needs $CWD to be a git repository" >&2; exit 2; }
  WORKTREE_BRANCH="omp/$WORKTREE"
  WORKTREE_PATH="$RUN_DIR/worktrees/$WORKTREE"
  WT_BASE_SHA=$(git -C "$CWD" rev-parse --verify "$WORKTREE_BASE" 2>/dev/null)
  [ -n "$WT_BASE_SHA" ] || { echo "unknown --worktree-base: $WORKTREE_BASE" >&2; exit 2; }
  UPSTREAM=$(git -C "$CWD" rev-parse --abbrev-ref --symbolic-full-name "$WORKTREE_BASE@{upstream}" 2>/dev/null || true)
  if [ -n "$UPSTREAM" ]; then
    BEHIND=$(git -C "$CWD" rev-list --count "$WORKTREE_BASE..$UPSTREAM" 2>/dev/null || echo 0)
    if [ "${BEHIND:-0}" -gt 0 ] && [ "$ALLOW_STALE" = 0 ]; then
      echo "base $WORKTREE_BASE is $BEHIND commit(s) behind $UPSTREAM;" >&2
      echo "update it first, or pass --allow-stale-base if that is intended" >&2
      exit 2
    fi
  fi
  if [ ! -d "$WORKTREE_PATH" ]; then
    mkdir -p "$RUN_DIR/worktrees"
    if git -C "$CWD" show-ref --verify --quiet "refs/heads/$WORKTREE_BRANCH"; then
      git -C "$CWD" worktree add "$WORKTREE_PATH" "$WORKTREE_BRANCH" >&2 || exit 2
    else
      git -C "$CWD" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_PATH" "$WORKTREE_BASE" >&2 || exit 2
    fi
  fi
  CWD=$(cd "$WORKTREE_PATH" && pwd)
  BASE_SHA=$WT_BASE_SHA
  BASE_REF=$WORKTREE_BASE
fi

if [ -n "$SCHEMA" ]; then RESULT="$OUT/result.json"; else RESULT="$OUT/last.txt"; fi
rm -f "$RESULT" "$OUT/thread.txt"

# omp cannot enforce a schema on a print-mode answer, so the contract goes into the prompt and
# the wrapper validates afterwards. Without the check a schema would be a suggestion.
PROMPT_INPUT="$OUT/prompt.md"
if [ -n "$SCHEMA" ]; then
  PROMPT_INPUT="$OUT/.prompt-with-schema.md"
  { cat "$OUT/prompt.md"
    printf '\n\n## Output contract\nYour final message must be exactly one JSON object, no prose,\nno code fence, matching this schema:\n\n```json\n'
    cat "$SCHEMA"
    printf '\n```\n'
  } > "$PROMPT_INPUT"
fi

SESSION_DIR="$RUN_DIR/sessions"
mkdir -p "$SESSION_DIR"

ARGS=(-p --mode=json --cwd "$CWD" --session-dir "$SESSION_DIR")
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
[ -n "$THINKING" ] && ARGS+=(--thinking "$THINKING")
[ -n "$TOOLSET" ] && ARGS+=(--tools "$TOOLSET")
for d in ${ADD_DIRS+"${ADD_DIRS[@]}"}; do ARGS+=(--add-dir "$d"); done
# A role file is an agent definition; its body is the system prompt for this worker.
if [ -n "$ROLE" ]; then
  ROLE_FILE="${OMP_AGENT_DIR:-$HOME/.omp/agent/agents}/$ROLE.md"
  [ -f "$ROLE_FILE" ] || { echo "no such role: $ROLE_FILE" >&2; exit 2; }
  ARGS+=(--append-system-prompt "$ROLE_FILE")
fi
# omp's own limit stops the session cleanly; the outer timeout is the backstop for a hang.
ARGS+=(--max-time "$TIMEOUT")
# An approval prompt has nobody to answer it in print mode, so every profile runs without one.
# The boundary is the tool allowlist above: a worker cannot call a tool it was not given.
ARGS+=(--approval-mode yolo)
[ "$PERMISSION" = bypass ] && ARGS+=(--auto-approve)
[ -n "$RESUME" ] && ARGS+=(-r "$RESUME")

if [ "$ADMISSION" != off ]; then
  # omp runs on a subscription with no per-minute quota to protect, so its budget is the
  # machine and the reviewer, not an API limit. It therefore locks its own slot namespace and
  # honours its own cap: sharing the metered engines' slots would let it starve them.
  SLOTS="$SLOTS/omp"
  mkdir -p "$SLOTS" 2>/dev/null
  MAXA=${OMP_MAX_AGENTS:-5}
  SLOT_FD=; WAITED=0
  while [ -z "$SLOT_FD" ]; do
    for i in $(seq 1 "$MAXA"); do
      exec {fd}>"$SLOTS/slot-$i" || continue
      if flock -n "$fd"; then SLOT_FD=$fd; break; fi
      exec {fd}>&-
    done
    [ -n "$SLOT_FD" ] && break
    if [ "$ADMISSION" = refuse ]; then
      echo "no free agent slot: $MAXA already running machine-wide (OMP_MAX_AGENTS)" >&2
      "$HERE/../../agents.sh" --list >&2
      exit 3
    fi
    [ "$WAITED" = 0 ] && echo "waiting for an agent slot ($MAXA in use machine-wide)" >&2
    sleep 10; WAITED=$((WAITED + 10))
  done
fi

START=$(date +%s)

# Session state is a shared store here too, so launches are serialized machine-wide.
STAGGER=${AGENT_START_STAGGER:-2}
stagger_start() {
  [ "$STAGGER" -gt 0 ] 2>/dev/null || return 0
  mkdir -p "$SLOTS" 2>/dev/null
  exec {sfd}>"$SLOTS/.start.lock" || return 0
  flock "$sfd" 2>/dev/null || return 0
  sleep "$STAGGER"
  exec {sfd}>&-
}

locked_without_progress() {
  grep -qiE "database is locked|SQLITE_BUSY|database table is locked" "$OUT/stderr.log" \
       "$OUT/events.jsonl" 2>/dev/null || return 1
  ! grep -qE '"type":"(message_end|tool|turn_end)"' "$OUT/events.jsonl" 2>/dev/null
}

ATTEMPT=0
MAX_ATTEMPTS=${AGENT_LOCK_RETRIES:-4}
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  stagger_start
  # stdin must be closed: an inherited terminal stdin would keep the process waiting.
  ( cd "$CWD" && timeout --signal=INT --kill-after=30 $((TIMEOUT + 60)) \
      omp "${ARGS[@]}" "$(cat "$PROMPT_INPUT")" \
      < /dev/null > "$OUT/events.jsonl" 2> "$OUT/stderr.log" ) &
  AGENT_PID=$!
  sleep 2
  if kill -0 "$AGENT_PID" 2>/dev/null; then break; fi
  wait "$AGENT_PID"; EARLY=$?
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
  ( while kill -0 "$AGENT_PID" 2>/dev/null; do
      sleep 30
      LAST=$(stat -c %Y "$OUT/events.jsonl" 2>/dev/null || echo 0)
      NOW=$(date +%s)
      if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -ge "$STALL" ]; then
        echo "stall: no event for $((NOW - LAST))s, interrupting" >> "$OUT/stderr.log"
        touch "$OUT/.stalled"
        kill -INT "$AGENT_PID" 2>/dev/null
        sleep 20; kill -KILL "$AGENT_PID" 2>/dev/null
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
if [ "$MAX_TOOLS" -gt 0 ] 2>/dev/null && kill -0 "$AGENT_PID" 2>/dev/null; then
  ( while kill -0 "$AGENT_PID" 2>/dev/null; do
      sleep 2
      COUNT=$(PYTHONPATH="$HERE" python3 -c \
        'from events import scan_tools; import sys; print(len(scan_tools(sys.argv[1], 0)[0]))' \
        "$OUT/events.jsonl")
      if [ "$COUNT" -gt "$MAX_TOOLS" ]; then
        echo "tool budget: $COUNT completions exceeds $MAX_TOOLS, interrupting" >> "$OUT/stderr.log"
        touch "$OUT/.over-budget"
        kill -INT "$AGENT_PID" 2>/dev/null
        sleep 2
        kill -KILL "$AGENT_PID" 2>/dev/null
        exit 0
      fi
    done ) &
  BUDGET_WATCHER=$!
fi

STARTED_JSON="$OUT/started.json"
LABEL="$LABEL" CWD="$CWD" TIMEOUT="$TIMEOUT" STALL="$STALL" START="$START" PID="$AGENT_PID" \
  python3 -c 'import json, os, sys
json.dump({"label": os.environ["LABEL"], "engine": "omp", "cwd": os.environ["CWD"],
           "pid": int(os.environ["PID"]), "started_at": int(os.environ["START"]),
           "timeout_s": int(os.environ["TIMEOUT"]), "stall_s": int(os.environ["STALL"]),
           "deadline": int(os.environ["START"]) + int(os.environ["TIMEOUT"])},
          open(sys.argv[1], "w"))' "$STARTED_JSON" 2>/dev/null

REG_META=$(mktemp)
LABEL="$LABEL" CWD="$CWD" RUN_DIR="$RUN_DIR" TIER="$TIER" THINKING="$THINKING" PERMISSION="$PERMISSION" \
  python3 -c 'import json, os, sys
json.dump({"label": os.environ["LABEL"], "cwd": os.environ["CWD"],
           "run_dir": os.environ["RUN_DIR"], "tier": os.environ["TIER"] or None,
           "effort": os.environ["THINKING"] or "default", "sandbox": os.environ["PERMISSION"]},
          open(sys.argv[1], "w"))' "$REG_META" 2>/dev/null \
  || echo "warning: could not build registry metadata for $LABEL" >&2
"$HERE/../../agents.sh" --register "$AGENT_PID" "$REG_META" 2>/dev/null
rm -f "$REG_META"

cleanup() {
  kill -INT "$AGENT_PID" 2>/dev/null
  [ -n "${WATCHER:-}" ] && kill "$WATCHER" 2>/dev/null
  [ -n "${BUDGET_WATCHER:-}" ] && kill "$BUDGET_WATCHER" 2>/dev/null
  "$HERE/../../agents.sh" --unregister "$AGENT_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ "${EARLY_DONE:-0}" = 1 ]; then CODE=$EARLY_CODE; else wait "$AGENT_PID"; CODE=$?; fi
"$HERE/../../agents.sh" --unregister "$AGENT_PID" 2>/dev/null
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
rm -f "$OUT/.prompt-with-schema.md"

python3 - "$OUT" "$LABEL" "$CWD" "$THINKING" "$PERMISSION" "$CODE" "$((END - START))" \
         "$RESUME" "$STALLED" "$WORKTREE_BRANCH" "$BASE_SHA" "$MODEL" "$BASE_REF" \
         "${SCHEMA:-}" "${ROLE:-}" "$HERE" "$OVER_BUDGET" <<'PY'
import json, sys, pathlib
(out, label, cwd, thinking, permission, code, dur, resume, stalled, branch, base_sha,
 model, base_ref, schema, role, scripts, over_budget) = sys.argv[1:18]
sys.path.insert(0, scripts)
from events import scan_tools
out = pathlib.Path(out)
session, usage, errors, files, reconnects = None, {}, [], set(), 0
tool_events, _ = scan_tools(out / "events.jsonl", 0)
tool_calls = sum(event["ok"] for event in tool_events)
failed_tools = len(tool_events) - tool_calls
texts, cost = [], 0.0
for line in (out / "events.jsonl").read_text(errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = ev.get("type")
    if kind == "session":
        session = ev.get("id")
    elif kind == "message_end":
        m = ev.get("message") or {}
        if m.get("role") != "assistant":
            continue
        u = m.get("usage") or {}
        # Later messages carry the running totals for that message; sum them for the run.
        usage = {"input_tokens": usage.get("input_tokens", 0) + u.get("input", 0),
                 "output_tokens": usage.get("output_tokens", 0) + u.get("output", 0),
                 "cached_input_tokens": usage.get("cached_input_tokens", 0) + u.get("cacheRead", 0)}
        cost += ((u.get("cost") or {}).get("total") or 0)
        for c in m.get("content", []):
            if c.get("type") == "text" and c.get("text"):
                texts.append(c["text"])
            if c.get("type") == "toolCall":
                name = c.get("name") or ""
                # Arguments arrive as a string; partialArgs is the JSON form when present.
                raw = c.get("partialArgs") or c.get("arguments") or ""
                try:
                    inp = json.loads(raw) if isinstance(raw, str) else dict(raw)
                except (json.JSONDecodeError, TypeError, ValueError):
                    inp = {}
                if name in ("write", "edit", "ast_edit", "create", "patch"):
                    path = inp.get("filePath") or inp.get("path") or inp.get("file")
                    if not path:
                        # The edit tool addresses a file inside its input payload as [name#id].
                        head = str(inp.get("input", ""))[:200]
                        if head.startswith("["):
                            path = head[1:].split("#", 1)[0].split("]", 1)[0]
                    if path:
                        files.add(path)
    elif kind == "error":
        message = json.dumps(ev)
        if "Reconnect" in message or "retry" in message.lower():
            reconnects += 1
        else:
            errors.append(ev)
if usage:
    usage["cost"] = round(cost, 6)
if session:
    (out / "thread.txt").write_text(session + "\n")

final = texts[-1].strip() if texts else ""
schema_error = None
if schema and final:
    body = final
    if body.startswith("```"):
        body = body.split("\n", 1)[-1].rsplit("```", 1)[0]
    try:
        parsed = json.loads(body)
        (out / "result.json").write_text(json.dumps(parsed, indent=2, ensure_ascii=False) + "\n")
    except json.JSONDecodeError as e:
        schema_error = f"final message is not valid JSON: {e}"
        (out / "last.txt").write_text(final + "\n")
elif final:
    (out / "last.txt").write_text(final + "\n")

result = out / "result.json" if (out / "result.json").exists() else out / "last.txt"
code = int(code)
meta = {
    "label": label, "engine": "omp", "cwd": cwd, "effort": thinking or "default", "sandbox": permission,
    "model": model or None, "role": role or None, "resumed_from": resume or None,
    "exit_code": code, "duration_s": int(dur), "thread_id": session, "usage": usage,
    "result_file": str(result) if result.exists() else None,
    "result_bytes": result.stat().st_size if result.exists() else 0,
    "tool_calls": tool_calls, "failed_commands": failed_tools, "files_touched": sorted(files),
    "errors": errors[:5], "error_count": len(errors), "schema_error": schema_error,
    "timed_out": code in (124, 137) and stalled != "1",
    "over_budget": over_budget == "1",
    "stalled": stalled == "1", "reconnects": reconnects,
    "transient_failure": bool(code != 0 and reconnects and not usage),
    "worktree_branch": branch or None, "base_sha": base_sha or None, "base_ref": base_ref or None,
}
(out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({k: meta[k] for k in
      ("label", "exit_code", "duration_s", "thread_id", "result_file", "timed_out",
       "stalled", "transient_failure", "schema_error", "worktree_branch")}, ensure_ascii=False))
PY

if [ -n "$SCHEMA" ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("schema_error") else 1)' "$OUT/meta.json" 2>/dev/null; then
  exit 65
fi
exit $CODE
