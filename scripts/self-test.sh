#!/usr/bin/env sh
# Every check must prove it can still go red. A check that cannot fail is worse than no check:
# it looks like coverage.
#
# All breakage happens on a temporary copy, so no tracked file is touched. That makes this
# safe inside a commit hook and removes the need for a "remember to restore it" convention.
set -u
cd "$(dirname "$0")/.." || exit 2
ENGINE=${1:-omp}
command -v python3 >/dev/null 2>&1 || { echo "no python3, controls cannot run"; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0
fail=0

# Start each control from a clean copy so one break cannot leak into the next.
fresh() {
  rm -rf "$TMP/w"
  mkdir -p "$TMP/w" || return 2
  cp SKILL.md "$TMP/w/SKILL.md" || return 2
  cp README.md README.zh-TW.md "$TMP/w/" || return 2
  cp -R scripts references "$TMP/w/" || return 2
  [ -f install.sh ] && cp install.sh "$TMP/w/install.sh"
  return 0
}

# expect <wanted exit code> <name> <command...>
expect() {
  want=$1
  name=$2
  shift 2
  "$@" >"$TMP/out" 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'DEAD  %s: wanted exit %s, got %s\n' "$name" "$want" "$rc"
    sed 's/^/      /' "$TMP/out"
  fi
}

# Prove the exact source text exists before a mutation. A stale sed expression must stop the
# controls instead of turning a no-op into apparent coverage.
require_count() {
  want=$1
  needle=$2
  path=$3
  got=$(grep -cF -- "$needle" "$path")
  if [ "$got" -ne "$want" ]; then
    printf 'DEAD  mutation source in %s: wanted %s copies, found %s\n' "$path" "$want" "$got"
    exit 2
  fi
}

# Shared event fixtures exercise the parser through both public consumers.
fresh || exit 2
cat > "$TMP/event-controls.py" <<'PY'
import fcntl, importlib.util, json, os, pathlib, shlex, subprocess, sys, threading, time

root = pathlib.Path(sys.argv[1])
tmp = root.parent
sys.path.insert(0, str(root / "scripts/engines/omp"))
from events import scan_tools

def event(kind, call, name="read", ok=True, args=None):
    row = {"type": kind, "toolCallId": call, "toolName": name}
    if kind == "tool_execution_start":
        row["args"] = args or {}
    else:
        row["isError"] = not ok
    return json.dumps(row, separators=(",", ":")) + "\n"

def run(name, fn):
    try:
        fn()
    except Exception as exc:
        print(f"DEAD  {name}: {exc}")
        raise
    print(f"PASS  {name}")

def fake_omp(lines, delay=0, exit_code=0):
    bindir = tmp / "bin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "omp"
    script.write_text("#!/usr/bin/env python3\nimport os,sys,time\n" +
                      "p=os.environ.get('FAKE_COUNT')\n" +
                      "open(p,'a').write('1\\n') if p else None\n" +
                      f"lines={lines!r}\n" +
                      "for line in lines:\n print(line, flush=True)\n" +
                      f"time.sleep({delay})\nsys.exit({exit_code})\n")
    script.chmod(0o755)
    return bindir

def codex_completed(item_type, item_id, **fields):
    item = {"id": item_id, "type": item_type}
    item.update(fields)
    return json.dumps({"type": "item.completed", "item": item},
                      separators=(",", ":")) + "\n"

def fake_codex(lines, delay=0, exit_code=0):
    bindir = tmp / "codex-bin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "codex"
    script.write_text(
        "#!/usr/bin/env python3\n"
        "import json,os,pathlib,sys,time\n"
        "p=os.environ.get('FAKE_COUNT')\n"
        "open(p,'a').write('1\\n') if p else None\n"
        f"lines={lines!r}\n"
        "answer=None\n"
        "for line in lines:\n"
        " print(line, flush=True)\n"
        " try:\n"
        "  item=json.loads(line).get('item') or {}\n"
        "  if item.get('type') == 'agent_message': answer=item.get('text')\n"
        " except (json.JSONDecodeError, AttributeError): pass\n"
        "args=sys.argv[1:]\n"
        "if os.environ.get('FAKE_ARGV'):\n"
        " pathlib.Path(os.environ['FAKE_ARGV']).write_text(json.dumps(args))\n"
        "if os.environ.get('FAKE_ENV'):\n"
        " pathlib.Path(os.environ['FAKE_ENV']).write_text(json.dumps({k:os.environ.get(k) for k in ('AGENT_START_STAGGER','AGENT_LOCK_RETRIES')}))\n"
        "if answer is not None and '-o' in args:\n"
        " pathlib.Path(args[args.index('-o')+1]).write_text(answer+'\\n')\n"
        f"time.sleep({delay})\nsys.exit({exit_code})\n")
    script.chmod(0o755)
    return bindir

_MISSING = object()

def opencode_event(kind, call, name="read", ok=True, args=None, exit_code=_MISSING):
    status = "pending" if kind == "tool_execution_start" else \
        ("completed" if ok else "error")
    state = {"status": status, "input": args or {}}
    if exit_code is not _MISSING:
        state["metadata"] = {"exit": exit_code}
    row = {"type": "tool_use", "part": {"callID": call, "tool": name, "state": state}}
    return json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n"

def fake_opencode(lines, delay=0, exit_code=0):
    bindir = tmp / "opencode-bin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "opencode"
    script.write_text(
        "#!/usr/bin/env python3\n"
        "import json,os,pathlib,sys,time\n"
        "p=os.environ.get('FAKE_COUNT')\n"
        "open(p,'a').write('1\\n') if p else None\n"
        f"lines={lines!r}\n"
        "for line in lines:\n print(line, flush=True)\n"
        "args=sys.argv[1:]\n"
        "if os.environ.get('FAKE_ARGV'):\n"
        " pathlib.Path(os.environ['FAKE_ARGV']).write_text(json.dumps(args))\n"
        "if os.environ.get('FAKE_ENV'):\n"
        " pathlib.Path(os.environ['FAKE_ENV']).write_text(json.dumps({k:os.environ.get(k) for k in ('AGENT_START_STAGGER','AGENT_LOCK_RETRIES','OPENCODE_CONFIG_CONTENT')}))\n"
        f"time.sleep({delay})\nsys.exit({exit_code})\n")
    script.chmod(0o755)
    return bindir

def opencode_parser_boundaries():
    spec = importlib.util.spec_from_file_location(
        "opencode_events", root / "scripts/engines/opencode/events.py")
    parser = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(parser)
    path = tmp / "opencode-events.jsonl"
    body = opencode_event("tool_execution_start", "pending") + \
           opencode_event("tool_execution_end", "a", args={"path": "/one"}) + \
           opencode_event("tool_execution_end", "b", name="skill", ok=False,
                          args={"path": "/two"}) + \
           opencode_event("tool_execution_end", "c", name="bash",
                          args={"command": "x" * 100}, exit_code=2) + \
           opencode_event("tool_execution_end", "d", name="bash", exit_code=0) + \
           opencode_event("tool_execution_end", "e", name="bash", exit_code=None) + \
           "{malformed}\n"
    path.write_text(body + opencode_event("tool_execution_end", "half").rstrip())
    rows, offset = parser.scan_tools(path, 0)
    assert [row["name"] for row in rows] == ["read", "skill", "bash", "bash", "bash"]
    assert [row["ok"] for row in rows] == [True, False, False, True, True]
    assert "/one" in rows[0]["args_head"] and "/two" in rows[1]["args_head"]
    assert all(len(row["args_head"]) <= 80 for row in rows)
    assert offset == len(body.encode())
    rows2, offset2 = parser.scan_tools(path, offset)
    assert rows2 == [] and offset2 == offset
    with path.open("a") as output:
        output.write("\n")
    rows2, offset2 = parser.scan_tools(path, offset)
    assert len(rows2) == 1 and offset2 == path.stat().st_size

def dispatch_fake(name, lines, *, delay=0, exit_code=0, max_tools=None, timeout=4):
    bindir = fake_omp(lines, delay, exit_code)
    run_dir = tmp / name
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}", "AGENT_START_STAGGER": "0",
                        "OMP_REGISTRY_DIR": str(tmp / f"{name}-registry")}
    cmd = [root / "scripts/agent.sh", "--engine", "omp", "--run-dir", run_dir, "--label", "w",
           "--prompt", "x", "--admission", "off", "--timeout", str(timeout)]
    if max_tools is not None:
        cmd += ["--max-tools", str(max_tools)]
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    return result, json.loads((run_dir / "agents/w/meta.json").read_text())

