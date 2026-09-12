#!/usr/bin/env bash
# Dispatch one opencode agent non-interactively and persist every artifact under the run
# directory. Never blocks on stdin; always writes meta.json, even when killed.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: agent.sh --engine opencode --run-dir DIR --label NAME (--prompt-file FILE | --prompt TEXT) [options]

Required:
  --run-dir DIR      run directory created by new_run.sh
  --label NAME       agent label; artifacts land in <run-dir>/agents/<label>/
  --prompt-file F    task spec file (preferred)
  --prompt TEXT      inline task spec

Workspace:
  --cwd DIR          workspace root for the agent            (default: $PWD)
  --worktree [NAME]  run in a dedicated git worktree of --cwd, branch opencode/<name>
  --worktree-base B  branch or commit the worktree starts from  (default: HEAD)
  --allow-stale-base start a worktree from a base that is behind its upstream

Model and limits:
  --tier NAME        difficulty tier: cheap|standard|deep|frontier|max
                     Sets the variant, and the model when OPENCODE_TIER_<NAME>_MODEL is set.
  --variant LEVEL    provider reasoning effort, e.g. low|medium|high|xhigh|max
  --model NAME       provider/model override
  --agent NAME       opencode agent preset; defaults to plan for read-only and build otherwise
  --timeout SEC      hard wall-clock limit                   (default: 1800)
  --stall SEC        kill when no event arrives for this long (default: off)
  --max-tools N      invalidate after more than N terminal tools (default: 0, unlimited)

Permissions (opencode has no sandbox; these are its equivalent):
  --permission MODE  read-only|inspect|workspace-write|full|bypass  (default: inspect)
                     inspect runs commands but has no edit tool: the profile for auditing,
                     testing, and linting. read-only additionally denies every command that is
                     not plain inspection.
                     bypass allows everything including git history commands and adds --auto.
                     Dangerous, never a default.
  --network          allow webfetch
  --allow-git        do not deny history-changing git commands (dangerous, off by default)
  --allow-cmd PAT    allow one more shell pattern in this run, e.g. --allow-cmd "python3 *"
                     (repeatable; a read-only profile denies everything else by default)

Behavior:
  --schema FILE      append a JSON Schema to the prompt; final JSON syntax is checked after the run
  --resume SESSION   continue an existing session id
  --fork             fork the resumed session instead of extending it
  --admission MODE   wait|refuse|off - how to handle a full machine (default: wait)

Artifacts: prompt.md events.jsonl stderr.log thread.txt started.json meta.json
           result.json (with --schema) or last.txt (without)
EOF
}

RUN_DIR=; LABEL=; PROMPT_FILE=; PROMPT_TEXT=; CWD=$PWD
VARIANT=; VARIANT_SET=0; MODEL=; AGENT=; TIMEOUT=1800; STALL=0; MAX_TOOLS=0; RESUME=; FORK=0
SCHEMA=; TIER=; PERMISSION=inspect; NETWORK=0; ALLOW_GIT=0; ADMISSION=wait; ALLOW_CMDS=()
WORKTREE=; WORKTREE_BASE=HEAD; ALLOW_STALE=0
HERE=$(cd "$(dirname "$0")" && pwd)
REG=${OPENCODE_REGISTRY_DIR:-${XDG_RUNTIME_DIR:-/tmp}/opencode-agents}

