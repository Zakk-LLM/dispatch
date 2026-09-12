#!/usr/bin/env bash
# A bounded wait that always returns something actionable. Blocks until an agent finishes,
# stalls, or dies, or until the deadline — then prints what changed since the last call. The
# point is that an orchestrator never sleeps for an unknown length of time and never polls
# blindly: it either gets work back, or gets told the window is free for other work.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: watch.sh <run-dir> [--timeout SEC] [--interval SEC] [--state FILE]

  --timeout SEC   maximum block, default 300. Pick it as the time until your next useful
                  action, not as how long the agents might take.
  --interval SEC  poll interval, default 10
  --state FILE    where the seen-set lives, default <run-dir>/.watch-state
  --reflect-tools N  notify after N completed tools, default 100
  --reflect-min M    notify after M elapsed minutes, default 45
  --warn PCT      warn when a running agent has used this share of its wall-clock limit,
                  default 80. Reported once per agent as "<label> EXPIRING <seconds> left".
  --peek          for each running agent, also print its last event, read from the tail of
                  events.jsonl. Liveness never costs more than a few kilobytes.

Exit codes:
  0  something changed — labels and states are printed, act on them now
  1  nothing changed before the deadline — spend the window on work that needs no agent
  2  every agent in the run has finished
  3  the run has no agents yet
EOF
}

RUN=${1:-}; shift 2>/dev/null
[ -n "$RUN" ] || { usage >&2; exit 3; }
case "$RUN" in -h|--help) usage; exit 0 ;; esac

TIMEOUT=300; INTERVAL=10; STATE=; WARN=80; PEEK=0
REFLECT_TOOLS=100; REFLECT_MIN=45
HERE=$(cd "$(dirname "$0")" && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --state) STATE=$2; shift 2 ;;
    --reflect-tools) REFLECT_TOOLS=$2; shift 2 ;;
    --reflect-min) REFLECT_MIN=$2; shift 2 ;;
    --warn) WARN=$2; shift 2 ;;
    --peek) PEEK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done
[ -n "$STATE" ] || STATE="$RUN/.watch-state"
[ -d "$RUN/agents" ] || { echo "no agents under $RUN" >&2; exit 3; }