def parser_boundaries():
    path = tmp / "events.jsonl"
    body = event("tool_execution_start", "a", args={"path": "/one"}) + \
           event("tool_execution_start", "b", args={"path": "/two"}) + \
           event("tool_execution_end", "b", ok=False) + event("tool_execution_end", "a")
    path.write_text(body + event("tool_execution_end", "half").rstrip())
    rows, offset = scan_tools(path, 0)
    assert [r["ok"] for r in rows] == [False, True]
    assert "/two" in rows[0]["args_head"] and "/one" in rows[1]["args_head"]
    assert all(len(r["args_head"]) <= 80 for r in rows)
    assert offset == len(body.encode())
    rows2, offset2 = scan_tools(path, offset)
    assert rows2 == [] and offset2 == offset
    with path.open("a") as out:
        out.write("\n")
    rows2, offset2 = scan_tools(path, offset)
    assert len(rows2) == 1 and offset2 == path.stat().st_size
    whole, whole_offset = scan_tools(path, 0)
    assert whole == rows + rows2 and whole_offset == offset2

def wrapper_counts():
    lines = [event("tool_execution_start", "a", args={"path": "/x"}).strip(),
             event("tool_execution_end", "a").strip(),
             event("tool_execution_end", "b", ok=False).strip()]
    result, meta = dispatch_fake("agent-run", lines, timeout=2)
    assert result.returncode == 0, result.stderr
    assert meta["tool_calls"] == 1 and meta["failed_commands"] == 1

def watch_incremental_identity():
    run_dir = tmp / "watch-run"
    agent = run_dir / "agents/w"
    agent.mkdir(parents=True)
    events = agent / "events.jsonl"
    events.write_text(event("tool_execution_end", "a", name="x" * 500))
    started_at = int(time.time())
    (agent / "started.json").write_text(json.dumps(
        {"started_at": started_at, "deadline": started_at + 1000, "timeout_s": 1000}))
    cmd = [root / "scripts/watch.sh", run_dir, "--timeout", "0", "--interval", "1",
           "--reflect-tools", "999", "--reflect-min", "999999"]
    for expected in (1, 1):
        result = subprocess.run(cmd, capture_output=True, text=True)
        assert result.returncode == expected, result.stderr
    state = json.loads((run_dir / ".watch-state").read_text())
    first = state["w#tools"]
    assert first["count"] == 1 and first["offset"] == events.stat().st_size
    events.write_text(event("tool_execution_end", "b") + event("tool_execution_end", "c"))
    subprocess.run(cmd, capture_output=True)
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#tools"]["count"] == 2
    (agent / "started.json").write_text(json.dumps(
        {"started_at": 11, "deadline": int(time.time()) + 1000, "timeout_s": 1000}))
    subprocess.run(cmd, capture_output=True)
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#tools"]["started_at"] == 11 and state["w#tools"]["count"] == 2

def make_watch(name, successes, failures=0, age=0, deadline=2000, label="w"):
    run_dir = tmp / name
    agent = run_dir / f"agents/{label}"
    agent.mkdir(parents=True)
    rows = [event("tool_execution_end", f"s{i}") for i in range(successes)]
    rows += [event("tool_execution_end", f"f{i}", ok=False) for i in range(failures)]
    (agent / "events.jsonl").write_text("".join(rows))
    now = int(time.time())
    (agent / "started.json").write_text(json.dumps(
        {"started_at": now - age, "deadline": now + deadline, "timeout_s": age + deadline}))
    return run_dir

def poll_watch(run_dir, tools=100, minutes=45, state=None):
    command = [root / "scripts/watch.sh", run_dir, "--timeout", "0", "--interval", "1",
               "--reflect-tools", str(tools), "--reflect-min", str(minutes)]
    if state is not None:
        command += ["--state", state]
    return subprocess.run(command, capture_output=True, text=True)

def reflect_threshold_and_dedup():
    run_dir = make_watch("threshold-run", 99, failures=5)
    first = poll_watch(run_dir)
    assert first.returncode == 1 and "REFLECT" not in first.stdout
    with (run_dir / "agents/w/events.jsonl").open("a") as out:
        out.write(event("tool_execution_end", "hundred"))
    second = poll_watch(run_dir)
    assert second.returncode == 0 and second.stdout.count("REFLECT 1") == 1
    third = poll_watch(run_dir)
    assert third.returncode == 1 and "REFLECT" not in third.stdout
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["pending"] is True
    with (run_dir / "agents/w/events.jsonl").open("a") as out:
        out.write("".join(event("tool_execution_end", f"later{i}") for i in range(100)))
    fourth = poll_watch(run_dir)
    assert fourth.returncode == 1 and "REFLECT" not in fourth.stdout

def reflect_single_and_deadline():
    both = make_watch("both-run", 100, age=3600)
    result = poll_watch(both)
    assert result.returncode == 0 and result.stdout.count("REFLECT") == 1
    elapsed = make_watch("elapsed run", 0, age=3600, label="w;echo bad")
    custom_state = tmp / "custom state"
    result = poll_watch(elapsed, state=custom_state)
    advertised = result.stdout.split("— ", 1)[1].strip()
    assert shlex.split(advertised) == [
        str(root / "scripts/reflect.sh"), str(elapsed), "w;echo bad",
        "--trigger", "elapsed", "--state", str(custom_state)]
    late = make_watch("late-run", 100, age=3600, deadline=599)
    result = poll_watch(late)
    assert "REFLECT" not in result.stdout

def reflect_identity_reset():
    run_dir = make_watch("identity-run", 2)
    poll_watch(run_dir, tools=1)
    state_path = run_dir / ".watch-state"
    state = json.loads(state_path.read_text())
    state["w#reflect"]["n"] = 7
    state_path.write_text(json.dumps(state))
    started = json.loads((run_dir / "agents/w/started.json").read_text())
    started["started_at"] += 1
    (run_dir / "agents/w/started.json").write_text(json.dumps(started))
    poll_watch(run_dir, tools=999, minutes=999)
    state = json.loads(state_path.read_text())
    assert state["w#reflect"] == {
        "n": 7, "base_count": 0, "base_at": started["started_at"], "pending": False}

