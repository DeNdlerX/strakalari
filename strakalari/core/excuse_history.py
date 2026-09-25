"""Already-excused history: normalization, coverage checks, safe writes.

The history file (``already_excused_lessons.json``) lists every excuse
that was sent — locally or, via the Komens outbox sync, from the web.
Entries are ranges::

    {"type": "pure days", "starting_day": "01.09.2026", "ending_day": "03.09.2026"}
    {"type": "days and hours", "starting_day": "04.09.2026", "ending_day": "04.09.2026",
     "starting_lesson": 2, "ending_lesson": 4}

Hour-based entries spanning several days run from ``starting_lesson`` on
the first day to ``ending_lesson`` on the last one (middle days whole).

Duplicate detection is *coverage*, not equality: an absence is already
excused when every one of its lessons falls inside some history entry,
so a broader web excuse (e.g. a whole week) also covers a single day.

Every read-check-send-write sequence runs under :func:`history_lock`
(in-process lock + lock file shared with the tray process), so two
senders can neither excuse the same absence twice nor lose each other's
history entries.
"""

from __future__ import annotations

import threading
from contextlib import contextmanager
from datetime import date, timedelta
from typing import Iterator

STORED_KEYS = ("type", "starting_day", "ending_day", "starting_lesson", "ending_lesson")

_PROCESS_LOCK = threading.RLock()
_HELD = threading.local()


def _day(value) -> date | None:
    from .models import parse_cz_date

    return parse_cz_date(value) if value else None


def normalize_history_item(item):
    """Canonicalizes excuse day strings to zero-padded ``DD.MM.YYYY``."""
    if not isinstance(item, dict):
        return item
    item = dict(item)
    for key in ("starting_day", "ending_day"):
        parsed = _day(item.get(key))
        if parsed is not None:
            item[key] = parsed.strftime("%d.%m.%Y")
    return item


def base_excuse(excuse: dict | None) -> dict:
    """Only the storable keys of an excuse (UI extras stripped)."""
    return {k: v for k, v in (excuse or {}).items() if k in STORED_KEYS}


#: Only absences this recent are ever excused. Komens → Odeslané lists the
#: last month of sent messages by default, so older excuses cannot be
#: checked for duplicates — older absences are history, not tasks.
EXCUSE_WINDOW_DAYS = 30


def excuse_window_start(today: date, outbox_from: date | None = None) -> date:
    """First day an absence may still be excused.

    ``outbox_from`` is the start of the range Odeslané actually showed;
    when it is later than the default month, the narrower range wins.
    """
    start = today - timedelta(days=EXCUSE_WINDOW_DAYS)
    if isinstance(outbox_from, date) and start < outbox_from <= today:
        return outbox_from
    return start


HOUR_TYPES = ("income", "soon", "days and hours")


def history_entries(excuse: dict | None) -> list[dict]:
    """History rows recording one sent excuse.

    Bakaláři renders late arrivals, early leaves and short absences as
    the same hour-range message, so the web sync can never tell them
    apart: an hour-based excuse is stored in all three shapes, locally
    exactly as the web sync stores it, so both sides always agree.
    """
    entry = base_excuse(normalize_history_item(excuse))
    if str(entry.get("type", "")).lower() not in HOUR_TYPES:
        return [entry]
    return [{**entry, "type": kind} for kind in HOUR_TYPES]


def merge_sent_excuses(history: list, discovered: list) -> tuple[list, int]:
    """Merges web-scraped sent excuses into a history list.

    Both sides are normalized before comparing, so a web excuse never
    duplicates a local entry written in another spelling. Returns
    ``(merged_history, added_count)``. Pure — never raises.
    """
    merged = []
    for item in history or []:
        merged.append(base_excuse(normalize_history_item(item))
                      if isinstance(item, dict) else item)
    added = 0
    for item in discovered or []:
        if not isinstance(item, dict):
            continue
        entry = base_excuse(normalize_history_item(item))
        if entry not in merged:
            merged.append(entry)
            added += 1
    return merged, added


def _lesson(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _covers(entry: dict, day: date, lesson: int | None) -> bool:
    """True when one history entry covers ``lesson`` (None = whole day) on ``day``."""
    start = _day(entry.get("starting_day"))
    end = _day(entry.get("ending_day")) or start
    if start is None or end is None or not (start <= day <= end):
        return False
    if str(entry.get("type", "")).lower() == "pure days":
        return True
    first, last = _lesson(entry.get("starting_lesson")), _lesson(entry.get("ending_lesson"))
    if first is None or last is None:
        return False
    if start < day < end:
        return True  # middle day of a multi-day hour range
    if lesson is None:
        return False  # a partial range never covers a whole day
    if start == end:
        return first <= lesson <= last
    if day == start:
        return lesson >= first
    return lesson <= last


def _excuse_points(excuse: dict) -> list[tuple[date, int | None]]:
    start = _day(excuse.get("starting_day"))
    end = _day(excuse.get("ending_day")) or start
    if start is None or end is None or end < start:
        return []
    if str(excuse.get("type", "")).lower() == "pure days":
        days = []
        cursor = start
        while cursor <= end and len(days) < 366:
            days.append((cursor, None))
            cursor += timedelta(days=1)
        return days
    first = _lesson(excuse.get("starting_lesson"))
    last = _lesson(excuse.get("ending_lesson"))
    if first is None or last is None or start != end:
        return []
    return [(start, lesson) for lesson in range(first, max(first, last) + 1)]


def excuse_covered(excuse: dict, history: list) -> bool:
    """True when every lesson/day of ``excuse`` is inside the history.

    Unparseable excuses are never covered (fail toward sending, the
    caller's exact-match fallback still applies).
    """
    entries = [h for h in history or [] if isinstance(h, dict)]
    if base_excuse(normalize_history_item(excuse)) in (
            base_excuse(normalize_history_item(h)) for h in entries):
        return True
    points = _excuse_points(excuse)
    if not points:
        return False
    return all(any(_covers(h, day, lesson) for h in entries) for day, lesson in points)


def task_covered(day: date, period: int | None, history: list) -> bool:
    """True when a single lesson task (day + period) is already excused."""
    return any(_covers(h, day, period) for h in history or []
               if isinstance(h, dict) and (period is not None
                                           or str(h.get("type", "")).lower() == "pure days"))


@contextmanager
def history_lock(history_path: str, timeout_s: float = 600.0) -> Iterator[bool]:
    """Serializes history read-check-send-write sequences.

    Yields True when the lock is held, False when another process kept
    it for ``timeout_s`` (callers must then not send). Stale lock files
    from killed processes are reclaimed after 15 minutes.
    """
    import time

    from .helpers import release_file_lock, try_file_lock

    with _PROCESS_LOCK:
        if getattr(_HELD, "depth", 0):
            # Re-entrant within one thread: the outer holder has the file.
            _HELD.depth += 1
            try:
                yield True
            finally:
                _HELD.depth -= 1
            return
        token = None
        deadline = time.monotonic() + max(0.0, timeout_s)
        while True:
            token = try_file_lock(history_path + ".lock", stale_after_s=900.0)
            if token is not None or time.monotonic() >= deadline:
                break
            time.sleep(0.5)
        _HELD.depth = 1 if token is not None else 0
        try:
            yield token is not None
        finally:
            _HELD.depth = 0
            release_file_lock(token)
