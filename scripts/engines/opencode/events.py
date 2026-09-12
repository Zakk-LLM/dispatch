#!/usr/bin/env python3
"""Read complete OpenCode tool events without modifying their source."""

import json
from pathlib import Path


def _args_head(value):
    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        except (TypeError, ValueError):
            text = str(value)
    return text.replace("\n", " ")[:80]


def scan_tools(path, offset):
    """Return terminal tool calls after offset and the last complete-line offset."""
    path = Path(path)
    try:
        size = path.stat().st_size
        if offset < 0 or offset > size:
            offset = 0
        with path.open("rb") as stream:
            stream.seek(offset)
            data = stream.read()
    except OSError:
        return [], offset

    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    complete = data[: end + 1]
    events = []
    for raw in complete.splitlines():
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Malformed lines are not events and cannot contribute to the count.
            continue
        if event.get("type") != "tool_use":
            continue
        part = event.get("part") or {}
        state = part.get("state") or {}
        status = state.get("status")
        if status not in {"completed", "error"}:
            continue
        ok = status == "completed"
        if part.get("tool") == "bash":
            exit_code = (state.get("metadata") or {}).get("exit")
            ok = ok and exit_code in (0, None)
        events.append({
            "name": part.get("tool") or "",
            "args_head": _args_head(state.get("input")),
            "ok": ok,
        })
    return events, offset + len(complete)


def repeated_failure(path, window=40, threshold=8):
    """Return a repeated failing OpenCode tool from the bounded event tail."""
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            fh.seek(max(0, size - 262144))
            lines = fh.read().decode(errors="replace").splitlines()
    except OSError:
        return None
    fails = []
    for line in lines:
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") != "tool_use":
            continue
        part = event.get("part") or {}
        state = part.get("state") or {}
        status = state.get("status")
        if status not in {"completed", "error"}:
            continue
        failed = status == "error"
        if part.get("tool") == "bash":
            failed = failed or (state.get("metadata") or {}).get("exit") not in (0, None)
        fails.append((part.get("tool") or "tool_use") if failed else None)
    recent = [failure for failure in fails[-window:] if failure]
    if not recent:
        return None
    top = max(set(recent), key=recent.count)
    count = recent.count(top)
    return (top, count) if count >= threshold else None


def last_event(path):
    """Describe the last complete OpenCode event from the bounded event tail."""
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            fh.seek(max(0, size - 4096))
            lines = [line for line in fh.read().decode(errors="replace").splitlines()
                     if line.startswith("{")]
    except OSError:
        return None
    for line in reversed(lines):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        part = event.get("part") or {}
        state = part.get("state") or {}
        kind = part.get("tool") or event.get("type")
        detail = (state.get("input") or {}).get("command")
        if not detail:
            detail = part.get("text") or ""
        return f"{kind} {str(detail)[:60]}".strip()
    return None