def max_tools_slow():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    result, meta = dispatch_fake("budget-slow", lines, delay=20, max_tools=10, timeout=30)
    assert result.returncode == 66
    assert meta["over_budget"] is True and meta["tool_calls"] == 11

def max_tools_fast():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    result, meta = dispatch_fake("budget-fast", lines, max_tools=10)
    assert result.returncode == 66 and meta["over_budget"] is True

def max_tools_exact():
    lines = [event("tool_execution_end", str(i)).strip() for i in range(10)]
    result, meta = dispatch_fake("budget-exact", lines, max_tools=10)
    assert result.returncode == 0 and meta["over_budget"] is False

def answer(value):
    return json.dumps({"type": "message_end", "message": {"role": "assistant",
        "content": [{"type": "text", "text": value}]}})
def reflect_run(name, value, *, extra_events=(), env_extra=None, dry=False, exit_code=0,
                delay=0, mutate=None, prepare=None, trigger=None):
    run_dir = tmp / name
    worker = run_dir / "agents/w"
    worker.mkdir(parents=True, exist_ok=True)
    work = tmp / f"{name}-work"
    work.mkdir(exist_ok=True)
    (worker / "prompt.md").write_text("SPEC SENTENCE\n")
    (worker / "NOTES.md").write_text("# Live notes\nNOTE SENTENCE\n")
    (run_dir / "maintainer.md").write_text("STOP HERE\n")
    rows = event("tool_execution_end", "worker")
    (worker / "events.jsonl").write_text(rows)
    now = int(time.time())
    (worker / "started.json").write_text(json.dumps(
        {"started_at": now, "cwd": str(work), "deadline": now + 1000, "timeout_s": 1000}))
    state = {"w#tools": {"started_at": now, "offset": len(rows.encode()), "count": 1},
             "w#reflect": {"n": 0, "base_count": 0, "base_at": now, "pending": True}}
    (run_dir / ".watch-state").write_text(json.dumps(state))
    if prepare:
        prepare(run_dir, worker)
    lines = list(extra_events)
    if value is not None:
        lines.append(answer(value))
    bindir = fake_omp(lines, delay=delay, exit_code=exit_code)
    if (env_extra or {}).get("FAKE_TIMEOUT"):
        timeout = bindir / "timeout"
        timeout.write_text("#!/usr/bin/env python3\nimport subprocess,sys\n"
            "a=sys.argv[1:]\nwhile a and a[0].startswith('--'): a.pop(0)\n"
            "a.pop(0)\ntry: subprocess.run(a,timeout=.5); sys.exit(0)\n"
            "except subprocess.TimeoutExpired: sys.exit(124)\n")
        timeout.chmod(0o755)
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
                        "OMP_REGISTRY_DIR": str(tmp / f"{name}-registry"),
                        "AGENT_SLOTS_DIR": str(tmp / f"{name}-slots"),
                        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env")}
    env.update(env_extra or {})
    cmd = [root / "scripts/reflect.sh", run_dir, "w"]
    if trigger:
        cmd += ["--trigger", trigger]
    if dry:
        cmd.append("--dry-run")
    thread = threading.Thread(target=mutate) if mutate else None
    if thread:
        thread.start()
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if thread:
        thread.join()
    return run_dir, result, state

def valid_no_issue():
    value = "```json\n" + json.dumps({"verdict": "NO_ISSUE",
        "reason": "The route matches."}) + "\n```"
    run_dir, result, _ = reflect_run("reflect-ok", value)
    assert result.returncode == 0, result.stderr
    report = json.loads((run_dir / "agents/w/reflect-1.json").read_text())
    assert report["verdict"] == "NO_ISSUE" and report["tools_at_check"] == 1
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["n"] == 1 and state["w#reflect"]["pending"] is False
    assert state["w#reflect"]["base_count"] == 1

def valid_route():
    value = json.dumps({"verdict": "ROUTE_CORRECTION", "reason": "A stop was bypassed.",
        "next_step": "Stop and report.", "quotes": [{"source": "maintainer.md",
        "text": "STOP HERE"}]})
    run_dir, result, _ = reflect_run("reflect-route", value, trigger="maintainer")
    assert result.returncode == 0 and "Stop and report." in result.stdout
    assert json.loads((run_dir / "agents/w/reflect-1.json").read_text())["trigger"] == "maintainer"
    assert (run_dir / "agents/w/NOTES.md").read_text() == "# Live notes\nNOTE SENTENCE\n"

def valid_route_singular_quote():
    value = json.dumps({"verdict": "ROUTE_CORRECTION", "reason": "A stop was bypassed.",
        "next_step": "Stop and report.", "quote": {"source": "maintainer.md",
        "text": "STOP HERE"}})
    run_dir, result, _ = reflect_run("reflect-route-singular", value, trigger="maintainer")
    assert result.returncode == 0
    report = json.loads((run_dir / "agents/w/reflect-1.json").read_text())
    assert report["quotes"] == [{"source": "maintainer.md", "text": "STOP HERE"}] and "quote" not in report

def valid_cannot_judge():
    value = json.dumps({"verdict": "CANNOT_JUDGE", "reason": "No maintainer quote applies."})
    run_dir, result, _ = reflect_run("reflect-cannot", value)
    assert result.returncode == 0
    assert json.loads((run_dir / "agents/w/reflect-1.json").read_text())["verdict"] == "CANNOT_JUDGE"

def invalid_result(name, obj):
    run_dir, result, _ = reflect_run(f"reflect-invalid-{name}", json.dumps(obj))
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()
    assert not (run_dir / "agents/w/reflect-1.json").exists()

def empty_result():
    run_dir, result, _ = reflect_run("reflect-empty", None)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def failed_reflector():
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run("reflect-exit", value, exit_code=1)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()
    assert (run_dir / "reflect/w-1/agents/reflector/meta.json").exists()

def dry_run_prompt():
    def prepare(_, worker):
        rows = []
        for i in range(45):
            rows += [event("tool_execution_start", f"d{i}", args={"index": i}),
                     event("tool_execution_end", f"d{i}", ok=i != 6)]
        (worker / "events.jsonl").write_text("".join(rows))
        (worker / "reflect-7.json").write_text(json.dumps(
            {"verdict": "NO_ISSUE", "reason": "history"}))
    run_dir, _, state = reflect_run("reflect-dry", json.dumps(
        {"verdict": "NO_ISSUE", "reason": "x"}), dry=True, prepare=prepare)
    prompt = (run_dir / "agents/w/reflect-8.prompt.md").read_text()
    heads = [prompt.index(x) for x in ("## prompt.md", "## maintainer.md", "## NOTES.md",
                                      "## Tool summary")]
    summary = prompt.split("## Tool summary", 1)[1].split("## Previous reflection", 1)[0]
    assert heads == sorted(heads) and summary.count("\n- ") == 40
    assert '"index":5' in summary and "error" in summary and "Historical" in prompt
    assert json.loads((run_dir / ".watch-state").read_text()) == state
    assert not (run_dir / "reflect").exists()

