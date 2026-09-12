#!/usr/bin/env bash
# Dispatch a whole fan-out from a job list: hardest first, concurrency derived from the
# machine, everything else delegated to the selected agent adapter. One command instead of N background
# invocations the orchestrator has to track by hand.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: dispatch.sh --engine omp|codex|opencode --run-dir DIR --jobs FILE [--weight light|medium|heavy] [--max N]
                         [--common "ARGS"] [--dry-run]

FILE is JSONL, one job per line. `label` is required; `engine` defaults to --engine.
Common keys: tier model cwd prompt_file timeout stall max_tools admission depends_on worktree resume.
OMP-only keys: thinking role permission network allow_git.
Codex-only keys: effort sandbox profile approve_for_me add_dir network.
OpenCode-only keys: variant agent permission allow_cmd fork network allow_git.

prompt_file defaults to <run-dir>/agents/<label>/prompt.md. Independent jobs run
hardest-tier-first. Global concurrency is the larger engine capacity; each engine also keeps
its own lane limit so a full quota pool cannot block work from the independent pool.

depends_on holds labels that must finish successfully first. A dependent job is not dispatched
until they do, and is skipped outright if any of them fails — running it against a missing or
broken result only produces work that has to be thrown away. Unknown labels and dependency
cycles are rejected before anything is dispatched.
EOF
}

ENGINE=; RUN=; JOBS=; WEIGHT=medium; MAX=0; COMMON=; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE=$2; shift 2 ;;
    --run-dir) RUN=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    --weight) WEIGHT=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    --common) COMMON=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$ENGINE" ] && [ -n "$RUN" ] && [ -n "$JOBS" ] || { usage >&2; exit 2; }
case "$ENGINE" in omp|codex|opencode) ;; *) echo "unsupported engine: $ENGINE" >&2; exit 2 ;; esac
[ -f "$JOBS" ] || { echo "no such job file: $JOBS" >&2; exit 2; }

OMP_CAP=$("$HERE/capacity.sh" --engine omp "$WEIGHT" 2>/dev/null) || OMP_CAP=3
METERED_CAP=$("$HERE/capacity.sh" --engine opencode "$WEIGHT" 2>/dev/null) || METERED_CAP=3
# A full pool still gets one waiting wrapper, but cannot occupy every scheduler slot and block
# work from the independent pool.
[ "${OMP_CAP:-0}" -ge 1 ] 2>/dev/null || OMP_CAP=1
[ "${METERED_CAP:-0}" -ge 1 ] 2>/dev/null || METERED_CAP=1
if [ "$OMP_CAP" -gt "$METERED_CAP" ]; then CAP=$OMP_CAP; else CAP=$METERED_CAP; fi
[ "$MAX" -gt 0 ] 2>/dev/null && [ "$MAX" -lt "$CAP" ] && CAP=$MAX
echo "dispatching with concurrency $CAP (weight $WEIGHT; omp lane $OMP_CAP, codex/opencode lane $METERED_CAP)" >&2