# Machine-local defaults (tier-to-model bindings, the shared cap) live outside this repository
# so nothing here assumes a provider's lineup. The file is optional.
ENV_FILE=${AGENT_ORCHESTRATION_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestration.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
# Codex and OpenCode share one machine quota, so they share one slot directory and cap.
SLOTS=${AGENT_SLOTS_DIR:-${XDG_RUNTIME_DIR:-/tmp}/agent-slots}

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --prompt-file) PROMPT_FILE=$2; shift 2 ;;
    --prompt) PROMPT_TEXT=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --worktree)
      if [ $# -ge 2 ] && case "$2" in --*) false ;; *) true ;; esac; then WORKTREE=$2; shift 2
      else WORKTREE=@label; shift; fi ;;
    --worktree-base) WORKTREE_BASE=$2; shift 2 ;;
    --allow-stale-base) ALLOW_STALE=1; shift ;;
    --tier) TIER=$2; shift 2 ;;
    --variant) VARIANT=$2; VARIANT_SET=1; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --agent) AGENT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --stall) STALL=$2; shift 2 ;;
    --max-tools) MAX_TOOLS=$2; shift 2 ;;
    --permission) PERMISSION=$2; shift 2 ;;
    --network) NETWORK=1; shift ;;
    --allow-git) ALLOW_GIT=1; shift ;;
    --allow-cmd) ALLOW_CMDS+=("$2"); shift 2 ;;
    --schema) SCHEMA=$2; shift 2 ;;
    --resume) RESUME=$2; shift 2 ;;
    --fork) FORK=1; shift ;;
    --admission) ADMISSION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$TIER" ]; then
  case "$TIER" in
    cheap)    TIER_VARIANT=low ;;
    standard) TIER_VARIANT=medium ;;
    deep)     TIER_VARIANT=high ;;
    frontier) TIER_VARIANT=xhigh ;;
    max)      TIER_VARIANT=max ;;
    *) echo "bad --tier: $TIER (cheap|standard|deep|frontier|max)" >&2; exit 2 ;;
  esac
  # The variant ladder is a default, not a law: a machine where a mid model at a high variant
  # beats a top model at a lower one wants a different shape, and that belongs in the
  # machine-local file rather than in every job's flags.
  TIER_VARIANT_VAR="OPENCODE_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_VARIANT"
  eval "TIER_OVERRIDE=\${$TIER_VARIANT_VAR:-}"
  [ -n "$TIER_OVERRIDE" ] && TIER_VARIANT=$TIER_OVERRIDE
  [ "$VARIANT_SET" = 1 ] || VARIANT=$TIER_VARIANT
  if [ -z "$MODEL" ]; then
    TIER_VAR="OPENCODE_TIER_$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')_MODEL"
    eval "MODEL=\${$TIER_VAR:-}"
  fi
fi

[ -n "$RUN_DIR" ] && [ -n "$LABEL" ] || { echo "--run-dir and --label are required" >&2; exit 2; }
[ -n "$PROMPT_FILE" ] || [ -n "$PROMPT_TEXT" ] || { echo "--prompt-file or --prompt is required" >&2; exit 2; }
case "$PERMISSION" in read-only|inspect|workspace-write|full|bypass) ;;
  *) echo "bad --permission: $PERMISSION" >&2; exit 2 ;; esac
