"""Separate quiet live jobs from missing completion after finalisation grace."""
import os
from pathlib import Path


FINALISE_GRACE = 5


def liveness(agent, started, now, quiet_seconds, progress):
    if any((agent / name).exists() for name in ("meta.json", "last.txt", "result.json")):
        return None, None
    identity = started.get("started_at")
    previous = progress.get(agent.name) or {}
    if previous.get("started_at") != identity:
        previous = {}
    dead = False
    pid = started.get("pid")
    if pid:
        try:
            os.kill(int(pid), 0)
            stat = Path(f"/proc/{pid}/stat").read_text()
            dead = stat.rsplit(")", 1)[1].split()[0] == "Z"
        except ProcessLookupError:
            dead = True
        except (OSError, ValueError):
            pass
    events = agent / "events.jsonl"
    try:
        stat = events.stat()
        size, last_growth = stat.st_size, stat.st_mtime
    except OSError:
        size, last_growth = 0, started.get("started_at", now)
    if previous:
        last_growth = now if size != previous["size"] else previous["last_growth"]
    current = {"started_at": identity, "size": size, "last_growth": last_growth}
    progress[agent.name] = current
    if dead:
        current["dead_since"] = previous.get("dead_since", now)
        if now - current["dead_since"] >= FINALISE_GRACE:
            return "STALLED", "process gone without meta.json or final result"
        return None, None
    quiet = int(now - last_growth)
    if pid and quiet_seconds and quiet >= quiet_seconds:
        return "QUIET", f"{quiet}s without event growth (notice {quiet_seconds}s)"
    return None, None
