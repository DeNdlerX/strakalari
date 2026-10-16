"""What a refresh brought since the previous one: marks, absences, timetable changes.

Fresh data is compared with the data cache before the refresh saves over
it, so each novelty is reported once — also across the tray and the
window (separate processes take turns through the session lock and share
the cache). Only what the previous state can be compared with counts: the
first sync, a failed part of the fetch, or timetable days loaded for the
first time (history weeks, a week entering the window) report nothing.
"""

from __future__ import annotations

from datetime import date
from typing import Any

from .i18n import t
from .models import Lesson, canonical_day_key, parse_cz_date

#: Lesson states that record the student's (partial) absence.
ABSENCE_STATES = frozenset({"absent", "late", "early", "soon", "excused"})

#: Items named in one notification; the rest are only counted.
MAX_ITEMS = 4


def find_news(previous: dict | None, fresh: dict | None,
              today: date | None = None) -> list[tuple[str, str]]:
    """``(event, message)`` notifications for what ``fresh`` adds to ``previous``.

    ``fresh`` is the refresh's cache payload (only the parts fetched OK).
    """
    previous = previous if isinstance(previous, dict) else {}
    fresh = fresh if isinstance(fresh, dict) else {}
    found = (
        ("new_mark", "news_mark", "news_marks", new_marks(previous, fresh)),
        ("new_absence", "news_absence", "news_absences", new_absences(previous, fresh)),
        ("timetable_change", "news_change", "news_changes",
         new_changes(previous, fresh, today or date.today())),
    )
    return [(event, _message(one, many, items))
            for event, one, many, items in found if items]


def _message(one: str, many: str, items: list[str]) -> str:
    shown = "; ".join(items[:MAX_ITEMS])
    if len(items) > MAX_ITEMS:
        shown += " " + t("news_more", n=len(items) - MAX_ITEMS)
    return t(one if len(items) == 1 else many, items=shown)


def _label(subject: str, day: date | None, period: int | None) -> str:
    """'Matematika 14. 10., 3. hodina'."""
    text = subject or "?"
    if day is not None:
        text += f" {day.day}. {day.month}."
    if period is not None:
        text += ", " + t("period_label", n=period)
    return text


# -- marks -------------------------------------------------------------------------
def new_marks(previous: dict, fresh: dict) -> list[str]:
    """Marks the previous grades did not have (announced ``?`` marks skipped)."""
    from .grades import is_planned, mark_keys

    old, new = previous.get("grades"), fresh.get("grades")
    if not isinstance(old, dict) or not isinstance(new, dict):
        return []  # first sync, or the grades did not load this time
    items: list[str] = []
    for subject, marks in new.items():
        if not isinstance(marks, list):
            continue
        before = old.get(subject) if isinstance(old.get(subject), list) else []
        # An announced mark that is now given keeps its id: still news.
        known = {key for key, mark in zip(mark_keys(before), before, strict=True)
                 if not (isinstance(mark, dict) and is_planned(mark))}
        for key, mark in zip(mark_keys(marks), marks, strict=True):
            if key in known or not isinstance(mark, dict) or is_planned(mark):
                continue
            text = f"{subject} {str(mark.get('Grade') or '').strip()}".strip()
            caption = str(mark.get("Caption") or "").strip()
            items.append(f"{text} ({caption})" if caption else text)
    return items


# -- timetable ---------------------------------------------------------------------
def _days(timetable: Any) -> dict[str, list]:
    """Lessons per canonical day (``DD.MM.YYYY``)."""
    out: dict[str, list] = {}
    for day_key, lessons in (timetable.items() if isinstance(timetable, dict) else ()):
        if isinstance(lessons, list):
            out.setdefault(canonical_day_key(day_key), []).extend(
                raw for raw in lessons if isinstance(raw, dict))
    return out


def _by_date(item: tuple[str, Any]) -> date:
    return parse_cz_date(item[0]) or date.min


def _slot(lesson: Lesson) -> Any:
    """Which lesson of the day (period, else its time)."""
    return lesson.period if lesson.period is not None else (lesson.time or lesson.subject)


def new_absences(previous: dict, fresh: dict) -> list[str]:
    """Lessons newly recorded as missed (absent, late, left early) on known days."""
    old_days = _days(previous.get("timetable"))
    items: list[str] = []
    for day_key, lessons in sorted(_days(fresh.get("timetable")).items(), key=_by_date):
        if day_key not in old_days:
            continue  # nothing to compare with
        known = {_slot(lesson) for raw in old_days[day_key]
                 if (lesson := Lesson.from_legacy(raw, day=day_key)).status in ABSENCE_STATES}
        for raw in lessons:
            lesson = Lesson.from_legacy(raw, day=day_key)
            if lesson.status in ABSENCE_STATES and _slot(lesson) not in known:
                known.add(_slot(lesson))
                items.append(_label(lesson.subject, lesson.day, lesson.period))
    return items


def _baseline(previous: dict, fresh: dict) -> tuple[dict, bool]:
    """The scraped stable timetable (this run's, else the cached one).

    Both states are diffed against the same one, so a stable-view scrape
    that failed this run does not make old changes look new.
    """
    from .schedule import baseline_from_dict

    for source in (fresh, previous):
        stored = source.get("stable_baseline")
        if source.get("stable_baseline_source") != "scraped" or not isinstance(stored, dict):
            continue
        try:
            baseline = baseline_from_dict(stored)
        except Exception:
            continue
        if baseline:
            return baseline, True
    return {}, False


def _kind(change: dict) -> str:
    changed = set(getattr(change.get("diff"), "changed", None) or [])
    if changed & {"status", "missing"}:
        return "cancelled"
    if "added" in changed:
        return "added"
    return "changed"


def _change_key(change: dict) -> tuple:
    lesson = Lesson.from_legacy(change.get("lesson") or {}, day=change.get("day_key"))
    return canonical_day_key(change.get("day_key")), _slot(lesson), _kind(change)


def new_changes(previous: dict, fresh: dict, today: date) -> list[str]:
    """Timetable changes (vs the stable timetable) that are new, from today on."""
    from .schedule import iter_changes

    old_days = _days(previous.get("timetable"))
    days = {key: lessons for key, lessons in _days(fresh.get("timetable")).items()
            if key in old_days and (parse_cz_date(key) or date.min) >= today}
    if not days:
        return []
    baseline, complete = _baseline(previous, fresh)
    known = {_change_key(change) for change in iter_changes(
        {key: old_days[key] for key in days}, baseline, complete=complete)}
    items: list[str] = []
    fresh_changes = []
    for change in iter_changes(days, baseline, complete=complete):
        lesson = Lesson.from_legacy(change.get("lesson") or {}, day=change.get("day_key"))
        fresh_changes.append((lesson.day or date.min,
                              lesson.period if lesson.period is not None else 99,
                              lesson, change))
    for _day, _period, lesson, change in sorted(fresh_changes, key=lambda item: item[:2]):
        key = _change_key(change)
        if key in known:
            continue
        known.add(key)
        diff = change.get("diff")
        kind = key[2]
        if kind == "cancelled":
            what = t("news_cancelled")
        elif kind == "added":
            what = t("news_added")
        elif "room" in (getattr(diff, "changed", None) or []) and lesson.room:
            what = t("news_room", room=lesson.room)
        else:
            what = str(getattr(diff, "note", "") or "").strip()[:80] or t("news_changed")
        items.append(f"{_label(lesson.subject, lesson.day, lesson.period)}: {what}")
    return items
