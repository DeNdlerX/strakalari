"""Planned skips (planner "stay home" ranges) — pure helpers.

Canonical entry shape (stored in config under ``planned_skips``)::

    {"start_date": iso, "end_date": iso,
     "start_period": int | None, "end_period": int | None,
     "template": str}

The legacy ``{"date": iso, "template": str}`` single-day shape is upgraded
by :func:`normalize_planned_entry`.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Iterable, Mapping, Sequence


def normalize_planned_entry(raw: dict | None) -> dict | None:
    """Canonical planned-skip entry, or None for unparseable input."""
    if not isinstance(raw, dict):
        return None
    template = str(raw.get("template", "") or "")
    start_iso = str(raw.get("start_date", "") or raw.get("date", "") or "")
    end_iso = str(raw.get("end_date", "") or start_iso or "")

    def _period(value: object) -> int | None:
        if value is None or value == "":
            return None
        try:
            num = int(value)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return None
        return num if num >= 0 else None

    start_period = _period(raw.get("start_period"))
    end_period = _period(raw.get("end_period"))
    try:
        start = date.fromisoformat(start_iso)
        end = date.fromisoformat(end_iso)
    except ValueError:
        return None
    if end < start:
        start, end = end, start
    if (start == end and start_period is not None and end_period is not None
            and end_period < start_period):
        start_period, end_period = end_period, start_period
    entry: dict = {"start_date": start.isoformat(),
                   "end_date": end.isoformat(), "template": template}
    if start_period is not None:
        entry["start_period"] = start_period
    if end_period is not None:
        entry["end_period"] = end_period
    # Only an explicit "keep my lunch" is stored; entries without the key
    # (older configs, the default) cancel the lunch.
    if raw.get("cancel_lunch") is False:
        entry["cancel_lunch"] = False
    return entry


def cancels_lunch(entry: dict) -> bool:
    """True unless the user chose to keep the lunch on this day off."""
    return (entry or {}).get("cancel_lunch") is not False


def entry_start_iso(entry: dict) -> str:
    return str(entry.get("start_date", "") or entry.get("date", "") or "")


def entry_end_iso(entry: dict) -> str:
    return str(entry.get("end_date", "") or entry_start_iso(entry))


def entry_days(entry: dict, limit: int = 62) -> list[date]:
    """Every calendar day an entry covers (inclusive, capped at ``limit``)."""
    try:
        start = date.fromisoformat(entry_start_iso(entry))
        end = date.fromisoformat(entry_end_iso(entry))
    except ValueError:
        return []
    days: list[date] = []
    current = start
    while current <= end and len(days) < limit:
        days.append(current)
        current += timedelta(days=1)
    return days


def entry_covers(entry: dict, day: date, period: int | None) -> bool:
    """True when ``entry`` skips lesson ``period`` on ``day``.

    The planner's rule: ``start_period`` limits the first day, ``end_period``
    the last one, the days between are whole; a lesson without a number
    counts as covered.
    """
    days = entry_days(entry)
    if day not in days:
        return False
    if period is None:
        return True
    first = entry.get("start_period") if day == days[0] else None
    last = entry.get("end_period") if day == days[-1] else None
    return (first is None or period >= first) and (last is None or period <= last)


def _next_weekday(day: date) -> date:
    nxt = day + timedelta(days=1)
    while nxt.weekday() >= 5:
        nxt += timedelta(days=1)
    return nxt


def entries_for_selection(
    picked: Mapping[date, Iterable[int]],
    lessons: Mapping[date, Sequence[int]],
    template: str = "",
    cancel_lunch: bool = True,
    max_days: int = 31,
) -> list[dict]:
    """Planned entries that skip exactly the picked lessons.

    ``picked`` maps a day to the lesson numbers chosen on it, ``lessons``
    a day to every lesson number it holds (cancelled ones left out, already
    planned or past ones kept, so they split the selection). Picked lessons
    next to each other become one entry; whole days in a row — a weekend
    between them doesn't break the row, a holiday does — merge into one
    range, which may start with the end of one day and finish with the
    start of another. The edge of a day stays open (no period), so a lesson
    added there later is still covered. A range never spans more than
    ``max_days`` calendar days.
    """
    out: list[dict] = []
    run: dict | None = None  # open range: its last day is picked to the end

    def _close() -> None:
        nonlocal run
        if run is not None:
            out.append(run)
            run = None

    for day in sorted(picked):
        chosen: set[int] = set()
        for period in picked[day] or ():
            try:
                chosen.add(int(period))
            except (TypeError, ValueError):
                continue
        if not chosen:
            continue
        order: set[int] = set(chosen)
        for period in lessons.get(day) or ():
            try:
                order.add(int(period))
            except (TypeError, ValueError):
                continue
        ordered = sorted(order)
        segments: list[tuple[int, int]] = []  # index ranges into ``ordered``
        begin: int | None = None
        for i, period in enumerate(ordered):
            if period in chosen:
                if begin is None:
                    begin = i
            elif begin is not None:
                segments.append((begin, i - 1))
                begin = None
        if begin is not None:
            segments.append((begin, len(ordered) - 1))
        for first, last in segments:
            head, tail = first == 0, last == len(ordered) - 1
            if (head and run is not None
                    and _next_weekday(date.fromisoformat(run["end_date"])) == day
                    and (day - date.fromisoformat(run["start_date"])).days < max_days):
                run["end_date"] = day.isoformat()
                run["end_period"] = None if tail else ordered[last]
            else:
                _close()
                run = {"start_date": day.isoformat(), "end_date": day.isoformat(),
                       "start_period": None if head else ordered[first],
                       "end_period": None if tail else ordered[last],
                       "template": template, "cancel_lunch": bool(cancel_lunch)}
            if not tail:
                _close()
    _close()
    entries = (normalize_planned_entry(raw) for raw in out)
    return [e for e in entries if e is not None]


def load_planned_skips(config_data: dict | None) -> list[dict]:
    """Normalized planned-skip entries from a config dict."""
    stored = (config_data or {}).get("planned_skips", [])
    if not isinstance(stored, list):
        return []
    entries = (normalize_planned_entry(e) for e in stored if isinstance(e, dict))
    return [e for e in entries if e is not None]


def planned_lunch_days(config_data: dict | None) -> set[str]:
    """``DD.MM.YYYY`` days off whose lunch should be cancelled."""
    days: set[str] = set()
    for entry in load_planned_skips(config_data):
        if not cancels_lunch(entry):
            continue
        for day in entry_days(entry):
            days.add(day.strftime("%d.%m.%Y"))
    return days