def admission_preserves_pending():
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, state = reflect_run("reflect-full", value, env_extra={"OMP_MAX_AGENTS": "0"})
    assert result.returncode == 3
    assert json.loads((run_dir / ".watch-state").read_text()) == state
    assert not (run_dir / "agents/w/reflect-1.error").exists()

def over_budget_is_error():
    tools = [event("tool_execution_end", str(i)).strip() for i in range(11)]
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run("reflect-budget", value, extra_events=tools)
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def lock_and_numbering():
    lock = tmp / "reflect-lock/agents/w/.reflect.lock"
    lock.parent.mkdir(parents=True)
    with lock.open("w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        _, result, state = reflect_run("reflect-lock", json.dumps(
            {"verdict": "NO_ISSUE", "reason": "x"}))
        assert result.returncode == 2
        assert json.loads((tmp / "reflect-lock/.watch-state").read_text()) == state
    run_dir, result, _ = reflect_run("reflect-lock", None)
    assert result.returncode != 2 and (run_dir / "agents/w/reflect-1.error").exists()
    run_dir, result, _ = reflect_run("reflect-lock", None)
    assert result.returncode != 2 and (run_dir / "agents/w/reflect-2.error").exists()

def completion_uses_current_count():
    name = "reflect-current"
    def mutate():
        time.sleep(1)
        with (tmp / name / "agents/w/events.jsonl").open("a") as out:
            out.write("".join(event("tool_execution_end", f"new{i}") for i in range(100)))
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run(name, value, delay=3, mutate=mutate)
    assert result.returncode == 0
    state = json.loads((run_dir / ".watch-state").read_text())
    assert state["w#reflect"]["base_count"] == 101
    assert "REFLECT" not in poll_watch(run_dir).stdout

def old_inquiry_preserves_new_identity():
    name = "reflect-identity"
    replacement = {}
    def mutate():
        time.sleep(1)
        started_path = tmp / name / "agents/w/started.json"
        started = json.loads(started_path.read_text())
        started["started_at"] += 10
        started_path.write_text(json.dumps(started))
        replacement.update({
            "w#tools": {"started_at": started["started_at"], "offset": 0, "count": 0},
            "w#reflect": {"n": 4, "base_count": 0, "base_at": started["started_at"],
                          "pending": False}})
        (tmp / name / ".watch-state").write_text(json.dumps(replacement))
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    run_dir, result, _ = reflect_run(name, value, delay=3, mutate=mutate)
    assert result.returncode == 0 and (run_dir / "agents/w/reflect-1.json").exists()
    assert json.loads((run_dir / ".watch-state").read_text()) == replacement

def timeout_does_not_redrive():
    count = tmp / "reflect-timeout-count"
    value = json.dumps({"verdict": "NO_ISSUE", "reason": "x"})
    start = time.time()
    run_dir, result, _ = reflect_run("reflect-timeout", value, delay=20,
        env_extra={"FAKE_TIMEOUT": "1", "FAKE_COUNT": str(count)})
    assert time.time() - start < 8 and count.read_text().splitlines() == ["1"]
    assert result.returncode != 0 and (run_dir / "agents/w/reflect-1.error").exists()

def status_fixture(name, running=False):
    run_dir = tmp / name
    agent = run_dir / "agents/w"
    agent.mkdir(parents=True)
    if running:
        (agent / "events.jsonl").write_text(event("tool_execution_end", "a"))
        now = int(time.time())
        (agent / "started.json").write_text(json.dumps(
            {"started_at": now, "deadline": now + 1000, "timeout_s": 1000}))
        (run_dir / ".watch-state").write_text(json.dumps({
            "w#tools": {"started_at": now, "offset": 0, "count": 12},
            "w#reflect": {"n": 3, "base_count": 0, "base_at": now, "pending": True}}))
    else:
        (agent / "meta.json").write_text(json.dumps(
            {"label": "w", "exit_code": 0, "duration_s": 1, "usage": {},
             "thread_id": "t", "result_file": None}))
        (agent / "reflect-1.json").write_text(json.dumps(
            {"verdict": "NO_ISSUE", "reason": "x"}))
        (agent / "reflect-2.error").write_text("invalid result\n")
    return run_dir

def status_running_state():
    result = subprocess.run([root / "scripts/status.sh",
        status_fixture("status-running", True), "--brief"], capture_output=True, text=True)
    assert result.returncode == 0 and "tools=12 reflect=3[pending]" in result.stdout

def status_finished_reports():
    run_dir = status_fixture("status-finished")
    for flag in ("--brief", "--full"):
        result = subprocess.run([root / "scripts/status.sh", run_dir, flag],
                                capture_output=True, text=True)
        assert "reflect: 1 NO_ISSUE, 2 error" in result.stdout

def nested_runs_stay_isolated():
    run_dir = status_fixture("parent-isolation")
    nested = run_dir / "reflect/w-1/agents/reflector"
    nested.mkdir(parents=True)
    (nested / "meta.json").write_text(json.dumps(
        {"exit_code": 0, "worktree_branch": "omp/child"}))
    wait = subprocess.run([root / "scripts/wait.sh", run_dir, "--timeout", "0"],
                          capture_output=True, text=True)
    assert wait.stdout.strip() == "w OK"
    parent_meta = run_dir / "agents/w/meta.json"
    meta = json.loads(parent_meta.read_text())
    meta.update({"worktree_branch": "omp/parent", "base_sha": "", "cwd": str(tmp)})
    parent_meta.write_text(json.dumps(meta))
    bindir = tmp / "fake-git"
    bindir.mkdir()
    git = bindir / "git"
    git.write_text("#!/bin/sh\ncase \"$*\" in\n"
        "*'rev-parse --git-dir'*) echo .git;;\n"
        "*'rev-parse --abbrev-ref HEAD'*) echo main;;\n"
        "*'rev-parse HEAD'*) echo abc;;\n"
        "esac\nexit 0\n")
    git.chmod(0o755)
    merge = subprocess.run([root / "scripts/merge.sh", "--run-dir", run_dir,
        "--repo", tmp, "--into", "main", "--dry-run"],
        env=os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}"},
        capture_output=True, text=True)
    assert merge.returncode == 0 and "integrating 1 branch" in merge.stderr

def new_run_prompts_for_maintainer_words():
    base = tmp / "new-runs"
    result = subprocess.run([root / "scripts/new_run.sh", "probe"],
        env=os.environ | {"OMP_RUNS_DIR": str(base)}, capture_output=True, text=True)
    assert result.returncode == 0
    assert "maintainer.md" in (pathlib.Path(result.stdout.strip()) / "PLAN.md").read_text()

def adapter_argv_passthrough():
    adapter = root / "scripts/engines/codex/agent.sh"
    original = adapter.read_bytes()
    try:
        adapter.write_text("#!/usr/bin/env python3\nimport json,os,pathlib,sys\n"
                           "pathlib.Path(os.environ['ARGV_OUT']).write_text(json.dumps(sys.argv[1:]))\n")
        adapter.chmod(0o755)
        output = tmp / "adapter-argv.json"
        args = ["--label", "literal value", "--resume", "thread/one", "--network"]
        result = subprocess.run([root / "scripts/agent.sh", "--engine", "codex", *args],
                                env=os.environ | {"ARGV_OUT": str(output)}, capture_output=True)
        assert result.returncode == 0 and json.loads(output.read_text()) == args
    finally:
        adapter.write_bytes(original)
        adapter.chmod(0o755)

