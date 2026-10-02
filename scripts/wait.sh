#!/usr/bin/env bash
# Wait for completion; quiet live jobs only produce notices.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$HERE" "$@" <<'PY'
import argparse
import json
from pathlib import Path
import sys
import time
sys.path.insert(0, sys.argv.pop(1))
from liveness import liveness

parser = argparse.ArgumentParser(description="Print unhandled completed or stalled jobs.")
parser.add_argument("run_dir", type=Path)
parser.add_argument("--handled", default="")
parser.add_argument("--interval", type=float, default=15)
parser.add_argument("--timeout", type=float, default=3600)
parser.add_argument("--stall", type=int, default=300,
                    help="seconds without event growth before QUIET; 0 disables notices")
args = parser.parse_args()
if args.interval <= 0 or args.timeout < 0 or args.stall < 0:
    parser.error("interval must be positive; timeout and stall must be nonnegative")
agents = args.run_dir / "agents"
if not agents.is_dir():
    parser.error(f"no agents under {args.run_dir}")
handled, progress = set(args.handled.split(",")), {}
notices = {}
deadline = time.monotonic() + args.timeout
while True:
    found = False
    for agent in sorted(agents.iterdir()):
        if not agent.is_dir() or agent.name in handled:
            continue
        try:
            meta = json.loads((agent / "meta.json").read_text())
        except (OSError, ValueError):
            meta = None
        if meta is not None:
            code = meta.get("exit_code")
            state = ("OK" if code == 0 else "STALLED" if meta.get("stalled") else
                     "TIMEOUT" if meta.get("timed_out") else f"FAIL({code})")
        else:
            try:
                started = json.loads((agent / "started.json").read_text())
            except (OSError, ValueError):
                if not (agent / "events.jsonl").exists():
                    continue
                started = {}
            state, reason = liveness(agent, started, time.time(), args.stall, progress)
            identity = (started.get('started_at'), state)
            if state == 'QUIET':
                if notices.get(agent.name) != identity:
                    print(f'{agent.name} QUIET {reason}', flush=True)
                    notices[agent.name] = identity
                continue
            notices.pop(agent.name, None)
            if not state:
                continue
            state = f"{state} {reason}"
        print(f"{agent.name} {state}")
        found = True
    if found:
        raise SystemExit(0)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SystemExit(1)
    time.sleep(min(args.interval, remaining))
PY
