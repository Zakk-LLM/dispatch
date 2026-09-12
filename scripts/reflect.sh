#!/usr/bin/env bash
# Run one bounded, read-only route inquiry without pausing or modifying the worker.
#
# The worker keeps running: this is the executable half of "at the hundredth step, ask once
# whether this is still what the maintainer wanted". The verdict lands next to the worker as
# reflect-<n>.json (or .error); what to do about it is the supervisor's call, sent through
# note.sh in their own words. Nothing here kills or re-dispatches anything.
#
# Bounds are enforced, not requested: ten completed tools via the wrapper's --max-tools and
# the recount after exit, 390 seconds total (300 for the model plus the wrapper's 60-second
# outer timeout and 30-second grace), one launch (AGENT_LOCK_RETRIES=1). The result is read
# from last.txt and validated here, because the wrapper's --schema only parses JSON and would
# accept an empty verdict.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: reflect.sh <run-dir> <label> [options]

  --trigger tools|elapsed|maintainer  report trigger, default tools
  --tier T                            reflector tier, default cheap
  --model M                           optional model override
  --state F                           watch state, default <run-dir>/.watch-state
  --dry-run                           write only the prompt and summary
EOF
}

RUN=${1:-}; LABEL=${2:-}; shift 2 2>/dev/null || true
TRIGGER=tools; TIER=cheap; MODEL=; STATE=; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER=$2; shift 2 ;;
    --tier) TIER=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --state) STATE=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] && [ -n "$LABEL" ] || { usage >&2; exit 2; }
