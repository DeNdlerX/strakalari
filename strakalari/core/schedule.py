"""Stable-schedule baseline, change-vs-note classification, lesson clock.

The timetable coming from Bakalari is the *actual* week: every lesson may
carry a teacher ``notice`` (description). A notice alone is NOT a schedule
change — it only becomes one when the lesson actually differs from the
stable (main) timetable: different subject, teacher, room, time, an added
lesson in a normally free slot, a missing stable lesson, or a cancelled
lesson.

The baseline prefers the scraped "Stálý rozvrh" view (the exact template
week, see ``BakalariClient.extract_stable_timetable``): with such a
*complete* baseline an empty slot is a free period, so an actual lesson
there is an ``added`` change and a stable slot with no actual lesson is a
``missing`` change. The baseline is never guessed from the actual weeks:
when the stable view cannot be scraped there is no baseline, and
Bakaláři's own change flags plus the notice-keyword heuristic decide.

Lesson-clock helpers in this module are the single place that reasons
about "what time is it during the school day" — the Today view and the
planner both use them so "next lesson" and "can I still plan today"
respect the clock, not just the date.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Iterable, Sequence

from .models import Lesson, cancel_negated, parse_cz_date

_TIME_RANGE_RE = re.compile(
    r"(\d{1,2})\s*:\s*(\d{2})\s*(?:-|–|—|do)\s*(\d{1,2})\s*:\s*(\d{2})"
)

#: Notice keywords that — without any baseline to compare against — still
#: mean a real schedule change (substitution, move, cancellation).
CHANGE_KEYWORDS = (
    "supl", "substitut", "změn", "zmen", "odpad", "zruš", "zrus",
    "vyjm", "vynat", "vyňat", "přid", "prid",
    "přesun", "presun",
    "náhrad", "nahrad", "cancel", "moved",
)

_TITLE_TOKENS = {
    "ph.d.", "phd", "csc.", "csc", "drsc.", "drsc", "dis.", "dis", "mba",
    "th.d.", "thd", "dr.", "mgr.", "ing.", "bc.", "mudr.", "judr.",
    "paeddr.", "rndr.",
}


def _norm_text(value: Any) -> str:
    return str(value or "").strip().casefold()


def _surname(full_name: Any) -> str:
    tokens = [t.strip().rstrip(",") for t in str(full_name or "").split() if t.strip()]
    while tokens and tokens[0].lower() in _TITLE_TOKENS:
        tokens.pop(0)
    while tokens and tokens[-1].lower() in _TITLE_TOKENS:
        tokens.pop()
    return (tokens[-1] if tokens else "").casefold()


def parse_time_range(text: Any) -> tuple[int, int, int, int] | None:
    """Parses ``8:00 - 8:45`` (also inside ``1. 8:00 - 8:45`` / ``3 (10:05 - 10:50)``).

    Returns (start_hour, start_min, end_hour, end_min) or None.
    """
    if not text:
        return None
    match = _TIME_RANGE_RE.search(str(text))
    if not match:
        return None
    try:
        sh, sm, eh, em = (int(g) for g in match.groups())
    except (TypeError, ValueError):
        return None
    if not (0 <= sh <= 23 and 0 <= eh <= 23 and 0 <= sm <= 59 and 0 <= em <= 59):
        return None
    return sh, sm, eh, em


def lesson_clock(raw: dict, day: Any = None) -> tuple[int, int] | None:
    """Returns (start_minutes, end_minutes) since midnight for a lesson dict."""
    parsed = Lesson.from_legacy(raw or {}, day=day)
    span = parse_time_range(parsed.time)
    if span is None:
        return None
    sh, sm, eh, em = span
    start, end = sh * 60 + sm, eh * 60 + em
    if end <= start:
        return None
    return start, end


def _clocked(lessons: Iterable[dict], day: Any = None) -> list[tuple[int, int, dict]]:
    """Lessons with a parseable clock, sorted by start time."""
    out: list[tuple[int, int, dict]] = []
    for raw in lessons or []:
        if not isinstance(raw, dict):
            continue
        clock = lesson_clock(raw, day=day)
        if clock is not None:
            out.append((clock[0], clock[1], raw))
    out.sort(key=lambda item: (item[0], item[1]))
    return out


def resolve_day_lessons(
    day_lessons: Sequence[dict] | None,
    now: datetime | None = None,
    day: Any = None,
) -> dict[str, Any]:
    """Splits one day into running / upcoming lessons for ``now``.

    Returns ``{"phase", "current", "upcoming", "remaining"}`` where phase is
    one of ``empty`` (no clocked lessons at all), ``before`` (school hasn't
    started), ``running`` (a lesson is on right now), ``between`` (in a
    break, ``upcoming`` is next), ``done`` (all lessons over).
    Lessons without a parseable time are ignored for the clock but counted
    in ``remaining`` when their period number is still ahead — callers that
    need period-only fallback should sort by period themselves.
    """
    now = now or datetime.now()
    now_min = now.hour * 60 + now.minute
    clocked = _clocked(day_lessons or [], day=day)
    if not clocked:
        return {"phase": "empty", "current": None, "upcoming": None, "remaining": []}
    for start, end, raw in clocked:
        if start <= now_min < end:
            rest = [r for s, _e, r in clocked if s >= now_min]
            return {"phase": "running", "current": raw, "upcoming": None,
                    "remaining": rest}
    upcoming = [(s, r) for s, _e, r in clocked if s > now_min]
    if not upcoming:
        return {"phase": "done", "current": None, "upcoming": None, "remaining": []}
    if now_min < clocked[0][0]:
        return {"phase": "before", "current": None, "upcoming": upcoming[0][1],
                "remaining": [r for _s, r in upcoming]}
    return {"phase": "between", "current": None, "upcoming": upcoming[0][1],
            "remaining": [r for _s, r in upcoming]}


def future_lessons(
    day_lessons: Sequence[dict] | None,
    now: datetime | None = None,
    day: Any = None,
) -> list[dict]:
    """Lessons of one day that haven't started yet (clock-aware).

    Lessons without a parseable clock are kept (better to offer than to
    hide), so "plan today" never drops unparseable rows.
    """
    now = now or datetime.now()
    now_min = now.hour * 60 + now.minute
    out: list[dict] = []
    for raw in day_lessons or []:
        if not isinstance(raw, dict):
            continue
        clock = lesson_clock(raw, day=day)
        if clock is None or clock[0] > now_min:
            out.append(raw)
    return out


# -- stable baseline ----------------------------------------------------

@dataclass
class SlotBaseline:
    """The stable lesson for one (weekday, period) slot."""

    weekday: int
    period: int
    subject: str = ""
    teacher: str = ""
    room: str = ""
    start_min: int | None = None
    support: int = 0  # how many weeks agree on this fingerprint

    def __post_init__(self) -> None:
        try:
            from .helpers import short_room_name

            self.room = short_room_name(self.room)
        except Exception:
            pass


def _period_of(raw: dict, day: Any) -> int | None:
    from .helpers import extract_lesson_num

    parsed = Lesson.from_legacy(raw, day=day)
    num = parsed.period
    if num is None:
        try:
            num = extract_lesson_num(parsed.time)
        except Exception:
            num = None
    if num is None and isinstance(raw, dict):
        # Scraped rows carry Bakalari's hourIndex (period + 2); the
        # cancelled ("removed") rows have no period number in their clock.
        # Same 1..15 range as parse_timetable_detail (period 0 is never
        # inferred from hourIndex 2).
        try:
            hi = raw.get("hourIndex")
            if hi is not None:
                candidate = int(hi) - 2
                if 1 <= candidate <= 15:
                    num = candidate
        except (TypeError, ValueError):
            pass
    try:
        return int(num) if num is not None else None
    except (TypeError, ValueError):
        return None


def stable_weekly_hours(baseline: dict | None) -> dict[str, int]:
    """Weekly lesson counts per subject from the stable baseline.

    Unlike counting raw timetable rows (which include cancelled lessons,
    substitutions and one-off events), the baseline holds one slot per
    (weekday, period) — so this is the trustworthy "how many hours of X
    per normal week" input for absence forecasting. Accepts both live
    ``SlotBaseline`` values and plain serialized dicts (see
    :func:`baseline_to_dict`). Split-group slots count each distinct
    subject once — the student attends one group, but every offered
    subject still costs absence budget.
    """
    counts: dict[str, int] = {}

    def _name(variant: Any) -> str:
        if isinstance(variant, SlotBaseline):
            return str(variant.subject or "").strip()
        if isinstance(variant, dict):
            return str(variant.get("subject", "") or "").strip()
        return ""

    for slot_value in (baseline or {}).values():
        variants = slot_value if isinstance(slot_value, list) else [slot_value]
        for name in {_name(v) for v in variants}:
            if name:
                counts[name] = counts.get(name, 0) + 1
    return counts


def baseline_to_dict(baseline: dict | None) -> dict[str, dict | list]:
    """Serializes a stable baseline to JSON-safe plain dicts.

    Split-group slots (variant lists) serialize to a list of dicts.
    """
    def _one(slot: SlotBaseline | dict) -> dict:
        if isinstance(slot, SlotBaseline):
            return {
                "weekday": slot.weekday, "period": slot.period,
                "subject": slot.subject, "teacher": slot.teacher,
                "room": slot.room, "start_min": slot.start_min,
                "support": slot.support,
            }
        return dict(slot)

    out: dict[str, dict | list] = {}
    for slot_key, slot in (baseline or {}).items():
        try:
            weekday, period = slot_key
            dict_key = f"{int(weekday)}|{int(period)}"
        except (TypeError, ValueError):
            continue
        if isinstance(slot, list):
            items = [_one(v) for v in slot
                     if isinstance(v, (SlotBaseline, dict))]
            if items:
                out[dict_key] = items
        elif isinstance(slot, (SlotBaseline, dict)):
            out[dict_key] = _one(slot)
    return out


def baseline_from_dict(data: dict | None) -> dict[tuple[int, int], SlotBaseline | list[SlotBaseline]]:
    """Restores a baseline serialized with :func:`baseline_to_dict`."""
    from .helpers import short_room_name

    def _one(item: dict, slot_key: tuple[int, int]) -> SlotBaseline | None:
        if not isinstance(item, dict):
            return None
        try:
            return SlotBaseline(
                weekday=int(item.get("weekday", slot_key[0])),
                period=int(item.get("period", slot_key[1])),
                subject=str(item.get("subject", "") or ""),
                teacher=str(item.get("teacher", "") or ""),
                room=short_room_name(str(item.get("room", "") or "")),
                start_min=item.get("start_min"),
                support=int(item.get("support", 0) or 0),
            )
        except (TypeError, ValueError):
            return None

    baseline: dict[tuple[int, int], SlotBaseline | list[SlotBaseline]] = {}
    for dict_key, item in (data or {}).items():
        try:
            weekday_s, period_s = str(dict_key).split("|")
            slot_key = (int(weekday_s), int(period_s))
        except (TypeError, ValueError):
            continue
        if isinstance(item, list):
            variants = [_one(v, slot_key) for v in item]
            variants = [v for v in variants if v is not None]
            if len(variants) == 1:
                baseline[slot_key] = variants[0]
            elif variants:
                baseline[slot_key] = variants
        else:
            single = _one(item, slot_key)
            if single is not None:
                baseline[slot_key] = single
    return baseline


#: Czech / English weekday names (full + common abbreviations) to
#: ``date.weekday()``. The scraped stable ("Stálý rozvrh") view may label
#: days with names (``Pondělí``) instead of dates.
_WEEKDAY_NAMES = {
    "pondělí": 0, "pondeli": 0, "po": 0, "monday": 0, "mon": 0,
    "úterý": 1, "utery": 1, "út": 1, "ut": 1, "tuesday": 1, "tue": 1,
    "tues": 1,
    "středa": 2, "streda": 2, "st": 2, "wednesday": 2, "wed": 2,
    "čtvrtek": 3, "ctvrtek": 3, "čt": 3, "ct": 3, "thursday": 3,
    "thu": 3, "thur": 3, "thurs": 3,
    "pátek": 4, "patek": 4, "pá": 4, "pa": 4, "friday": 4, "fri": 4,
    "sobota": 5, "so": 5, "saturday": 5, "sat": 5,
    "neděle": 6, "nedele": 6, "ne": 6, "ned": 6, "sunday": 6, "sun": 6,
}


def _weekday_of(day_key: Any) -> int | None:
    """Weekday for a timetable day key: a date or a weekday name."""
    day = parse_cz_date(day_key)
    if day is not None:
        return day.weekday()
    text = str(day_key or "").split("(")[0].strip().casefold()
    return _WEEKDAY_NAMES.get(text)


def baseline_from_stable_timetable(
    stable: dict,
) -> dict[tuple[int, int], SlotBaseline | list[SlotBaseline]]:
    """Builds the baseline directly from a scraped stable week.

    The stable ("Stálý") view already shows the template week, so no
    majority vote is needed — but one slot may hold SEVERAL lessons
    (split groups sharing a period). Those are kept as a variant list so
    every group lesson still matches its slot instead of being flagged a
    change forever. Single-lesson slots stay a plain ``SlotBaseline``.
    Day keys may be dates or weekday names (``Pondělí``); unparseable
    days are skipped.
    """
    votes: dict[tuple[int, int], Counter] = {}
    exemplars: dict[tuple[int, int], dict] = {}
    for day_key, lessons in (stable or {}).items():
        weekday = _weekday_of(day_key)
        if weekday is None:
            continue
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            period = _period_of(raw, day_key)
            if period is None:
                continue
            parsed = Lesson.from_legacy(raw, day=day_key)
            clock = lesson_clock(raw, day=day_key)
            fingerprint = (
                _norm_text(parsed.subject),
                _surname(parsed.teacher),
                _norm_text(parsed.room),
                clock[0] if clock else -1,
            )
            slot = (weekday, period)
            votes.setdefault(slot, Counter())[fingerprint] += 1
            exemplars.setdefault(slot, {})\
                .setdefault(fingerprint, {
                    "subject": parsed.subject or "",
                    "teacher": parsed.teacher or "",
                    "room": parsed.room or "",
                    "start_min": clock[0] if clock else None,
                })
    baseline: dict[tuple[int, int], SlotBaseline | list[SlotBaseline]] = {}
    for slot, counter in votes.items():
        (weekday, period) = slot
        variants: list[SlotBaseline] = []
        for fingerprint in counter:
            exemplar = exemplars[slot][fingerprint]
            variants.append(SlotBaseline(
                weekday=weekday, period=period,
                subject=exemplar["subject"], teacher=exemplar["teacher"],
                room=exemplar["room"], start_min=exemplar["start_min"],
                support=counter[fingerprint],
            ))
        # One lesson per slot is the common case — keep it unwrapped so
        # lookups stay simple. Split-group slots
        # keep every variant.
        baseline[slot] = variants[0] if len(variants) == 1 else variants
    return baseline


def _period_by_clock(
    baseline: dict | None,
    weekday: int,
    clock: tuple[int, int] | None,
) -> int | None:
    """Period number for a bare clock (``"13:40 - 14:25"``) via the baseline.

    Scraped ``removed`` (cancelled) rows carry no period number — only a
    clock. When exactly one stable slot on that weekday starts at the
    same minute, that slot's period is unambiguous. Multiple or zero
    matches yield None (callers fall back to the notice heuristic).
    Never raises.
    """
    try:
        if not baseline or clock is None:
            return None
        start = clock[0]
        hits: set[int] = set()
        for slot_key, slot_value in baseline.items():
            try:
                wd, period = slot_key
                if int(wd) != int(weekday):
                    continue
                period_i = int(period)
            except (TypeError, ValueError):
                continue
            for variant in _variants(slot_value):
                if variant.start_min == start:
                    hits.add(period_i)
        if len(hits) == 1:
            return hits.pop()
    except Exception:
        pass
    return None


def backfill_stable_facts(timetable: dict | None, baseline: dict | None) -> int:
    """Completes scraped removed rows from the stable baseline.

    Cancelled lessons arrive with a bare clock and short names; matching
    their start time against the stable day fills the period number (so
    the timetable grid can place them) and completes subject, teacher
    and room from the closest stable variant. Returns the enriched row
    count. Never raises.
    """
    if not timetable or not baseline:
        return 0
    enriched = 0
    for day_key, lessons in timetable.items():
        try:
            day = parse_cz_date(day_key)
        except Exception:
            continue
        if day is None:
            continue
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            try:
                if str(raw.get("type") or "").strip().lower() != "removed":
                    continue
                clock = lesson_clock(raw, day=day_key)
                if clock is None:
                    continue
                period = _period_of(raw, day_key)
                if period is None:
                    period = _period_by_clock(baseline, day.weekday(), clock)
                if period is None:
                    continue
                slot = baseline.get((day.weekday(), period))
                variant = closest_variant(slot, raw, day_key)
                raw["period"] = period
                if variant is not None:
                    # The stable slot is ground truth for *what* was
                    # cancelled; removedinfo stays in notice/change.
                    raw["subject"] = variant.subject
                    raw["teacher"] = variant.teacher
                    raw["room"] = variant.room
                enriched += 1
            except Exception:
                continue
    return enriched


#: Feed badges (Suplovani view) mapped to timetable change codes.
FEED_BADGE_CODES = {
    "M": "RoomChanged",
    "O": "Removed",
    "S": "Substitution",
    "N": "Added",
    "A": "Absence",
}


def _feed_day_lessons(timetable: dict | None, day) -> tuple[str, list] | tuple[None, list]:
    """Timetable (day_key, lessons) whose date equals ``day``."""
    for day_key, lessons in (timetable or {}).items():
        try:
            if parse_cz_date(day_key) == day:
                return day_key, lessons or []
        except Exception:
            continue
    return None, []


def apply_substitution_feed(
    timetable: dict | None,
    substitutions: list | None,
) -> int:
    """Stamps Suplovani feed entries onto scraped lessons.

    The feed is the authoritative per-student change list. For every
    entry the matching actual lesson (same day + period, else same
    day + clock) gains the feed's change code and description when it
    does not already carry them, so live classification flags it even
    when the timetable row arrived without signals. A cancelled (badge
    O) entry with no matching lesson synthesizes a cancelled shell
    (later enriched by backfill_stable_facts). Returns the number of
    stamped or synthesized lessons. Never raises.
    """
    if not timetable or not substitutions:
        return 0
    stamped = 0
    for entry in substitutions:
        try:
            if not isinstance(entry, dict):
                continue
            day = parse_cz_date(entry.get("day"))
            if day is None:
                continue
            try:
                period = int(entry.get("period")) if entry.get("period") is not None else None
            except (TypeError, ValueError):
                period = None
            badge = str(entry.get("badge") or "").strip().upper()
            code = FEED_BADGE_CODES.get(badge, "")
            description = str(entry.get("description") or "").strip()
            clock = parse_time_range(entry.get("time"))
            start = None
            try:
                if clock is not None:
                    start = clock[0] * 60 + clock[1]
            except (TypeError, ValueError):
                start = None
            day_key, lessons = _feed_day_lessons(timetable, day)
            match = None
            for raw in lessons:
                if not isinstance(raw, dict):
                    continue
                if period is not None:
                    try:
                        lesson_period = _period_of(raw, day_key)
                    except Exception:
                        lesson_period = None
                    if lesson_period is not None:
                        if lesson_period == period:
                            match = raw
                            break
                        continue
                    # Lesson period unknown (e.g. a bare-clock cancelled
                    # row awaiting backfill): fall through to the clock.
                if start is not None:
                    try:
                        lesson_clock_value = lesson_clock(raw, day=day_key)
                    except Exception:
                        lesson_clock_value = None
                    if lesson_clock_value is not None and lesson_clock_value[0] == start:
                        match = raw
                        break
            if match is None:
                if badge != "O" or day_key is None:
                    # Never invent a day that was not scraped this run: the
                    # cache merge would let that one-lesson shell replace
                    # the day's known lessons (absences included).
                    continue
                lessons = timetable[day_key]
                match = {
                    "subject": str(entry.get("subject_short") or "").strip(),
                    "teacher": "",
                    "room": "",
                    "time": str(entry.get("time") or "").strip(),
                    "date": day_key,
                    "notice": description,
                    "change": description,
                    "status": "cancelled",
                    "type": "removed",
                    "removedinfo": description,
                    "infoChangeCode": "Removed",
                    "changeBadgeChar": "O",
                }
                if period is not None:
                    match["period"] = period
                lessons.append(match)
                stamped += 1
                continue
            changed = False
            if badge == "O":
                try:
                    status = Lesson.from_legacy(match, day=day_key).status
                except Exception:
                    status = ""
                if status != "cancelled":
                    match["status"] = "cancelled"
                    match["type"] = "removed"
                    if description and description not in str(match.get("removedinfo") or ""):
                        match["removedinfo"] = description
                    changed = True
            else:
                if code and not str(match.get("infoChangeCode") or "").strip():
                    match["infoChangeCode"] = code
                    changed = True
            if description:
                notice = str(match.get("notice") or "")
                if description not in notice:
                    match["notice"] = (notice + " | " + description).strip(" |") if notice else description
                    changed = True
            if changed:
                stamped += 1
        except Exception:
            continue
    return stamped


def _variants(slot_value: SlotBaseline | list[SlotBaseline] | dict | None) -> list[SlotBaseline]:
    """Normalizes a baseline slot to a variant list (split-group safe)."""
    if isinstance(slot_value, list):
        return [v for v in slot_value if isinstance(v, SlotBaseline)]
    if isinstance(slot_value, SlotBaseline):
        return [slot_value]
    return []


def _field_diffs(parsed: Lesson, clock_start: int | None,
                 variant: SlotBaseline) -> list[str]:
    """Field names where a parsed lesson differs from one stable variant."""
    changed: list[str] = []
    if _norm_text(parsed.subject) != _norm_text(variant.subject):
        changed.append("subject")
    if _surname(parsed.teacher) != _surname(variant.teacher):
        changed.append("teacher")
    if _norm_text(parsed.room) != _norm_text(variant.room):
        changed.append("room")
    if (clock_start is not None and variant.start_min is not None
            and clock_start != variant.start_min):
        changed.append("time")
    return changed


def closest_variant(slot_value: SlotBaseline | list[SlotBaseline] | dict | None,
                    raw: dict, day: Any = None) -> SlotBaseline | None:
    """The stable variant a lesson resembles most (fewest field diffs).

    Used to render "usual vs actual" for split-group slots; None when the
    slot has no usable baseline.
    """
    variants = _variants(slot_value)
    if not variants:
        return None
    parsed = Lesson.from_legacy(raw or {}, day=day)
    clock = lesson_clock(raw or {}, day=day)
    start = clock[0] if clock else None
    return min(variants, key=lambda v: len(_field_diffs(parsed, start, v)))


def stable_template_week(
    baseline: dict | None,
    monday: date | None = None,
) -> dict[date, list[dict]]:
    """Renders the baseline as plain lesson dicts on one Mon–Sun week.

    Used for the "Stálý" template view and as the fallback day plan when
    no concrete week was fetched. ``monday`` anchors the week (any date
    in the target week works); defaults to this week. Lesson dicts carry
    subject/teacher/room plus ``"<period> (<HH:MM>)"`` clocks (start only
    — the baseline stores no end times), so period parsing and the grid
    work unchanged while clock comparison stays skipped.
    """
    if monday is None:
        monday = date.today() - timedelta(days=date.today().weekday())
    else:
        monday = monday - timedelta(days=monday.weekday())
    days: dict[date, list[dict]] = {}
    for slot_key, slot_value in (baseline or {}).items():
        try:
            weekday, period = slot_key
            weekday_i, period_i = int(weekday), int(period)
        except (TypeError, ValueError):
            continue
        if not 0 <= weekday_i <= 6:
            continue
        variants = slot_value if isinstance(slot_value, list) else [slot_value]
        for variant in variants:
            if isinstance(variant, SlotBaseline):
                subject = variant.subject
                teacher = variant.teacher
                room = variant.room
                start = variant.start_min
            elif isinstance(variant, dict):
                from .helpers import short_room_name as _short_room

                subject = str(variant.get("subject", "") or "")
                teacher = str(variant.get("teacher", "") or "")
                room = _short_room(str(variant.get("room", "") or ""))
                start = variant.get("start_min")
            else:
                continue
            try:
                start_i = int(start) if start is not None else None
            except (TypeError, ValueError):
                start_i = None
            if start_i is not None:
                time_label = f"{period_i} ({start_i // 60}:{start_i % 60:02d})"
            else:
                time_label = f"{period_i}"
            day = monday + timedelta(days=weekday_i)
            days.setdefault(day, []).append({
                "subject": subject, "teacher": teacher, "room": room,
                "time": time_label,
            })
    for lessons in days.values():
        lessons.sort(key=lambda raw: (_p if (_p := _period_of(raw, None)) is not None else 999))
    return dict(sorted(days.items()))


@dataclass
class LessonDiff:
    """Classification of one actual lesson against the stable baseline."""

    is_change: bool = False
    changed: list[str] = field(default_factory=list)  # subject/teacher/room/time/status
    note: str = ""  # teacher description — always shown, never a change by itself


def classify_lesson(
    raw: dict,
    day: Any = None,
    baseline: dict[tuple[int, int], SlotBaseline] | None = None,
    complete: bool = False,
) -> LessonDiff:
    """Compares one lesson against the stable baseline.

    A bare teacher note (description) with identical subject/teacher/room/
    time is a *note*, not a change. Attendance states of the student
    (absent/late/early/excused) are likewise not schedule changes — they
    belong to excuses, not to "week changes". Cancelled lessons and real
    field differences are changes. Split-group slots (several stable
    variants) match when the lesson equals ANY variant.

    ``complete`` marks a complete template-week baseline (scraped "Stálý"
    view): an actual lesson in a slot the template leaves empty is an
    ``added`` change even without signals. Without a complete baseline an
    empty slot only means "no data", so the notice-keyword heuristic
    decides instead.
    """
    parsed = Lesson.from_legacy(raw or {}, day=day)
    note = parsed.change or ""
    status = (parsed.status or "").lower()

    if status == "cancelled":
        return LessonDiff(is_change=True, changed=["status"], note=note)

    raw_dict = raw if isinstance(raw, dict) else {}
    info_code = str(raw_dict.get("infoChangeCode") or "").strip().lower()
    # Bakalari's own verdict: an explicit change code (e.g. RoomChanged) or
    # a "removed" (cancelled) row is a change even when the teacher notice
    # is empty and no baseline is available to diff against.
    flagged = (
        str(raw_dict.get("type") or "").strip().lower() == "removed"
        or (bool(info_code) and info_code != "nochange")
    )

    day_obj = parsed.day
    period = parsed.period
    if period is None and day_obj is not None and baseline:
        # Cancelled rows carry a bare clock ("13:40 - 14:25") with no
        # period number — resolve the slot via the stable day's clocks.
        try:
            period = _period_by_clock(
                baseline, day_obj.weekday(), lesson_clock(raw_dict, day=day))
        except Exception:
            period = None
    if day_obj is None or period is None or not baseline:
        # No baseline to diff against: the teacher notice, or Bakalari's
        # own change flag, decides. Negated notices ("Neodpadá - beze
        # změny") embed a keyword stem but mean no change (same guard as
        # models.cancel_negated).
        lowered = note.lower()
        if flagged or (note and not cancel_negated(note)
                       and any(k in lowered for k in CHANGE_KEYWORDS)):
            return LessonDiff(is_change=True, changed=["notice"], note=note)
        return LessonDiff(is_change=False, changed=[], note=note)

    slot = baseline.get((day_obj.weekday(), period))
    variants = _variants(slot)
    if not variants:
        if complete:
            # Complete template week: the slot is a free period, so any
            # actual lesson there is an added hour — even with no notice
            # or change code on it.
            return LessonDiff(is_change=True, changed=["added"], note=note)
        lowered = note.lower()
        if flagged or (note and not cancel_negated(note)
                       and any(k in lowered for k in CHANGE_KEYWORDS)):
            return LessonDiff(is_change=True, changed=["notice"], note=note)
        return LessonDiff(is_change=False, changed=[], note=note)

    clock = lesson_clock(raw or {}, day=day)
    start = clock[0] if clock else None
    diffs = [_field_diffs(parsed, start, variant) for variant in variants]
    best = min(diffs, key=len)
    if not best:
        if flagged:
            return LessonDiff(is_change=True, changed=["notice"], note=note)
        return LessonDiff(is_change=False, changed=[], note=note)
    return LessonDiff(is_change=True, changed=best, note=note)


def _missing_changes(
    timetable: dict,
    baseline: dict | None,
) -> list[dict[str, Any]]:
    """Stable slots with no actual lesson on a fetched day.

    Complete template weeks only: every fetched school day is expected to
    carry each of its weekday slots, so a slot with no actual lesson of
    that period is a ``missing`` change. Split-group slots (variant lists)
    count as covered when ANY variant's period is present — one of the
    rooms being taught means no change. Cancelled rows already carry their
    backfilled period and count as present (they are flagged separately as
    a status change). Never raises.
    """
    out: list[dict[str, Any]] = []
    for day_key, lessons in (timetable or {}).items():
        try:
            day = parse_cz_date(day_key)
        except Exception:
            continue
        if day is None:
            continue
        present: set[int] = set()
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            try:
                period = _period_of(raw, day_key)
            except Exception:
                period = None
            if period is not None:
                try:
                    present.add(int(period))
                except (TypeError, ValueError):
                    pass
        for slot_key, slot_value in (baseline or {}).items():
            try:
                weekday, period = slot_key
                weekday_i, period_i = int(weekday), int(period)
            except (TypeError, ValueError):
                continue
            if weekday_i != day.weekday() or period_i in present:
                continue
            variants = _variants(slot_value)
            if not variants:
                continue
            first = variants[0]
            try:
                start = int(first.start_min) if first.start_min is not None else None
            except (TypeError, ValueError):
                start = None
            if start is not None:
                time_label = f"{period_i} ({start // 60}:{start % 60:02d})"
            else:
                time_label = f"{period_i}"
            lesson = {
                "subject": first.subject, "teacher": first.teacher,
                "room": first.room, "time": time_label,
                "date": day_key, "period": period_i,
                "group": "", "theme": "", "notice": "", "status": "",
            }
            out.append({"day_key": day_key, "day": day,
                        "lesson": lesson,
                        "diff": LessonDiff(is_change=True, changed=["missing"], note="")})
    return out


def iter_changes(
    timetable: dict,
    baseline: dict[tuple[int, int], SlotBaseline] | None = None,
    complete: bool = False,
) -> list[dict[str, Any]]:
    """Real schedule changes across the timetable (notes excluded).

    Each item holds day_key, day, lesson and diff. Without a ``baseline``
    Bakaláři's own change flags and notices decide. With ``complete=True`` (scraped template week) an actual
    lesson in a free slot is an ``added`` change and a stable slot with no
    actual lesson on a fetched day is a ``missing`` change.
    """
    baseline = baseline or {}
    out: list[dict[str, Any]] = []
    for day_key, lessons in (timetable or {}).items():
        day = parse_cz_date(day_key)
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            diff = classify_lesson(raw, day=day_key, baseline=baseline,
                                   complete=complete)
            if diff.is_change:
                out.append({"day_key": day_key, "day": day,
                            "lesson": raw, "diff": diff})
    if complete and baseline:
        try:
            out.extend(_missing_changes(timetable, baseline))
        except Exception:
            pass
    return out


def iter_notes(
    timetable: dict,
    baseline: dict[tuple[int, int], SlotBaseline] | None = None,
    complete: bool = False,
) -> list[dict[str, Any]]:
    """Lessons carrying a teacher note that is NOT a schedule change."""
    baseline = baseline or {}
    out: list[dict[str, Any]] = []
    for day_key, lessons in (timetable or {}).items():
        day = parse_cz_date(day_key)
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            diff = classify_lesson(raw, day=day_key, baseline=baseline,
                                   complete=complete)
            if not diff.is_change and diff.note:
                out.append({"day_key": day_key, "day": day,
                            "lesson": raw, "diff": diff})
    return out
