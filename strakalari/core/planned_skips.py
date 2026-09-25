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