def opencode_adapter_argv_passthrough():
    adapter = root / "scripts/engines/opencode/agent.sh"
    original = adapter.read_bytes()
    try:
        adapter.write_text("#!/usr/bin/env python3\nimport json,os,pathlib,sys\n"
                           "pathlib.Path(os.environ['ARGV_OUT']).write_text(json.dumps(sys.argv[1:]))\n")
        adapter.chmod(0o755)
        output = tmp / "opencode-adapter-argv.json"
        args = ["--label", "literal value", "--resume", "session/one", "--network"]
        result = subprocess.run([root / "scripts/agent.sh", "--engine", "opencode", *args],
                                env=os.environ | {"ARGV_OUT": str(output)}, capture_output=True)
        assert result.returncode == 0 and json.loads(output.read_text()) == args
    finally:
        adapter.write_bytes(original)
        adapter.chmod(0o755)

def codex_wrapper_and_output():
    lines = [codex_completed("command_execution", "ok", command="inspect",
                             exit_code=0, status="completed").strip(),
             codex_completed("command_execution", "bad", command="retry",
                             exit_code=2, status="completed").strip(),
             codex_completed("agent_message", "answer", text="READY").strip()]
    bindir = fake_codex(lines)
    run_dir = tmp / "codex-wrapper"
    argv = tmp / "codex-argv.json"
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
                        "AGENT_START_STAGGER": "0", "AGENT_LOCK_RETRIES": "1",
                        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env"),
                        "CODEX_REGISTRY_DIR": str(tmp / "codex-wrapper-registry"),
                        "FAKE_ARGV": str(argv)}
    result = subprocess.run([root / "scripts/agent.sh", "--engine", "codex",
        "--run-dir", run_dir, "--label", "w", "--prompt", "x", "--admission", "off",
        "--timeout", "4"], env=env, capture_output=True, text=True)
    meta = json.loads((run_dir / "agents/w/meta.json").read_text())
    started = json.loads((run_dir / "agents/w/started.json").read_text())
    assert result.returncode == 0, result.stderr
    assert meta["engine"] == started["engine"] == "codex"
    assert meta["tool_calls"] == 1 and meta["failed_commands"] == 1
    assert (run_dir / "agents/w/last.txt").read_text().strip() == "READY"
    assert "-o" in json.loads(argv.read_text())

def opencode_wrapper_and_output():
    lines = [
        opencode_event("tool_execution_end", "ok", name="read").strip(),
        opencode_event("tool_execution_end", "bad", name="bash", exit_code=2).strip(),
        json.dumps({"type": "text", "sessionID": "session-one",
                    "part": {"text": "READY"}}, separators=(",", ":"))]
    bindir = fake_opencode(lines)
    run_dir = tmp / "opencode-wrapper"
    argv = tmp / "opencode-argv.json"
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
                        "AGENT_START_STAGGER": "0", "AGENT_LOCK_RETRIES": "1",
                        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env"),
                        "OPENCODE_REGISTRY_DIR": str(tmp / "opencode-wrapper-registry"),
                        "FAKE_ARGV": str(argv)}
    result = subprocess.run([root / "scripts/agent.sh", "--engine", "opencode",
        "--run-dir", run_dir, "--label", "w", "--prompt", "x", "--admission", "off",
        "--timeout", "4"], env=env, capture_output=True, text=True)
    meta = json.loads((run_dir / "agents/w/meta.json").read_text())
    started = json.loads((run_dir / "agents/w/started.json").read_text())
    args = json.loads(argv.read_text())
    assert result.returncode == 0, result.stderr
    assert meta["engine"] == started["engine"] == "opencode"
    assert meta["tool_calls"] == 1 and meta["failed_commands"] == 1
    assert meta["thread_id"] == "session-one"
    assert (run_dir / "agents/w/last.txt").read_text().strip() == "READY"
    assert args[:4] == ["run", "--format", "json", "--dir"]

def mixed_parser_selection():
    run_dir = tmp / f"mixed-parser-{phase}"
    now = int(time.time())
    rows = {
        "as-omp": ("omp", event("tool_execution_end", "one")),
        "as-codex": ("codex", codex_completed(
            "command_execution", "one", command="inspect", exit_code=0, status="completed")),
        "as-opencode": ("opencode", opencode_event("tool_execution_end", "one")),
    }
    for label, (engine, row) in rows.items():
        worker = run_dir / f"agents/{label}"
        worker.mkdir(parents=True)
        (worker / "events.jsonl").write_text(row)
        (worker / "started.json").write_text(json.dumps({"engine": engine,
            "started_at": now, "deadline": now + 1000, "timeout_s": 1000}))
    result = subprocess.run([root / "scripts/watch.sh", run_dir, "--timeout", "0",
        "--reflect-tools", "999", "--reflect-min", "999999"], capture_output=True, text=True)
    state = json.loads((run_dir / ".watch-state").read_text())
    assert result.returncode == 1
    assert all(state[f"{label}#tools"]["count"] == 1 for label in rows)

def codex_reflector_uses_worker_policy():
    run_dir = tmp / "codex-reflect"
    worker = run_dir / "agents/w"
    work = tmp / "codex-reflect-work"
    worker.mkdir(parents=True); work.mkdir()
    now = int(time.time())
    (worker / "prompt.md").write_text("SPEC\n")
    (worker / "NOTES.md").write_text("# Live notes\n")
    (run_dir / "maintainer.md").write_text("MAINTAINER\n")
    (worker / "events.jsonl").write_text(codex_completed(
        "command_execution", "one", command="inspect", exit_code=0, status="completed"))
    (worker / "started.json").write_text(json.dumps({"engine": "codex", "started_at": now,
        "cwd": str(work), "deadline": now + 1000, "timeout_s": 1000}))
    answer = json.dumps({"verdict": "NO_ISSUE", "reason": "The route matches."})
    lines = [codex_completed("agent_message", "answer", text=answer).strip()]
    bindir = fake_codex(lines)
    argv, environment = tmp / "reflect-codex-argv.json", tmp / "reflect-codex-env.json"
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
        "FAKE_ARGV": str(argv), "FAKE_ENV": str(environment),
        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env"),
        "CODEX_REGISTRY_DIR": str(tmp / "codex-reflect-registry"),
        "AGENT_SLOTS_DIR": str(tmp / "codex-reflect-slots")}
    result = subprocess.run([root / "scripts/reflect.sh", run_dir, "w"], env=env,
                            capture_output=True, text=True)
    args = json.loads(argv.read_text())
    seen_env = json.loads(environment.read_text())
    assert result.returncode == 0, result.stderr
    assert args[args.index("-s") + 1] == "read-only"
    assert args.count("--add-dir") == 2
    assert seen_env == {"AGENT_START_STAGGER": "0", "AGENT_LOCK_RETRIES": "1"}
    assert json.loads((worker / "reflect-1.json").read_text())["verdict"] == "NO_ISSUE"