# Expand each job into a complete agent.sh argument line, hardest tier first, with its
# dependencies attached so the scheduler below can hold it back.
CMDS=$(RUN_DIR="$RUN" DEFAULT_ENGINE="$ENGINE" python3 - "$JOBS" <<'PY'
import json, os, shlex, sys
order = {"frontier": 0, "deep": 1, "standard": 2, "cheap": 3}
run = os.environ["RUN_DIR"]
default_engine = os.environ["DEFAULT_ENGINE"]
# schema is common because every adapter takes --schema; what it enforces differs (codex
# validates against the schema, omp and opencode only parse the result as JSON), and the
# engine page says so. The honk-lab job files carry it on every line.
common = {"tier", "model", "cwd", "prompt_file", "timeout", "stall", "max_tools",
          "admission", "depends_on", "worktree", "resume", "schema"}
specific = {
    "omp": {"thinking", "role", "permission", "network", "allow_git"},
    "codex": {"effort", "sandbox", "profile", "approve_for_me", "add_dir", "network"},
    "opencode": {"variant", "agent", "permission", "allow_cmd", "fork", "network", "allow_git"},
}
jobs = []
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    try:
        j = json.loads(line)
    except json.JSONDecodeError as e:
        sys.exit(f"job file line {n}: {e}")
    if "label" not in j:
        sys.exit(f"job file line {n}: missing label")
    engine = j.get("engine", default_engine)
    if engine not in specific:
        sys.exit(f"job file line {n}: unsupported engine {engine!r}")
    allowed = {"label", "engine"} | common | specific[engine]
    invalid = sorted(set(j) - allowed)
    if invalid:
        sys.exit(f"job file line {n}: field {invalid[0]!r} is invalid for engine {engine!r}")
    j["engine"] = engine
    jobs.append(j)

for j in sorted(jobs, key=lambda j: order.get(j.get("tier", "standard"), 2)):
    label = j["label"]
    engine = j["engine"]
    a = ["--run-dir", run, "--label", label]
    a += ["--prompt-file", j.get("prompt_file", f"{run}/agents/{label}/prompt.md")]
    mappings = [("tier", "--tier"), ("model", "--model"), ("cwd", "--cwd"),
                ("timeout", "--timeout"), ("stall", "--stall"),
                ("max_tools", "--max-tools"), ("admission", "--admission"),
                ("resume", "--resume"), ("schema", "--schema")]
    if engine == "omp":
        mappings += [("thinking", "--thinking"), ("role", "--role"),
                     ("permission", "--permission")]
    elif engine == "codex":
        mappings += [("effort", "--effort"), ("sandbox", "--sandbox"),
                     ("profile", "--profile")]
    else:
        mappings += [("variant", "--variant"), ("agent", "--agent"),
                     ("permission", "--permission")]
    for key, flag in mappings:
        if j.get(key) is not None:
            a += [flag, str(j[key])]
    if j.get("worktree"):
        a += ["--worktree"] if j["worktree"] is True else ["--worktree", str(j["worktree"])]
    if j.get("network"):
        a += ["--network"]
    if j.get("allow_git"):
        a += ["--allow-git"]
    if j.get("approve_for_me"):
        a += ["--approve-for-me"]
    if j.get("fork"):
        a += ["--fork"]
    add_dirs = j.get("add_dir") or []
    if isinstance(add_dirs, str):
        add_dirs = [add_dirs]
    if not isinstance(add_dirs, list) or not all(isinstance(value, str) for value in add_dirs):
        sys.exit(f"job {label!r}: field 'add_dir' is invalid for engine 'codex'")
    for value in add_dirs:
        a += ["--add-dir", value]
    allow_cmds = j.get("allow_cmd") or []
    if isinstance(allow_cmds, str):
        allow_cmds = [allow_cmds]
    if not isinstance(allow_cmds, list) or not all(isinstance(value, str) for value in allow_cmds):
        sys.exit(f"job {label!r}: field 'allow_cmd' is invalid for engine 'opencode'")
    for value in allow_cmds:
        a += ["--allow-cmd", value]
    deps = ",".join(j.get("depends_on") or []) or "-"
    print(label + "\t" + deps + "\t" + engine + "\t" + " ".join(shlex.quote(x) for x in a))

# A dependency that does not exist, or a cycle, would deadlock the scheduler or silently drop
# work. Both are decided here, before a single agent starts.
labels = {j["label"] for j in jobs}
for j in jobs:
    for d in j.get("depends_on") or []:
        if d not in labels:
            sys.exit(f"job {j['label']!r} depends on unknown label {d!r}")
graph = {j["label"]: list(j.get("depends_on") or []) for j in jobs}
state = {}
def visit(node, chain):
    if state.get(node) == "done":
        return
    if state.get(node) == "open":
        sys.exit("dependency cycle: " + " -> ".join(chain + [node]))
    state[node] = "open"
    for d in graph.get(node, []):
        visit(d, chain + [node])
    state[node] = "done"
for label in graph:
    visit(label, [])
PY
) || exit 2

[ -n "$CMDS" ] || { echo "no jobs found in $JOBS" >&2; exit 2; }