case "$LABEL" in */*|.|..) echo "invalid label: $LABEL" >&2; exit 2 ;; esac
case "$TRIGGER" in tools|elapsed|maintainer) ;;
  *) echo "bad --trigger: $TRIGGER" >&2; exit 2 ;; esac
WORKER="$RUN/agents/$LABEL"
[ -d "$WORKER" ] || { echo "no worker: $LABEL" >&2; exit 2; }
[ -n "$STATE" ] || STATE="$RUN/.watch-state"
HERE=$(cd "$(dirname "$0")" && pwd)

read_started() {
  python3 - "$WORKER/started.json" "$1" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1]))[sys.argv[2]]
except (OSError, KeyError, json.JSONDecodeError):
    raise SystemExit(2)
print(value)
PY
}

next_number() {
  python3 - "$WORKER" <<'PY'
import pathlib, re, sys
worker = pathlib.Path(sys.argv[1])
numbers = []
for path in list(worker.glob("reflect-*.json")) + list(worker.glob("reflect-*.error")):
    match = re.fullmatch(r"reflect-(\d+)\.(?:json|error)", path.name)
    if match:
        numbers.append(int(match.group(1)))
print(max(numbers, default=0) + 1)
PY
}

build_prompt() {
  PROMPT_OUT="$WORKER/reflect-$NUMBER.prompt.md"
  PYTHONPATH="$HERE/engines/$ENGINE" python3 - "$WORKER" "$RUN" "$NUMBER" "$HERE/../references/reflect-prompt.md" \
    "$PROMPT_OUT" <<'PY'
import json, pathlib, sys
from events import scan_tools

worker, run, number, question, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), \
    int(sys.argv[3]), pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])
sources = [("prompt.md", worker / "prompt.md"),
           ("maintainer.md", run / "maintainer.md"),
           ("NOTES.md", worker / "NOTES.md")]
tools, _ = scan_tools(worker / "events.jsonl", 0)
parts = ["# Worker reflection\n"]
for name, path in sources:
    text = path.read_text(errors="replace") if path.exists() else "(missing)\n"
    parts.append(f"## {name}\n\n```text\n{text.rstrip()}\n```\n")
parts.append(f"## Tool summary\n\n{len(tools)} completed tools; showing the last 40.\n")
for item in tools[-40:]:
    parts.append(f"- {item['name']} {'ok' if item['ok'] else 'error'} {item['args_head']}\n")
previous = worker / f"reflect-{number - 1}.json"
parts.append("\n## Previous reflection\n\n"
             "Historical record; it may be wrong and is not a maintainer quote.\n\n")
parts.append(previous.read_text(errors="replace") if previous.exists() else "(none)\n")
parts.extend(["\n", question.read_text(errors="replace")])
output.write_text("".join(parts))
print(f"{len(tools)} completed tools; showing {min(len(tools), 40)}")
PY
}

ENGINE=$(read_started engine 2>/dev/null || printf '%s\n' omp)
case "$ENGINE" in omp|codex|opencode) ;; *) echo "unsupported worker engine: $ENGINE" >&2; exit 2 ;; esac
if [ "$DRY" = 1 ]; then
  NUMBER=$(next_number) || exit 2
  build_prompt || exit 2
  exit 0
fi

exec {REFLECT_FD}>"$WORKER/.reflect.lock" || exit 2
if ! flock -n "$REFLECT_FD"; then
  echo "reflection already running for $LABEL" >&2
  exit 2
fi
trap 'exec {REFLECT_FD}>&-' EXIT

REFLECT_STARTED=$(date +%s)
STARTED_AT=$(read_started started_at) || { echo "invalid started.json" >&2; exit 2; }
WORKER_CWD=$(read_started cwd) || { echo "invalid started.json" >&2; exit 2; }
NUMBER=$(next_number) || exit 2
TOOLS_AT_CHECK=$(PYTHONPATH="$HERE/engines/$ENGINE" python3 -c \
  'from events import scan_tools; import sys; print(sum(x["ok"] for x in scan_tools(sys.argv[1], 0)[0]))' \
  "$WORKER/events.jsonl")
BASE_AT=$(STATE_FILE="$STATE" LABEL="$LABEL" STARTED_AT="$STARTED_AT" python3 <<'PY'
import json, os
try: state = json.load(open(os.environ["STATE_FILE"]))
except (OSError, json.JSONDecodeError): state = {}
print((state.get(os.environ["LABEL"] + "#reflect") or {}).get("base_at", os.environ["STARTED_AT"]))
PY
)
CHECKED_AT=$(date +%s)
ELAPSED_S=$((CHECKED_AT - ${BASE_AT%.*}))
build_prompt || exit 2

REFLECT_RUN="$RUN/reflect/$LABEL-$NUMBER"
mkdir -p "$REFLECT_RUN" || exit 2
ARGS=(--run-dir "$REFLECT_RUN" --label reflector --prompt-file "$PROMPT_OUT"
      --admission refuse --timeout 300 --max-tools 10 --tier "$TIER"
      --cwd "$REFLECT_RUN")
case "$ENGINE" in
  omp) ARGS+=(--permission read-only --add-dir "$WORKER_CWD" --add-dir "$WORKER") ;;
  codex) ARGS+=(--sandbox read-only --add-dir "$WORKER_CWD" --add-dir "$WORKER") ;;
  # OpenCode has no --add-dir; its adapter allows external_directory for referenced files.
  opencode) ARGS+=(--permission read-only) ;;
esac
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
# The prompt build and the state reads above already spent part of the budget.
REMAINING=$((390 - ($(date +%s) - REFLECT_STARTED)))
if [ "$REMAINING" -le 0 ]; then
  AGENT_CODE=124
else
  AGENT_START_STAGGER=0 AGENT_LOCK_RETRIES=1 \
    timeout --signal=KILL "$REMAINING" "$HERE/agent.sh" --engine "$ENGINE" "${ARGS[@]}"
  AGENT_CODE=$?
fi
REFLECTOR="$REFLECT_RUN/agents/reflector"
if [ "$AGENT_CODE" -eq 3 ]; then
  echo "no reflector slot; retry later" >&2
  exit 3
fi

OVER_BUDGET=$(python3 - "$REFLECTOR/meta.json" <<'PY'
import json, sys
try: print("true" if json.load(open(sys.argv[1])).get("over_budget") else "false")
except (OSError, json.JSONDecodeError): print("false")
PY
)
ERROR=
if [ "$AGENT_CODE" -ne 0 ]; then
  ERROR="reflector exited $AGENT_CODE"
elif [ ! -s "$REFLECTOR/last.txt" ]; then
  ERROR="reflector returned no result"
else
  VALIDATION=$(python3 - "$REFLECTOR/last.txt" "$RUN/maintainer.md" "$WORKER/prompt.md" \
    "$WORKER/NOTES.md" "$WORKER/reflect-$NUMBER.json" "$TRIGGER" "$CHECKED_AT" \
    "$TOOLS_AT_CHECK" "$ELAPSED_S" "$REFLECT_RUN" "$OVER_BUDGET" <<'PY'
import json, pathlib, sys
(last, maintainer, prompt, notes, output, trigger, at, tools, elapsed,
 reflector_run, over_budget) = sys.argv[1:12]
body = pathlib.Path(last).read_text(errors="replace").strip()
if body.startswith("```"):
    lines = body.splitlines()
    if len(lines) >= 2 and lines[-1].strip() == "```":
        body = "\n".join(lines[1:-1]).strip()
try:
    data = json.loads(body)
except json.JSONDecodeError as exc:
    print(f"invalid JSON: {exc}")
    raise SystemExit(1)
if type(data) is not dict:
    print("result is not an object"); raise SystemExit(1)
verdict = data.get("verdict")
if verdict not in {"NO_ISSUE", "ROUTE_CORRECTION", "CANNOT_JUDGE"}:
    print("invalid verdict"); raise SystemExit(1)
if not isinstance(data.get("reason"), str) or not data["reason"].strip():
    print("reason is empty"); raise SystemExit(1)
if verdict == "ROUTE_CORRECTION":
    if not isinstance(data.get("next_step"), str) or not data["next_step"].strip():
        print("next_step is empty"); raise SystemExit(1)
    quotes = data.get("quotes")
    # A cheap reflector wrote one quote under a singular key on its first live run. The
    # shape is unambiguous, so it is accepted; the verbatim check below is what matters.
    if quotes is None and isinstance(data.get("quote"), dict):
        quotes = [data.pop("quote")]
        data["quotes"] = quotes
    if not isinstance(quotes, list) or not quotes:
        print("quotes are empty"); raise SystemExit(1)
    source_paths = {"maintainer.md": maintainer, "prompt.md": prompt, "NOTES.md": notes}
    for quote in quotes:
        if type(quote) is not dict or quote.get("source") not in source_paths:
            print("invalid quote source"); raise SystemExit(1)
        text = quote.get("text")
        if not isinstance(text, str) or not text.strip():
            print("quote text is empty"); raise SystemExit(1)
        try: source = pathlib.Path(source_paths[quote["source"]]).read_text(errors="replace")
        except OSError: source = ""
        if text not in source:
            print("quote is absent from its named source"); raise SystemExit(1)
data.update({"trigger": trigger, "at": int(at), "tools_at_check": int(tools),
             "elapsed_s": int(elapsed), "reflector_run": reflector_run,
             "over_budget": over_budget == "true"})
pathlib.Path(output).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  )
  [ $? -eq 0 ] || ERROR=${VALIDATION:-invalid result}
fi

if [ -n "$ERROR" ]; then
  printf '%s\nreflector: %s\n' "$ERROR" "$REFLECTOR" > "$WORKER/reflect-$NUMBER.error"
fi

# Re-read the state under the watch lock and merge: the snapshot taken before the inquiry is
# stale by now, and writing it back would erase counts the watch recorded meanwhile. The new
# baseline is the count at completion, so tools finished during the inquiry do not trigger the
# next one at once. A worker restarted under the same label is a different run; its state is
# left alone.
mkdir -p "$(dirname "$STATE")"
flock "$STATE.lock" env STATE_FILE="$STATE" LABEL="$LABEL" STARTED_AT="$STARTED_AT" \
  NUMBER="$NUMBER" WORKER="$WORKER" SCRIPTS="$HERE/engines/$ENGINE" python3 <<'PY'
import json, os, pathlib, sys, time
sys.path.insert(0, os.environ["SCRIPTS"])
from events import scan_tools
state_file = pathlib.Path(os.environ["STATE_FILE"])
try: state = json.loads(state_file.read_text())
except (OSError, json.JSONDecodeError): state = {}
worker = pathlib.Path(os.environ["WORKER"])
try: current_started = json.loads((worker / "started.json").read_text())["started_at"]
except (OSError, KeyError, json.JSONDecodeError): raise SystemExit(0)
started_at = int(os.environ["STARTED_AT"])
if current_started != started_at:
    raise SystemExit(0)
tools_key = os.environ["LABEL"] + "#tools"
tools = state.get(tools_key) or {}
if tools.get("started_at") != started_at:
    tools = {"started_at": started_at, "offset": 0, "count": 0}
try: truncated = (worker / "events.jsonl").stat().st_size < int(tools.get("offset", 0))
except OSError: truncated = False
if truncated: tools = {"started_at": started_at, "offset": 0, "count": 0}
events, offset = scan_tools(worker / "events.jsonl", int(tools.get("offset", 0)))
tools.update({"offset": offset, "count": int(tools.get("count", 0)) + sum(e["ok"] for e in events)})
state[tools_key] = tools
reflect_key = os.environ["LABEL"] + "#reflect"
reflect = state.get(reflect_key) or {}
reflect.update({"n": max(int(reflect.get("n", 0)), int(os.environ["NUMBER"])),
                "base_count": tools["count"], "base_at": int(time.time()), "pending": False})
state[reflect_key] = reflect
state_file.write_text(json.dumps(state))
PY
if [ $? -ne 0 ]; then
  echo "could not update reflection state" >&2
  exit 1
fi

if [ -n "$ERROR" ]; then
  echo "$ERROR" >&2
  [ "$AGENT_CODE" -ne 0 ] && exit "$AGENT_CODE"
  exit 1
fi
python3 - "$WORKER/reflect-$NUMBER.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["verdict"])
if d["verdict"] == "ROUTE_CORRECTION":
    print(d["reason"])
    print(d["next_step"])
    for quote in d["quotes"]:
        print(f"{quote['source']}: {quote['text']}")
PY