def opencode_reflector_uses_worker_policy():
    run_dir = tmp / "opencode-reflect"
    worker = run_dir / "agents/w"
    work = tmp / "opencode-reflect-work"
    worker.mkdir(parents=True); work.mkdir()
    now = int(time.time())
    (worker / "prompt.md").write_text("SPEC\n")
    (worker / "NOTES.md").write_text("# Live notes\n")
    (run_dir / "maintainer.md").write_text("MAINTAINER\n")
    (worker / "events.jsonl").write_text(
        opencode_event("tool_execution_end", "one", name="read"))
    (worker / "started.json").write_text(json.dumps({"engine": "opencode", "started_at": now,
        "cwd": str(work), "deadline": now + 1000, "timeout_s": 1000}))
    answer = json.dumps({"verdict": "NO_ISSUE", "reason": "The route matches."})
    lines = [json.dumps({"type": "text", "sessionID": "reflection",
                        "part": {"text": answer}}, separators=(",", ":"))]
    bindir = fake_opencode(lines)
    argv, environment = tmp / "reflect-opencode-argv.json", tmp / "reflect-opencode-env.json"
    env = os.environ | {"PATH": f"{bindir}:{os.environ['PATH']}",
        "FAKE_ARGV": str(argv), "FAKE_ENV": str(environment),
        "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env"),
        "OPENCODE_REGISTRY_DIR": str(tmp / "opencode-reflect-registry"),
        "AGENT_SLOTS_DIR": str(tmp / "opencode-reflect-slots")}
    result = subprocess.run([root / "scripts/reflect.sh", run_dir, "w"], env=env,
                            capture_output=True, text=True)
    args = json.loads(argv.read_text())
    seen_env = json.loads(environment.read_text())
    config = json.loads(seen_env.pop("OPENCODE_CONFIG_CONTENT"))
    assert result.returncode == 0, result.stderr
    assert "--add-dir" not in args
    assert args[args.index("--agent") + 1] == "plan"
    assert config["permission"]["external_directory"] == "allow"
    assert seen_env == {"AGENT_START_STAGGER": "0", "AGENT_LOCK_RETRIES": "1"}
    assert json.loads((worker / "reflect-1.json").read_text())["verdict"] == "NO_ISSUE"

def codex_capacity_uses_shared_limit():
    agents = root / "scripts/agents.sh"
    original = agents.read_bytes()
    try:
        agents.write_text("#!/bin/sh\ncase \"$*\" in *codex*) echo 2;; *opencode*) echo 1;; *) echo 0;; esac\n")
        agents.chmod(0o755)
        result = subprocess.run([root / "scripts/capacity.sh", "--engine", "codex", "light"],
            env=os.environ | {"AGENT_MAX_AGENTS": "3", "CODEX_MAX_AGENTS": "99",
                              "AGENT_CONCURRENCY_CEILING": "99",
                              "AGENT_ORCHESTRATION_ENV": str(tmp / "no-agent-env")},
            capture_output=True, text=True)
        assert result.returncode == 0 and result.stdout.strip() == "0"
        assert "running=3/3" in result.stderr and "AGENT_MAX_AGENTS=3" in result.stderr
    finally:
        agents.write_bytes(original)
        agents.chmod(0o755)

def invalid_engine_field():
    cases = [
        ({"label": "x", "engine": "codex", "permission": "read-only"},
         "permission", "codex"),
        ({"label": "x", "engine": "opencode", "sandbox": "read-only"},
         "sandbox", "opencode"),
    ]
    for index, (job, field, engine) in enumerate(cases):
        jobs = tmp / f"invalid-jobs-{index}.jsonl"
        jobs.write_text(json.dumps(job) + "\n")
        result = subprocess.run([root / "scripts/dispatch.sh", "--engine", "omp",
            "--run-dir", tmp / f"invalid-run-{index}", "--jobs", jobs, "--dry-run"],
            capture_output=True, text=True)
        assert result.returncode == 2
        assert field in result.stderr and engine in result.stderr

def live_codex_worktree_is_protected():
    repo = tmp / "worktree-repo"
    run_dir = tmp / "worktree-run"
    worktree = run_dir / "worktrees/custom-name"
    repo.mkdir()
    def git(*args, cwd=repo):
        return subprocess.run(["git", *args], cwd=cwd, check=True,
                              capture_output=True, text=True).stdout.strip()
    git("init", "-b", "main")
    git("config", "user.name", "Control")
    git("config", "user.email", "control@example.invalid")
    git("config", "commit.gpgsign", "false")
    (repo / "base.txt").write_text("base\n")
    git("add", "base.txt"); git("commit", "-m", "base")
    worktree.parent.mkdir(parents=True)
    git("worktree", "add", "-b", "codex/live", str(worktree), "HEAD")
    before = git("rev-parse", "codex/live")
    (repo / "main.txt").write_text("advance\n")
    git("add", "main.txt"); git("commit", "-m", "advance")
    registry = tmp / "nonstandard-live-codex-registry"
    registry.mkdir(parents=True)
    stat = pathlib.Path(f"/proc/{os.getpid()}/stat").read_text()
    ticks = int(stat[stat.rindex(") ") + 2:].split()[19])
    (registry / f"{os.getpid()}.json").write_text(json.dumps({"pid": os.getpid(),
        "start_ticks": ticks, "cwd": str(worktree), "label": "live", "run_dir": str(run_dir)}))
    result = subprocess.run([root / "scripts/worktrees.sh", run_dir, "--rebase", "main"],
        env=os.environ | {"CODEX_REGISTRY_DIR": str(registry),
                          "OMP_REGISTRY_DIR": str(tmp / "nonstandard-empty-omp-registry"),
                          "OPENCODE_REGISTRY_DIR": str(tmp / "nonstandard-empty-opencode-registry")},
        capture_output=True, text=True)
    assert result.returncode == 0 and "codex/live" in result.stdout and "SKIPPED" in result.stdout
    assert git("rev-parse", "codex/live") == before