if [ "$DRY" = 1 ]; then
  printf '%s\n' "$CMDS" | while IFS=$'\t' read -r label deps engine args; do
    printf '%s%s: agent.sh --engine %s %s %s\n' "$label" \
      "$([ "$deps" != - ] && echo " (after $deps)")" "$engine" "$args" "$COMMON"
  done
  exit 0
fi

declare -A DEPS ENGINE_OF ARGS RESULT PID_OF CAP_OF
CAP_OF[omp]=$OMP_CAP
CAP_OF[codex]=$METERED_CAP
CAP_OF[opencode]=$METERED_CAP
ORDER=()
while IFS=$'\t' read -r label deps engine args; do
  [ "$deps" = - ] && deps=
  ORDER+=("$label"); DEPS[$label]=$deps; ENGINE_OF[$label]=$engine; ARGS[$label]=$args
done <<< "$CMDS"

mkdir -p "$RUN/logs"
FAIL=0

engine_running() {
  local wanted=$1 item count=0
  for item in "${ORDER[@]}"; do
    case "$wanted:${ENGINE_OF[$item]:-}" in
      omp:omp|codex:codex|codex:opencode|opencode:codex|opencode:opencode) ;;
      *) continue ;;
    esac
    if [ -n "${PID_OF[$item]:-}" ] && [ -z "${RESULT[$item]:-}" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

launch() {
  local label=$1
  echo "start $label" >&2
  eval "\"$HERE/agent.sh\" --engine \"${ENGINE_OF[$label]}\" ${ARGS[$label]} $COMMON" > "$RUN/logs/$label.dispatch.log" 2>&1 &
  PID_OF[$label]=$!
}

# Ready when every dependency finished successfully; skipped when one of them failed. Holding a
# dependent back is the whole point: dispatching it early wastes the run and has to be redone.
deps_state() {
  local label=$1 dep
  local status=ready
  IFS=',' read -ra list <<< "${DEPS[$label]}"
  for dep in ${list+"${list[@]}"}; do
    [ -z "$dep" ] && continue
    case "${RESULT[$dep]:-pending}" in
      ok) ;;
      pending|running) status=waiting ;;
      *) echo "skip"; return ;;
    esac
  done
  echo "$status"
}

remaining=${#ORDER[@]}
while [ "$remaining" -gt 0 ]; do
  progressed=0
  for label in "${ORDER[@]}"; do
    [ -n "${RESULT[$label]:-}" ] && continue
    [ -n "${PID_OF[$label]:-}" ] && continue
    case "$(deps_state "$label")" in
      ready)
        [ "$(engine_running "${ENGINE_OF[$label]}")" -ge "${CAP_OF[${ENGINE_OF[$label]}]}" ] &&
          continue
        [ "$(jobs -pr | wc -l)" -ge "$CAP" ] && continue
        launch "$label"; progressed=1 ;;
      skip)
        RESULT[$label]=skipped; FAIL=1; remaining=$((remaining - 1)); progressed=1
        echo "skip $label: a dependency failed" >&2 ;;
    esac
  done

  # Reap whatever finished, then loop: a completed dependency may unblock several jobs.
  for label in "${ORDER[@]}"; do
    pid=${PID_OF[$label]:-}
    [ -z "$pid" ] && continue
    [ -n "${RESULT[$label]:-}" ] && continue
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; code=$?
      if [ "$code" = 0 ]; then RESULT[$label]=ok; else RESULT[$label]=failed; FAIL=1; fi
      remaining=$((remaining - 1)); progressed=1
      printf '%s exit=%s\n' "$label" "$code" >&2
    fi
  done

  [ "$remaining" -gt 0 ] && [ "$progressed" = 0 ] && sleep 2
done

for label in "${ORDER[@]}"; do
  [ "${RESULT[$label]:-}" = skipped ] && echo "$label: skipped, dependency failed" >&2
done
"$HERE/status.sh" "$RUN" 2>/dev/null | head -n $(( ${#ORDER[@]} + 4 ))
exit $FAIL
