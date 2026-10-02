#!/usr/bin/env python3
"""Run bounded engine recovery without resetting the job deadline."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time


def evidence(path, engine):
    session, errors, progress = None, [], False
    for line in path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        kind = event.get("type", "")
        if engine == "omp" and kind == "session":
            session = event.get("id") or session
        session = event.get("thread_id") or event.get("sessionID") or session
        if kind in ("error", "turn.failed"):
            errors.append(json.dumps(event))
        elif kind in ("message_end", "tool_execution_end", "item.completed", "text", "tool_use"):
            progress = True
    return session, "\n".join(errors), progress


def scan_job_tools(path, scanner):
    path = Path(path)
    try:
        attempt = int((path.parent / "attempt.txt").read_text())
    except (OSError, ValueError):
        attempt = 1
    rows = []
    for previous in range(1, attempt):
        rows.extend(scanner(path.parent / f"events.attempt-{previous}.jsonl", 0)[0])
    rows.extend(scanner(path, 0)[0])
    return rows


def classify(code, diagnostic):
    if code == 0:
        return "success"
    if code in (124, 137, 130, 143):
        return "terminal"
    if re.search(r"unauthori[sz]ed|authentication|invalid.api.key|\b401\b|\b403\b", diagnostic, re.I):
        return "terminal"
    if re.search(r"token.limit|maximum.context.length|context[_ -]length|context.window", diagnostic, re.I):
        return "terminal"
    if re.search(r"quota|usage.limit|insufficient[_ ](?:quota|credits|balance)|(?:usage|credit|budget).*exceeded|exceeded.*(?:quota|usage)|hit your.*(?:usage|credit|budget).limit", diagnostic, re.I):
        return "quota"
    if re.search(r"at capacity|overloaded|rate[_ -]?limit|\b429\b|\b503\b", diagnostic, re.I):
        return "transient"
    if re.search(r"database (?:table )?is locked|SQLITE_BUSY", diagnostic, re.I):
        return "lock"
    return "terminal"


def replace_option(args, flags, value):
    for flag in flags:
        if flag in args:
            index = args.index(flag)
            args[index + 1] = value
            return
    # Codex options must precede its resume subcommand and stdin marker.
    index = args.index("resume") if "resume" in args else len(args) - 1
    args[index:index] = [flags[0], value]


def aggregate_usage(out, engine):
    total = {}
    # A deadline can expire before the first attempt starts, leaving no attempt or events file.
    marker = out / 'attempt.txt'
    attempt = int(marker.read_text()) if marker.exists() else 1
    paths = [out / f'events.attempt-{n}.jsonl' for n in range(1, attempt)]
    for path in [*paths, out / 'events.jsonl']:
        if not path.exists():
            continue
        usage = {}
        for line in path.read_text(errors='replace').splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get('type')
            if engine == 'omp' and kind == 'message_end':
                message = event.get('message') or {}
                if message.get('role') != 'assistant':
                    continue
                u = message.get('usage') or {}
                values = {'input_tokens':u.get('input',0), 'output_tokens':u.get('output',0),
                          'cached_input_tokens':u.get('cacheRead',0),
                          'cost':(u.get('cost') or {}).get('total',0)}
                for key, value in values.items():
                    usage[key] = usage.get(key,0) + value
            elif engine == 'codex' and kind == 'turn.completed':
                for key, value in (event.get('usage') or {}).items():
                    usage[key] = usage.get(key,0) + value
            elif engine == 'opencode' and kind == 'step_finish':
                part = event.get('part') or {}
                tok = part.get('tokens') or {}
                usage = {'input_tokens':tok.get('input',0),'output_tokens':tok.get('output',0),
                         'reasoning_output_tokens':tok.get('reasoning',0),
                         'cached_input_tokens':(tok.get('cache') or {}).get('read',0),
                         'cost':part.get('cost',0)}
        for key, value in usage.items():
            total[key] = total.get(key,0) + value
    if 'cost' in total:
        total['cost'] = round(total['cost'],6)
    return total


def hard_kill(out, wrapper):
    try:
        os.kill(wrapper, signal.SIGSTOP)
    except ProcessLookupError:
        return
    try:
        identity = json.loads((out / 'engine.json').read_text())
        if identity['wrapper'] == wrapper:
            try:
                os.killpg(identity['pgid'], signal.SIGKILL)
            except ProcessLookupError:
                pass
    finally:
        os.kill(wrapper, signal.SIGKILL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True)
    parser.add_argument("--prompt-input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--no-recovery", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    opts = parser.parse_args()
    args = opts.command[1:] if opts.command[:1] == ["--"] else opts.command
    engine, out = opts.engine, opts.out
    events, stderr = out / "events.jsonl", out / "stderr.log"
    pairs = dict(pair.split("=", 1) for pair in os.environ.get("AGENT_FALLBACK_PAIRS", "").split())
    limit = max(1, int(os.environ.get("AGENT_RECOVERY_ATTEMPTS", os.environ.get("AGENT_LOCK_RETRIES", "4"))))
    backoff = max(0.0, float(os.environ.get("AGENT_RECOVERY_BACKOFF", "2")))
    model_flag = "--model" if engine == "omp" else "-m"
    model = args[args.index(model_flag) + 1] if model_flag in args else ""
    session_flag = "resume" if engine == "codex" else "-r" if engine == "omp" else "-s"
    session = args[args.index(session_flag) + 1] if session_flag in args else None
    fork_parent = session if '--fork' in args else None
    prompt_path = opts.prompt_input
    seen_models = {model}
    rows, code, attempt = [], 124, 0
    child = None
    (out / 'recovery.json').write_text('[]\n')

    def interrupt(signum, _frame):
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signum)
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        events.touch(exist_ok=True)
        stderr.touch(exist_ok=True)
        found, _, _ = evidence(events, engine)
        if not rows or rows[-1]["attempt"] != attempt:
            rows.append({"attempt": attempt, "model": model or None, "session": found or session,
                         "exit_code": 128 + signum, "classification": "terminal", "deadline": opts.deadline})
            shutil.copyfile(events, out / f"events.attempt-{attempt}.jsonl")
            shutil.copyfile(stderr, out / f"stderr.attempt-{attempt}.log")
        (out / "recovery.json").write_text(json.dumps(rows, indent=2) + "\n")
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupt)
    for attempt in range(1, limit + 1):
        remaining = opts.deadline - time.time()
        if remaining <= 0:
            break
        (out / "attempt.txt").write_text(str(attempt))
        if engine == "omp":
            replace_option(args, ["--max-time"], str(max(1, int(remaining))))
        # Result files belong to this attempt, never to an earlier failed turn.
        for name in ("last.txt", "result.json"):
            (out / name).unlink(missing_ok=True)
        with events.open("w") as ev, stderr.open("w") as err, prompt_path.open() as prompt:
            try:
                child = subprocess.Popen(args, stdin=prompt if engine == "codex" else subprocess.DEVNULL,
                                         stdout=ev, stderr=err, start_new_session=True)
                (out / 'engine.json').write_text(json.dumps({'wrapper':os.getpid(),'pgid':child.pid}))
            except OSError as exc:
                err.write(f"engine launch failed: {exc}\n")
                child, code = None, 127
            if child is not None:
                try:
                    code = child.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGINT)
                    try:
                        child.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    code = 124
        code = 128 - code if code < 0 else code
        found, error, progress = evidence(events, engine)
        session = found or session
        kind = classify(code, stderr.read_text(errors="replace") + "\n" + error)
        row = {"attempt": attempt, "model": model or None, "session": session,
               "exit_code": code, "classification": kind, "deadline": opts.deadline}
        rows.append(row)
        shutil.copyfile(events, out / f"events.attempt-{attempt}.jsonl")
        shutil.copyfile(stderr, out / f"stderr.attempt-{attempt}.log")
        (out / "recovery.json").write_text(json.dumps(rows, indent=2) + "\n")
        if opts.no_recovery or attempt == limit or kind in ("success", "terminal"):
            break
        if kind == "lock" and progress:
            break
        if kind != "lock" and not session:
            break
        if kind == "quota":
            fallback = pairs.get(model)
            if not fallback or fallback in seen_models:
                break
            model = fallback
            seen_models.add(model)
            replace_option(args, [model_flag], model)
        if session:
            if session_flag in args:
                replace_option(args, [session_flag], session)
            else:
                args[-1:-1] = [session_flag, session]
            if "--fork" in args and found and found != fork_parent:
                args.remove("--fork")
            continuation = (f'Your previous attempt stopped because of {kind}. '
                            'Continue from where you stopped; the working tree holds your earlier changes. '
                            'Do not redo finished steps.')
            original = opts.prompt_input.read_text()
            marker = '\n\nRun artifacts: '
            if marker in original:
                continuation += marker + original.split(marker,1)[1]
            prompt_path = out / 'continue.md'
            prompt_path.write_text(continuation)
            if engine != 'codex':
                args[-1] = continuation
        delay = backoff * attempt * attempt
        row["next_model"] = model or None
        row["backoff_s"] = delay
        (out / "recovery.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(f"{kind} on attempt {attempt}/{limit}; resume in {delay:g}s", file=__import__("sys").stderr)
        remaining = opts.deadline - time.time()
        if remaining <= delay:
            time.sleep(max(0, remaining))
            code = 124
            break
        time.sleep(delay)
    events.touch(exist_ok=True)
    stderr.touch(exist_ok=True)
    (out / "recovery.json").write_text(json.dumps(rows, indent=2) + "\n")
    return code


if __name__ == "__main__":
    import sys
    if sys.argv[1:2] == ['--hard-kill']:
        hard_kill(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        raise SystemExit(main())
