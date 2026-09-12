#!/usr/bin/env python3
"""Read complete Codex tool events without modifying their source."""

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


def _file_paths(changes):
    if not isinstance(changes, list):
        return changes
    return ",".join(
        change["path"]
        for change in changes
        if isinstance(change, dict) and isinstance(change.get("path"), str)
    )


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
            # Counts cover valid JSON lines only; interleaved fragments are not reconstructed.
            continue
        if event.get("type") != "item.completed":
            continue
        item = event.get("item") or {}
        item_type = item.get("type")
        if item_type == "command_execution":
            name = item_type
            args = item.get("command")
            # Codex also defines failed and declined terminal statuses in its protocol.
            ok = item.get("status") == "completed" and item.get("exit_code") == 0
        elif item_type == "file_change":
            name = item_type
            args = _file_paths(item.get("changes"))
            ok = item.get("status") == "completed"
        elif item_type == "mcp_tool_call":
            name = "/".join(filter(None, (item.get("server"), item.get("tool"))))
            args = item.get("arguments")
            ok = item.get("status") == "completed"
        elif item_type == "web_search":
            name = item_type
            args = item.get("query")
            ok = True
        else:
            continue
        events.append({"name": name, "args_head": _args_head(args), "ok": ok})
    return events, offset + len(complete)


def repeated_failure(path, window=40, threshold=8):
    """Return a repeated failing Codex item from the bounded event tail."""
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
        if event.get("type") != "item.completed":
            continue
        item = event.get("item") or {}
        status = item.get("status")
        exit_code = item.get("exit_code")
        failed = status in ("failed", "declined", "error") or exit_code not in (0, None)
        if item.get("type") in ("command_execution", "file_change", "mcp_tool_call"):
            key = item.get("tool") or item.get("type")
            fails.append(key if failed else None)
    recent = [failure for failure in fails[-window:] if failure]
    if not recent:
        return None
    top = max(set(recent), key=recent.count)
    count = recent.count(top)
    return (top, count) if count >= threshold else None


def last_event(path):
    """Describe the last complete Codex event from the bounded event tail."""
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
        item = event.get("item") or {}
        kind = item.get("type") or event.get("type")
        detail = (item.get("command") or item.get("query") or item.get("text") or "")[:60]
        return f"{kind} {detail}".strip()
    return None