def manual_worker_uses_process_cwd():
    cwd = tmp / "manual-worker-cwd"
    cwd.mkdir()
    (cwd / "exec").write_text("")
    worker = subprocess.Popen(["bash", "-c", "exec -a codex tail -f exec"], cwd=cwd,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(.2)
        result = subprocess.run([root / "scripts/agents.sh", "--cwd-live", cwd],
            env=os.environ | {"OMP_REGISTRY_DIR": str(tmp / "manual-empty-omp"),
                              "CODEX_REGISTRY_DIR": str(tmp / "manual-empty-codex"),
                              "OPENCODE_REGISTRY_DIR": str(tmp / "manual-empty-opencode")},
            capture_output=True, text=True)
        assert result.returncode == 0 and result.stdout.strip() == "yes", result.stderr
    finally:
        worker.terminate()
        worker.wait(timeout=2)

def mixed_dispatch_preserves_engine_lane():
    order_file = tmp / "mixed-dispatch-order"
    capacity = root / "scripts/capacity.sh"
    omp_adapter = root / "scripts/engines/omp/agent.sh"
    codex_adapter = root / "scripts/engines/codex/agent.sh"
    originals = {path: path.read_bytes() for path in (capacity, omp_adapter, codex_adapter)}
    try:
        capacity.write_text(
            "#!/bin/sh\ncase \"$*\" in *codex*|*opencode*) echo 0;; *) echo 5;; esac\n")
        codex_adapter.write_text(
            "#!/bin/sh\nsleep 1\nprintf 'codex-done\\n' >> \"$ORDER_FILE\"\n")
        omp_adapter.write_text("#!/bin/sh\nprintf 'omp-start\\n' >> \"$ORDER_FILE\"\n")
        for path in originals:
            path.chmod(0o755)
        jobs = tmp / "mixed-dispatch.jsonl"
        rows = [{"label": f"codex-{index}", "engine": "codex"} for index in range(5)]
        rows.append({"label": "omp-independent", "engine": "omp"})
        jobs.write_text("".join(json.dumps(row) + "\n" for row in rows))
        result = subprocess.run([root / "scripts/dispatch.sh", "--engine", "omp",
            "--run-dir", tmp / "mixed-dispatch-run", "--jobs", jobs],
            env=os.environ | {"ORDER_FILE": str(order_file)},
            capture_output=True, text=True, timeout=15)
        order = order_file.read_text().splitlines()
        assert result.returncode == 0, result.stderr
        assert order.index("omp-start") < order.index("codex-done"), order
    finally:
        for path, body in originals.items():
            path.write_bytes(body)
            path.chmod(0o755)


phase = sys.argv[2]
if phase == "events":
    run("event parser preserves partial lines and correlates arguments", parser_boundaries)
    run("agent meta counts completed tools", wrapper_counts)
    run("watch persists incremental counts and resets identity", watch_incremental_identity)
elif phase == "triggers":
    run("watch triggers once at one hundred successful tools", reflect_threshold_and_dedup)
    run("watch coalesces triggers and skips the final ten minutes", reflect_single_and_deadline)
    run("watch resets reflection state on worker identity change", reflect_identity_reset)
elif phase == "budget":
    run("max-tools kills a slow eleventh completion without stall", max_tools_slow)
    run("max-tools rejects a fast over-budget result", max_tools_fast)
    run("max-tools accepts exactly ten completions", max_tools_exact)
elif phase == "reflect":
    run("reflect accepts fenced NO_ISSUE", valid_no_issue)
    run("reflect accepts source-bound ROUTE_CORRECTION", valid_route)
    run("reflect accepts a single quote under the singular key", valid_route_singular_quote)
    run("reflect accepts CANNOT_JUDGE", valid_cannot_judge)
    run("reflect rejects a missing verdict", lambda: invalid_result("missing", {}))
    run("reflect rejects an absent quote", lambda: invalid_result("badquote",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "ABSENT"}]}))
    run("reflect rejects an empty quote", lambda: invalid_result("emptyquote",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "   "}]}))
    run("reflect rejects source misuse", lambda: invalid_result("misuse",
        {"verdict": "ROUTE_CORRECTION", "reason": "x", "next_step": "y",
         "quotes": [{"source": "maintainer.md", "text": "SPEC SENTENCE"}]}))
    run("reflect rejects a missing next_step", lambda: invalid_result("next",
        {"verdict": "ROUTE_CORRECTION", "reason": "x",
         "quotes": [{"source": "maintainer.md", "text": "STOP HERE"}]}))
    run("reflect rejects empty output", empty_result)
    run("reflect records a failed reflector without redrive", failed_reflector)
    run("reflect dry-run preserves state and renders bounded sources", dry_run_prompt)
    run("reflect admission refusal preserves pending", admission_preserves_pending)
    run("reflect treats over-budget output as failure", over_budget_is_error)
    run("reflect lock releases and report numbers never overwrite", lock_and_numbering)
    run("reflect completion merges the current tool count", completion_uses_current_count)
    run("old reflection cannot update a new worker identity", old_inquiry_preserves_new_identity)
    run("reflect timeout launches only once", timeout_does_not_redrive)
elif phase == "status":
    run("status renders running reflection state", status_running_state)
    run("status renders finished reflection artifacts in brief and full modes",
        status_finished_reports)
    run("wait and merge ignore nested reflector runs", nested_runs_stay_isolated)
    run("new runs prompt for maintainer words", new_run_prompts_for_maintainer_words)
elif phase == "step3":
    run("agent entry preserves Codex adapter argv", adapter_argv_passthrough)
    run("Codex fake CLI handles output and event metadata", codex_wrapper_and_output)
    run("mixed run selects each worker event parser independently", mixed_parser_selection)
    run("Codex reflection preserves the worker engine policy", codex_reflector_uses_worker_policy)
    run("Codex capacity uses AGENT_MAX_AGENTS for the shared pool", codex_capacity_uses_shared_limit)
    run("engine-specific JSON field names the field and engine", invalid_engine_field)
    run("live Codex worktree is protected from rebase", live_codex_worktree_is_protected)
    run("mixed dispatch keeps an independent engine lane", mixed_dispatch_preserves_engine_lane)
    run("manual worker liveness uses the actual process cwd", manual_worker_uses_process_cwd)
elif phase == "step4":
    run("agent entry preserves OpenCode adapter argv", opencode_adapter_argv_passthrough)
    run("OpenCode event parser preserves terminal event semantics", opencode_parser_boundaries)
    run("OpenCode fake CLI handles output and event metadata", opencode_wrapper_and_output)
    run("three-engine run selects each worker event parser independently", mixed_parser_selection)
    run("OpenCode reflection uses read-only without add-dir", opencode_reflector_uses_worker_policy)
    run("wrong-engine JSON fields name the field and engine", invalid_engine_field)
else:
    raise SystemExit(f"unknown phase {phase}")
PY

if [ "${2:-}" = step3 ]; then
  fresh || exit 2
  expect 0 "step 3 engine controls" python3 "$TMP/event-controls.py" "$TMP/w" step3
  cat "$TMP/out"
  if [ "$fail" -ne 0 ]; then
    printf '%d passed, %d dead\n' "$pass" "$fail"
    exit 1
  fi
  printf '%d controls passed, none dead\n' "$pass"
  exit 0
fi
if [ "${2:-}" = step4 ]; then
  fresh || exit 2
  expect 0 "step 4 engine controls" python3 "$TMP/event-controls.py" "$TMP/w" step4
  cat "$TMP/out"
  if [ "$fail" -ne 0 ]; then
    printf '%d passed, %d dead\n' "$pass" "$fail"
    exit 1
  fi
  printf '%d controls passed, none dead\n' "$pass"
  exit 0
fi
# Confirm every contract mode is green first. If a baseline were red, none of the breaks below
# would establish anything.
fresh || exit 2
expect 0 "baseline entry contract" python3 scripts/check-contract.py entry \
  "$TMP/w/SKILL.md" "$TMP/w/README.md" "$TMP/w/README.zh-TW.md"
expect 0 "baseline engine contract" python3 scripts/check-contract.py engine "$ENGINE" \
  "$TMP/w/references/engines/omp.md"
expect 0 "baseline Codex engine contract" python3 scripts/check-contract.py engine codex \
  "$TMP/w/references/engines/codex.md"
expect 0 "baseline OpenCode engine contract" python3 scripts/check-contract.py engine opencode \
  "$TMP/w/references/engines/opencode.md"
expect 0 "baseline template contract" python3 scripts/check-contract.py template \
  "$TMP/w/references/prompt-template.md"
fresh || exit 2
expect 0 "reflection event controls" python3 "$TMP/event-controls.py" "$TMP/w" events
cat "$TMP/out"
fresh || exit 2
expect 0 "step 3 engine controls" python3 "$TMP/event-controls.py" "$TMP/w" step3
cat "$TMP/out"
fresh || exit 2
expect 0 "step 4 engine controls" python3 "$TMP/event-controls.py" "$TMP/w" step4
cat "$TMP/out"