[ "$PERMISSION" = bypass ] && echo "WARNING: $LABEL runs with every permission allowed" >&2
case "$ADMISSION" in wait|refuse|off) ;; *) echo "bad --admission: $ADMISSION (wait|refuse|off)" >&2; exit 2 ;; esac
case "$LABEL" in */*|.|..) echo "invalid label: $LABEL (no path separators)" >&2; exit 2 ;; esac
case "$MAX_TOOLS" in *[!0-9]*|"") echo "bad --max-tools: $MAX_TOOLS" >&2; exit 2 ;; esac

CWD=$(cd "$CWD" && pwd) || exit 2
OUT="$RUN_DIR/agents/$LABEL"
mkdir -p "$OUT" || exit 2

if [ -n "$PROMPT_FILE" ]; then
  [ "$PROMPT_FILE" -ef "$OUT/prompt.md" ] || cp "$PROMPT_FILE" "$OUT/prompt.md" || exit 2
else
  printf '%s\n' "$PROMPT_TEXT" > "$OUT/prompt.md"
fi

# opencode has no sandbox: permission rules are the boundary, and they are merged into the
# user's config for this run only. "ask" must never appear — a non-interactive run would hang
# waiting for an answer nobody can give.
# plan mode removes the write tools entirely, which is a stronger boundary than any permission
# rule: measured with edit:allow in force, a plan agent still could not modify a file. Using it
# for read-only work means two independent boundaries instead of one.
if [ -z "$AGENT" ]; then
  case "$PERMISSION" in
    # plan has no write tool at all, which is what read-only wants. inspect must NOT use it:
    # measured, a plan agent refuses to run commands because its own prompt says it is a
    # planning mode, so an auditor there reports "not run" instead of running the tests.
    read-only) AGENT=plan ;;
    *) AGENT=build ;;
  esac
fi

ALLOW_CMDS_JSON=$(python3 -c 'import json,sys; json.dump(sys.argv[1:], sys.stdout)' ${ALLOW_CMDS+"${ALLOW_CMDS[@]}"})
PERM_JSON=$(PERMISSION="$PERMISSION" NETWORK="$NETWORK" ALLOW_GIT="$ALLOW_GIT" \
            ALLOW_CMDS="$ALLOW_CMDS_JSON" python3 -c '
import json, os
mode, network, allow_git = os.environ["PERMISSION"], os.environ["NETWORK"], os.environ["ALLOW_GIT"]
# History-changing git is denied for the same reason every task spec forbids it: the
# orchestrator owns commits, merges, and branches.
GIT_DENY = {f"git {c}*": "deny" for c in
            ("commit", "push", "rebase", "checkout", "switch", "reset", "merge", "cherry-pick",
             "stash", "tag", "branch -d", "branch -D", "clean")}
DESTRUCTIVE = {"rm -rf *": "deny", "sudo *": "deny", "shutdown*": "deny", "reboot*": "deny"}
if mode == "inspect":
    # An auditor has to run the tests and the linter it is judging by. The edit tools are gone
    # (plan mode) and history-changing git is denied, but bash is bash: a command can still
    # write a file, so the scope check in the review gate is what actually catches that.
    bash = {"*": "allow"}
    bash.update(DESTRUCTIVE)
    if allow_git != "1":
        bash.update(GIT_DENY)
    perm = {"edit": "deny", "bash": bash}
elif mode == "read-only":
    bash = {"*": "deny"}
    # Reading the repository is the whole job of a read-only agent.
    bash.update({p: "allow" for p in
                 ("ls*", "cat*", "head*", "tail*", "wc*", "file*", "stat*", "find*", "grep*",
                  "rg*", "sed -n*", "awk*", "nl*", "sort*", "uniq*", "cut*", "tr *", "diff*",
                  "jq*", "basename*", "dirname*", "realpath*", "readlink*", "which*", "type *",
                  "env", "tree*", "du*", "df*", "md5sum*", "sha256sum*",
                  "git log*", "git show*", "git diff*", "git status*", "git grep*",
                  "git ls-files*", "git rev-parse*", "git blame*", "git describe*",
                  "git branch --list*", "git worktree list*")})
    perm = {"edit": "deny", "bash": bash}
elif mode == "workspace-write":
    bash = {"*": "allow"}
    bash.update(DESTRUCTIVE)
    if allow_git != "1":
        bash.update(GIT_DENY)
    perm = {"edit": "allow", "bash": bash}
else:
    # full and bypass both allow everything; bypass additionally drops the git denials, which
    # `full` keeps because the orchestrator still owns commits.
    perm = {"edit": "allow", "bash": {"*": "allow"}}
    if mode == "full" and allow_git != "1":
        perm["bash"].update(GIT_DENY)
perm["webfetch"] = "allow" if network == "1" else "deny"
# Nothing may resolve to "ask": a non-interactive run has nobody to answer, and the agent would
# sit until the timeout kills it. These two default to ask in opencode.
# Anything the orchestrator explicitly allowed for this run, added last so it wins.
for pattern in json.loads(os.environ.get("ALLOW_CMDS") or "[]"):
    perm.setdefault("bash", {})[pattern] = "allow"
perm["doom_loop"] = "deny"          # a suspected runaway loop stops rather than waiting
perm["external_directory"] = "allow"  # specs point workers at skill files outside the workspace
print(json.dumps({"permission": perm}))
') || exit 2

WORKTREE_PATH=; WORKTREE_BRANCH=; BASE_SHA=; BASE_REF=
BASE_SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null)
BASE_REF=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$WORKTREE" ]; then
  [ "$WORKTREE" = "@label" ] && WORKTREE=$LABEL
  git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1 || { echo "--worktree needs $CWD to be a git repository" >&2; exit 2; }
  WORKTREE_BRANCH="opencode/$WORKTREE"
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

# opencode has no --output-schema, so the schema goes into the prompt and the wrapper checks
# only that the answer is valid JSON afterwards.
PROMPT_INPUT="$OUT/prompt.md"
if [ -n "$SCHEMA" ]; then
  PROMPT_INPUT="$OUT/.prompt-with-schema.md"
  { cat "$OUT/prompt.md"
    printf '\n\n## Output contract\nYour final message must be exactly one JSON object, no prose,\nno code fence, matching this schema:\n\n```json\n'
    cat "$SCHEMA"
    printf '\n```\n'
  } > "$PROMPT_INPUT"
fi

ARGS=(run --format json --dir "$CWD")
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
[ -n "$VARIANT" ] && ARGS+=(--variant "$VARIANT")
[ -n "$AGENT" ] && ARGS+=(--agent "$AGENT")
[ "$PERMISSION" = bypass ] && ARGS+=(--auto)
if [ -n "$RESUME" ]; then
  ARGS+=(-s "$RESUME")
  [ "$FORK" = 1 ] && ARGS+=(--fork)
fi

if [ "$ADMISSION" != off ]; then
  mkdir -p "$SLOTS" 2>/dev/null
  MAXA=${AGENT_MAX_AGENTS:-5}
  SLOT_FD=; WAITED=0
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

# opencode keeps its session state in SQLite, and several processes reaching it in the same
# instant lose to "database is locked". Starts are therefore serialized machine-wide with a
# short hold, so a fan-out ramps in rather than stampeding. The lock covers the launch only.
STAGGER=${AGENT_START_STAGGER:-2}
stagger_start() {
  [ "$STAGGER" -gt 0 ] 2>/dev/null || return 0
  mkdir -p "$SLOTS" 2>/dev/null
  exec {sfd}>"$SLOTS/.start.lock" || return 0
  flock "$sfd" 2>/dev/null || return 0
  sleep "$STAGGER"
  exec {sfd}>&-
}

# A lock error happens before the model does anything, so retrying costs nothing and repeats
# nothing. Any run that produced real events is never retried: that would duplicate work.
locked_without_progress() {
  grep -qiE "database is locked|SQLITE_BUSY|database table is locked" "$OUT/stderr.log" \
       "$OUT/events.jsonl" 2>/dev/null || return 1
  ! grep -qE '"type":"(tool_use|text|step_finish)"' "$OUT/events.jsonl" 2>/dev/null
}

ATTEMPT=0
MAX_ATTEMPTS=${AGENT_LOCK_RETRIES:-4}
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  stagger_start
  # stdin must be closed: an inherited terminal stdin makes `opencode run` wait forever, exactly
  # as it does for codex. The prompt is passed as an argument, not on stdin.
  ( cd "$CWD" && OPENCODE_CONFIG_CONTENT="$PERM_JSON" \
      timeout --signal=INT --kill-after=30 "$TIMEOUT" \
      opencode "${ARGS[@]}" "$(cat "$PROMPT_INPUT")" \
      < /dev/null > "$OUT/events.jsonl" 2> "$OUT/stderr.log" ) &
  AGENT_PID=$!
  # Only a launch that dies immediately can be a lock collision; a long run is real work.
  sleep 2
  if kill -0 "$AGENT_PID" 2>/dev/null; then break; fi
  # Already finished: reap it once and remember the status, or the final wait would report 127.
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

# A bounded inquiry may have no stall guard, so its tool budget needs an independent watcher.
# The recount after exit is the hard edge when a fast run finishes before this loop observes it.
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
json.dump({"label": os.environ["LABEL"], "engine": "opencode", "cwd": os.environ["CWD"],
           "pid": int(os.environ["PID"]), "started_at": int(os.environ["START"]),
           "timeout_s": int(os.environ["TIMEOUT"]), "stall_s": int(os.environ["STALL"]),
           "deadline": int(os.environ["START"]) + int(os.environ["TIMEOUT"])},
          open(sys.argv[1], "w"))' "$STARTED_JSON" 2>/dev/null

REG_META=$(mktemp)
LABEL="$LABEL" CWD="$CWD" RUN_DIR="$RUN_DIR" TIER="$TIER" VARIANT="$VARIANT" PERMISSION="$PERMISSION" \
  python3 -c 'import json, os, sys
json.dump({"label": os.environ["LABEL"], "engine": "opencode", "cwd": os.environ["CWD"],
           "run_dir": os.environ["RUN_DIR"], "tier": os.environ["TIER"] or None,
           "effort": os.environ["VARIANT"] or "default", "sandbox": os.environ["PERMISSION"]},
          open(sys.argv[1], "w"))' "$REG_META" 2>/dev/null \
  || echo "warning: could not build registry metadata for $LABEL" >&2
OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --register "$AGENT_PID" "$REG_META" 2>/dev/null
rm -f "$REG_META"

cleanup() {
  kill -INT "$AGENT_PID" 2>/dev/null
  [ -n "${WATCHER:-}" ] && kill "$WATCHER" 2>/dev/null
  [ -n "${BUDGET_WATCHER:-}" ] && kill "$BUDGET_WATCHER" 2>/dev/null
  OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --unregister "$AGENT_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [ "${EARLY_DONE:-0}" = 1 ]; then CODE=$EARLY_CODE; else wait "$AGENT_PID"; CODE=$?; fi
OMP_REGISTRY_DIR="$REG" "$HERE/../../agents.sh" --unregister "$AGENT_PID" 2>/dev/null
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

python3 - "$OUT" "$LABEL" "$CWD" "$VARIANT" "$PERMISSION" "$CODE" "$((END - START))" \
         "$RESUME" "$STALLED" "$WORKTREE_BRANCH" "$BASE_SHA" "$MODEL" "$BASE_REF" \
         "${SCHEMA:-}" "$HERE" "$OVER_BUDGET" <<'PY'
import json, sys, pathlib
(out, label, cwd, variant, permission, code, dur, resume, stalled, branch, base_sha,
 model, base_ref, schema, scripts, over_budget) = sys.argv[1:17]
sys.path.insert(0, scripts)
from events import scan_tools
out = pathlib.Path(out)
session, usage, errors, files, reconnects = None, {}, [], set(), 0
tool_events, _ = scan_tools(out / "events.jsonl", 0)
tool_calls = sum(event["ok"] for event in tool_events)
failed_cmds = len(tool_events) - tool_calls
texts = []
for line in (out / "events.jsonl").read_text(errors="replace").splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    session = session or ev.get("sessionID")
    part = ev.get("part") or {}
    kind = ev.get("type")
    if kind == "step_finish":
        # The last step carries the run's totals; earlier ones are per-step.
        tok = part.get("tokens") or {}
        usage = {"input_tokens": tok.get("input", 0), "output_tokens": tok.get("output", 0),
                 "reasoning_output_tokens": tok.get("reasoning", 0),
                 "cached_input_tokens": (tok.get("cache") or {}).get("read", 0),
                 "cost": part.get("cost", 0)}
    elif kind == "text":
        texts.append(part.get("text") or "")
    elif kind == "error":
        message = str((ev.get("error") or {}).get("data", {}).get("message", ""))
        if "Reconnect" in message or "retry" in message.lower():
            reconnects += 1
        else:
            errors.append(ev)
    elif kind == "tool_use":
        state = part.get("state") or {}
        inp = state.get("input") or {}
        tool = part.get("tool")
        if tool in ("edit", "write", "create"):
            path = inp.get("filePath") or inp.get("path")
            if path:
                files.add(path)
        elif tool == "apply_patch":
            # The patch tool names its targets inside the patch text, not in a path field.
            for line in str(inp.get("patchText", "")).splitlines():
                for marker in ("*** Update File: ", "*** Add File: ", "*** Delete File: "):
                    if line.startswith(marker):
                        files.add(line[len(marker):].strip())
        elif tool == "bash":
            # A command can write too; the review gate catches that from git, not from here.
            pass
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
    "label": label, "engine": "opencode", "cwd": cwd,
    "effort": variant or "default", "sandbox": permission,
    "model": model or None, "resumed_from": resume or None, "exit_code": code,
    "duration_s": int(dur), "thread_id": session, "usage": usage,
    "result_file": str(result) if result.exists() else None,
    "result_bytes": result.stat().st_size if result.exists() else 0,
    "tool_calls": tool_calls, "failed_commands": failed_cmds, "files_touched": sorted(files),
    "errors": errors[:5], "error_count": len(errors),
    "schema_error": schema_error,
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

# A JSON syntax violation is a failed run even when opencode exited cleanly.
[ "$CODE" -eq 66 ] && exit 66
if [ -n "$SCHEMA" ] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("schema_error") else 1)' "$OUT/meta.json" 2>/dev/null; then
  exit 65
fi
exit $CODE