WAITED=0
while :; do
  # Two orchestrators watching one run must not both claim the same completion, so the
  # read-modify-write of the seen-set happens under a lock.
  OUT=$(flock "$STATE.lock" env RUN_DIR="$RUN" STATE_FILE="$STATE" WARN_PCT="$WARN" \
        PEEK="$PEEK" REFLECT_TOOLS="$REFLECT_TOOLS" REFLECT_MIN="$REFLECT_MIN" \
        SCRIPTS_DIR="$HERE" python3 <<'PY'
import importlib.util, json, os, pathlib, shlex, sys, time

event_modules = {}
def event_module(engine):
    if engine not in ("omp", "codex"):
        raise SystemExit(f"unsupported worker engine: {engine}")
    if engine not in event_modules:
        path = pathlib.Path(os.environ["SCRIPTS_DIR"]) / "engines" / engine / "events.py"
        spec = importlib.util.spec_from_file_location(f"dispatch_events_{engine}", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        event_modules[engine] = module
    return event_modules[engine]

run = pathlib.Path(os.environ["RUN_DIR"])
state_file = pathlib.Path(os.environ["STATE_FILE"])
try:
    seen = json.loads(state_file.read_text())
except (OSError, json.JSONDecodeError):
    seen = {}

agents = [a for a in sorted((run / "agents").glob("*")) if a.is_dir()]
# A directory holding only a prepared spec has not been dispatched: events.jsonl appears when
# the worker actually starts. Counting it as running would hide "nothing was dispatched".
dispatched = [a for a in agents if (a / "events.jsonl").exists() or (a / "meta.json").exists()]
if not dispatched:
    sys.exit(3)

now = time.time()
warn_pct = int(os.environ.get("WARN_PCT", "80"))
reflect_tools = int(os.environ["REFLECT_TOOLS"])
reflect_seconds = int(os.environ["REFLECT_MIN"]) * 60
changed, running, done = [], 0, 0
count_state_changed = False
for a in dispatched:
    events = a / "events.jsonl"
    try:
        started = json.loads((a / "started.json").read_text())
        started_at = started["started_at"]
    except (OSError, KeyError, json.JSONDecodeError):
        started = {}
        started_at = None
    parser = event_module(started.get("engine") or "omp")
    tools_key = f"{a.name}#tools"
    tools = seen.get(tools_key) or {}
    if started_at is not None:
        identity_changed = tools.get("started_at") != started_at
        if identity_changed:
            tools = {"started_at": started_at, "offset": 0, "count": 0}
        try:
            truncated = events.stat().st_size < int(tools.get("offset", 0))
        except OSError:
            truncated = False
        if truncated:
            tools = {"started_at": started_at, "offset": 0, "count": 0}
        calls, offset = parser.scan_tools(events, int(tools.get("offset", 0)))
        updated = {"started_at": started_at, "offset": offset,
                   "count": int(tools.get("count", 0)) + sum(c["ok"] for c in calls)}
        if seen.get(tools_key) != updated:
            seen[tools_key] = updated
            count_state_changed = True
        reflect_key = f"{a.name}#reflect"
        reflect = seen.get(reflect_key) or {}
        if identity_changed or not reflect:
            reflect = {"n": int(reflect.get("n", 0)), "base_count": 0,
                       "base_at": started_at, "pending": False}
            seen[reflect_key] = reflect
            count_state_changed = True
    meta = a / "meta.json"
    if not meta.exists():
        running += 1
        # A guard kill destroys the turn's work, so the warning has to arrive before it, not
        # after: an expiring agent can still be told to stop and report what it has.
        s = started
        if not s:
            continue
        left = int(s.get("deadline", 0) - now)
        limit = int(s.get("timeout_s") or 0)
        reflect = seen[f"{a.name}#reflect"]
        tool_due = updated["count"] - int(reflect.get("base_count", 0)) >= reflect_tools
        time_due = now - float(reflect.get("base_at", started_at)) >= reflect_seconds
        if (tool_due or time_due) and not reflect.get("pending") and left >= 600:
            number = int(reflect.get("n", 0)) + 1
            elapsed = max(0, int((now - float(reflect.get("base_at", started_at))) / 60))
            trigger = "tools" if tool_due else "elapsed"
            command = " ".join(shlex.quote(value) for value in
                               (str(pathlib.Path(os.environ["SCRIPTS_DIR"]) / "reflect.sh"),
                                str(run), a.name, "--trigger", trigger,
                                "--state", os.environ["STATE_FILE"]))
            reflect["pending"] = True
            seen[f"{a.name}#reflect"] = reflect
            changed.append((a.name,
                            f"REFLECT {number}: {updated['count']} tools, {elapsed} min elapsed "
                            f"— {command}", "", ""))
        if limit and left <= limit * (100 - warn_pct) / 100:
            key = f"{a.name}#expiring"
            if key not in seen:
                seen[key] = "EXPIRING"
                changed.append((a.name, f"EXPIRING {max(left, 0)}s left of {limit}s", "", ""))
        # Burning wall-clock without progress: the same tool failing over and over.
        looping = parser.repeated_failure(a / "events.jsonl")
        if looping:
            key = f"{a.name}#loop"
            if seen.get(key) != looping[0]:
                seen[key] = looping[0]
                changed.append((a.name,
                                f"LOOPING {looping[0]} failed {looping[1]} times in the last 40 "
                                f"tool calls — interrupt it, the spec cannot fix itself", "", ""))

        stall = int(s.get("stall_s") or 0)
        if stall and events.exists():
            quiet = int(now - events.stat().st_mtime)
            if quiet >= stall * warn_pct / 100:
                key = f"{a.name}#quiet"
                if key not in seen:
                    seen[key] = "QUIET"
                    changed.append((a.name, f"QUIET {quiet}s without an event, stall kill at {stall}s",
                                    "", ""))
        continue
    try:
        m = json.loads(meta.read_text())
    except (json.JSONDecodeError, OSError):
        # A meta file being written right now is not a finished agent.
        running += 1
        continue
    done += 1
    if m.get("exit_code") == 0:
        state = "OK"
    elif m.get("transient_failure"):
        state = "TRANSIENT"
    elif m.get("stalled"):
        state = "STALLED"
    elif m.get("timed_out"):
        state = "TIMEOUT"
    else:
        state = f"FAIL({m.get('exit_code')})"
    if seen.get(a.name) != state:
        changed.append((a.name, state, m.get("result_file") or "",
                        m.get("thread_id") or ""))
        seen[a.name] = state

# Liveness is the mtime plus the last event, never the whole log: an event file grows to
# megabytes, and reading it to answer "is it alive" is the most expensive way to ask.
peeked = False
if os.environ.get("PEEK") == "1":
    for a in dispatched:
        if (a / "meta.json").exists():
            continue
        ev = a / "events.jsonl"
        if not ev.exists():
            continue
        try:
            started = json.loads((a / "started.json").read_text())
        except (OSError, json.JSONDecodeError):
            started = {}
        line = event_module(started.get("engine") or "omp").last_event(ev) or "(no event yet)"
        # Repeating an unchanged line every poll is the noise this whole design avoids.
        if seen.get(f"{a.name}#peek") == line:
            continue
        seen[f"{a.name}#peek"] = line
        peeked = True
        print(f"~ {a.name}\talive {int(now - ev.stat().st_mtime)}s ago\t{line}", file=sys.stderr)

if changed or peeked or count_state_changed:
    state_file.write_text(json.dumps(seen))

# A peek line is progress information, not a state change: it must not claim exit 0, which
# means "an agent needs handling now".
if changed:
    for name, state, result, thread in changed:
        print(f"{name}\t{state}\t{result}\t{thread}")
    print(f"# {running} still running, {done} finished", file=sys.stderr)
    sys.exit(0)

# Nothing new. Distinguish "all finished and already handled" from "still working".
sys.exit(2 if running == 0 else 1)
PY
)
  CODE=$?
  case "$CODE" in
    0) printf '%s\n' "$OUT"; exit 0 ;;
    2) echo "all agents finished and already reported" >&2; exit 2 ;;
    3) exit 3 ;;
  esac
  [ "$WAITED" -ge "$TIMEOUT" ] && {
    echo "nothing changed in ${TIMEOUT}s — use the window for work that needs no agent" >&2
    exit 1
  }
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done