# The description loses this engine's read-only boundary. That was the actual state of all
# three skills before this check existed.
fresh || exit 2
require_count 1 '`read-only` grants no `bash`' "$TMP/w/SKILL.md"
python3 - "$TMP/w/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "`read-only` grants no `bash`"
open(p, "w", encoding="utf-8").write(s.replace(old, "`read-only` grants no shell", 1))
PY
expect 1 "description without the boundary" python3 scripts/check-contract.py entry \
  "$TMP/w/SKILL.md" "$TMP/w/README.md" "$TMP/w/README.zh-TW.md"
fresh || exit 2
expect 0 "reflection trigger controls" python3 "$TMP/event-controls.py" "$TMP/w" triggers
cat "$TMP/out"

# The ladder drifts: deep falls from high to medium.
fresh || exit 2
page="$TMP/w/references/engines/omp.md"
require_count 1 '| `deep` | `high` | changes across several files, non-obvious bugs, refactors | 1800–3600 |' "$page"
sed -i 's/^| `deep` | `high` |/| `deep` | `medium` |/' "$page"
expect 1 "tier maps to the wrong effort" python3 scripts/check-contract.py engine "$ENGINE" "$page"
fresh || exit 2
expect 0 "reflection tool-budget controls" python3 "$TMP/event-controls.py" "$TMP/w" budget
cat "$TMP/out"

# A timeout drifts.
fresh || exit 2
page="$TMP/w/references/engines/omp.md"
require_count 1 '| `max` | `max` | one problem a `frontier` agent already failed twice | 3600–5400 |' "$page"
sed -i 's/^| `max` | `max` | one problem a `frontier` agent already failed twice | 3600–5400 |$/| `max` | `max` | one problem a `frontier` agent already failed twice | 3600–9999 |/' "$page"
expect 1 "timeout drift" python3 scripts/check-contract.py engine "$ENGINE" "$page"
fresh || exit 2
expect 0 "reflection inquiry controls" python3 "$TMP/event-controls.py" "$TMP/w" reflect
cat "$TMP/out"

# A whole tier disappears.
fresh || exit 2
page="$TMP/w/references/engines/omp.md"
require_count 1 '| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–5400 |' "$page"
sed -i '/^| `frontier` | `xhigh` | architecture, concurrency, performance, vague requirements | 3600–5400 |$/d' "$page"
expect 1 "a tier is missing" python3 scripts/check-contract.py engine "$ENGINE" "$page"
fresh || exit 2
expect 0 "reflection status controls" python3 "$TMP/event-controls.py" "$TMP/w" status
cat "$TMP/out"

# An access profile disappears.
fresh || exit 2
page="$TMP/w/references/engines/omp.md"
require_count 1 '| `workspace-write` | plus `write, edit, bash, ast_edit` | implementation |' "$page"
sed -i '/^| `workspace-write` | plus `write, edit, bash, ast_edit` | implementation |$/d' "$page"
expect 1 "an access profile is missing" python3 scripts/check-contract.py engine "$ENGINE" "$page"

# The OpenCode contract check must fail when its default audit profile disappears.
fresh || exit 2
page="$TMP/w/references/engines/opencode.md"
require_count 1 '| `inspect` (default) | `build` | every command except destructive and history-changing git; the edit tool is denied | audits, reviews, running tests and linters |' "$page"
sed -i '/^| `inspect` (default) | `build` | every command except destructive and history-changing git; the edit tool is denied | audits, reviews, running tests and linters |$/d' "$page"
expect 1 "OpenCode access profile is missing" python3 scripts/check-contract.py engine opencode "$page"

# The README loses the sentence saying these profile names do not carry to the siblings.
# Codex's README once said its read-only "reads only", contradicting its own SKILL.md; this
# is the control for that class of regression.
for r in README.md README.zh-TW.md; do
  fresh || exit 2
  case "$r" in
    README.md) needle="These profile names are omp's own." ;;
    README.zh-TW.md) needle='這些設定檔名稱是 omp 自己的。' ;;
  esac
  require_count 1 "$needle" "$TMP/w/$r"
  sed -i "\|$needle|d" "$TMP/w/$r"
  expect 1 "$r without the cross-engine note" python3 scripts/check-contract.py entry \
    "$TMP/w/SKILL.md" "$TMP/w/README.md" "$TMP/w/README.zh-TW.md"
done

# An evidence rule drops out of the worker prompt template. This happened: one sibling gained
# a rule and the other two kept the shorter list.
fresh || exit 2
template="$TMP/w/references/prompt-template.md"
require_count 1 '- A number is a claim' "$template"
sed -i '/^- A number is a claim/,+2d' "$template"
expect 1 "prompt template lost an evidence rule" python3 scripts/check-contract.py template "$template"

fresh || exit 2
rm -f "$TMP/w/references/prompt-template.md"
expect 2 "the prompt template is missing" python3 scripts/check-contract.py template \
  "$TMP/w/references/prompt-template.md"

# Input that cannot be read is 2, not a finding.
expect 2 "SKILL.md does not exist" python3 scripts/check-contract.py entry \
  "$TMP/does-not-exist.md" README.md README.zh-TW.md
expect 2 "engine page does not exist" python3 scripts/check-contract.py engine "$ENGINE" \
  "$TMP/does-not-exist.md"
expect 2 "unknown engine name" python3 scripts/check-contract.py engine nosuchengine \
  references/engines/omp.md
fresh || exit 2
rm -f "$TMP/w/README.zh-TW.md"
expect 2 "a README is missing" python3 scripts/check-contract.py entry \
  "$TMP/w/SKILL.md" "$TMP/w/README.md" "$TMP/w/README.zh-TW.md"

# Shell syntax: the clean copy is green, an injected error is red.
fresh || exit 2
expect 0 "baseline shell-syntax" sh "$TMP/w/scripts/check-shell-syntax.sh"
printf '\ncase x in\n' >> "$TMP/w/install.sh"
expect 1 "install.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

# An error in a dispatch script must be caught too, not only in install.sh. Break one that is
# not the checker itself.
fresh || exit 2
victim="$TMP/w/scripts/note.sh"
[ -f "$victim" ] || { printf 'DEAD  a dispatch script does not parse: nothing to break\n'; exit 2; }
printf '\nif [ 1 -eq 1 ]; then\n' >> "$victim"
expect 1 "a dispatch script does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

fresh || exit 2
printf '\ncase x in\n' >> "$TMP/w/scripts/reflect.sh"
expect 1 "reflect.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

fresh || exit 2
printf '\ncase x in\n' >> "$TMP/w/scripts/engines/omp/agent.sh"
expect 1 "engines/omp/agent.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

fresh || exit 2
printf '\ncase x in\n' >> "$TMP/w/scripts/engines/codex/agent.sh"
expect 1 "engines/codex/agent.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"

fresh || exit 2
printf '\ncase x in\n' >> "$TMP/w/scripts/engines/opencode/agent.sh"
expect 1 "engines/opencode/agent.sh does not parse" sh "$TMP/w/scripts/check-shell-syntax.sh"


if [ "$fail" -ne 0 ]; then
  printf '%d passed, %d dead\n' "$pass" "$fail"
  exit 1
fi
printf '%d controls passed, none dead\n' "$pass"
