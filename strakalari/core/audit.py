"""Automation history: every excuse send and lunch order attempt.

An append-only JSON-lines file (``automation_history.jsonl`` in the data
dir) with one record per attempt — manual clicks and background ``auto``
runs, real sends and ``dry_run`` simulations, successes and failures.
The UI shows the tail (Activity screen) so the user can always see what
was submitted under their account and when.

Records hold dates, lesson numbers and meal ids only — never
credentials, excuse texts or page content. Writing never raises: a
broken history file must not block a send, but the failure is printed
(it lands in the console / crash report) instead of being swallowed.
"""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime
from typing import Any

HISTORY_FILE = "./automation_history.jsonl"
MAX_BYTES = 1024 * 1024

KINDS = ("excuse", "lunch")
#: ``sent`` = submitted to the site, ``dry_run`` = simulated only,
#: ``covered`` = not sent because the history already covers it,
#: ``skipped`` = not attempted (closed day, not on the menu, …),
#: ``failed`` = attempted and not confirmed by the site.
OUTCOMES = ("sent", "dry_run", "covered", "skipped", "failed")

_LOCK = threading.Lock()


def history_path() -> str:
    from .helpers import _resolve_path

    return _resolve_path(HISTORY_FILE)


def record(kind: str, outcome: str, source: str, summary: str,
           detail: dict | None = None, now: datetime | None = None) -> bool:
    """Appends one record. Returns False (and prints why) when it could not."""
    entry: dict[str, Any] = {
        "ts": (now or datetime.now()).isoformat(timespec="seconds"),
        "kind": kind if kind in KINDS else str(kind),
        "outcome": outcome if outcome in OUTCOMES else str(outcome),
        "source": "auto" if source == "auto" else "manual",
        "summary": str(summary or "")[:300],
    }
    if detail:
        entry["detail"] = detail
    path = history_path()
    try:
        line = json.dumps(entry, ensure_ascii=False, default=str) + "\n"
        with _LOCK:
            _rotate_if_large(path)
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)
        return True
    except Exception as exc:  # noqa: BLE001 - never block a send on the audit trail
        print(f"Warning: could not write automation history {path!r}: "
              f"{type(exc).__name__}: {exc}")
        return False


def _rotate_if_large(path: str) -> None:
    from .helpers import release_file_lock, try_file_lock

    try:
        if not os.path.exists(path) or os.path.getsize(path) <= MAX_BYTES:
            return
    except OSError:
        return
    token = try_file_lock(path + ".lock")
    if token is None:
        return  # the other process is rotating; appending is still fine
    try:
        os.replace(path, path + ".old")
    except OSError as exc:
        print(f"Warning: could not rotate automation history: {exc}")
    finally:
        release_file_lock(token)


def recent(limit: int = 50) -> list[dict]:
    """The newest ``limit`` records, newest first. Unreadable lines are skipped."""
    path = history_path()
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []
    except OSError as exc:
        print(f"Warning: could not read automation history: {exc}")
        return []
    out: list[dict] = []
    for raw in reversed(lines):
        try:
            item = json.loads(raw)
        except ValueError:
            continue
        if isinstance(item, dict):
            out.append(item)
        if len(out) >= max(0, limit):
            break
    return out


def has_dry_run(kind: str) -> bool:
    """True when at least one dry run of ``kind`` completed successfully."""
    return any(item.get("kind") == kind and item.get("outcome") == "dry_run"
               for item in recent(limit=2000))


def describe_excuse(excuse: dict) -> str:
    """Short, text-free label of an excuse range (no excuse wording)."""
    start = excuse.get("starting_day", "?")
    end = excuse.get("ending_day") or start
    days = str(start) if start == end else f"{start} – {end}"
    first, last = excuse.get("starting_lesson"), excuse.get("ending_lesson")
    if first is None:
        return days
    lessons = f"{first}." if first == last or last is None else f"{first}.–{last}."
    return f"{days} ({lessons})"
