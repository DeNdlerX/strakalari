"""Wake-up alarm before the first lesson, and the Android home-screen widget.

Everything here is pure (no Android runtime: tests and the desktop app run
it as is) except :func:`sync_android`, which hands the results to the
phone's Java side through :mod:`strakalari.core.android`.

Both results are plans the phone carries out while Python isn't running:
the alarm queue covers the next two weeks (``AlarmReceiver`` arms one
alarm after another), and the widget data carries dates and clock times
instead of "today" / "now", so the widget itself works out the day to show
and the running lesson, also after midnight or between lessons.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, time as dtime, timedelta
from typing import Any

from .helpers import extract_lesson_num, short_time, teacher_surname
from .i18n import get_language, t
from .models import Lesson, parse_cz_date
from .planned_skips import entry_days, load_planned_skips
from .schedule import classify_lesson, lesson_clock, stable_template_week
from .school_presets import effective_calendar

DEFAULT_WAKEUP_MINUTES = 60
MIN_WAKEUP_MINUTES = 1
MAX_WAKEUP_MINUTES = 720
#: Days ahead the alarm queue covers (the phone rings them without the app).
ALARM_HORIZON_DAYS = 14
#: Days the widget can show: from this week's Monday on.
WIDGET_SPAN_DAYS = 21
#: Config keys the widget data or the alarms depend on (others need no sync).
PHONE_CONFIG_KEYS = frozenset({
    "wakeup_enabled", "wakeup_minutes_before", "wakeup_skip_dates", "planned_skips",
    "school_preset_id", "user_free_days", "holidays", "forced_school_days", "language",
})
#: A lesson known only by its start (the stable timetable has no end times).
_LESSON_MIN = 45
_START_RE = re.compile(r"(\d{1,2}):(\d{2})")

_DAY_NAMES = {
    "cs": ["Pondělí", "Úterý", "Středa", "Čtvrtek", "Pátek", "Sobota", "Neděle"],
    "en": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
}

#: Attendance statuses -> (widget badge, row status the widget colors by).
_STATUS_ROWS = {
    "cancelled": ("widget_cancelled", "cancelled"),
    "absent": ("widget_absent", "absent"),
    "excused": ("widget_excused", "excused"),
    "late": ("widget_late", "late"),
    "soon": ("widget_left_early", "late"),
    "early": ("widget_left_early", "late"),
}


@dataclass(frozen=True)
class WakeupAlarm:
    """One wake-up alarm, ``minutes_before`` ahead of the day's first lesson."""

    day: date
    alarm_dt: datetime
    lesson_start_dt: datetime
    period: int | None
    subject: str
    room: str
    minutes_before: int

    @property
    def alarm_time_label(self) -> str:
        return self.alarm_dt.strftime("%H:%M")

    @property
    def lesson_time_label(self) -> str:
        return self.lesson_start_dt.strftime("%H:%M")


def clamp_wakeup_minutes(value: Any, default: int = DEFAULT_WAKEUP_MINUTES) -> int:
    """``wakeup_minutes_before`` as a whole number within ``[1, 720]``."""
    try:
        parsed = int(float(str(value).strip().replace(",", ".")))
    except (TypeError, ValueError):
        return default
    return max(MIN_WAKEUP_MINUTES, min(MAX_WAKEUP_MINUTES, parsed))


def skipped_days(config_data: dict | None) -> set[date]:
    """Days the user switched the alarm off for (``wakeup_skip_dates``)."""
    raw = (config_data or {}).get("wakeup_skip_dates") or []
    out: set[date] = set()
    for value in raw if isinstance(raw, list) else []:
        try:
            out.add(date.fromisoformat(str(value)))
        except ValueError:
            continue
    return out


def with_skipped_day(config_data: dict | None, day: date, skip: bool,
                     today: date | None = None) -> list[str]:
    """``wakeup_skip_dates`` with ``day`` added or removed; past days dropped."""
    today = today or date.today()
    days = {d for d in skipped_days(config_data) if d >= today}
    if skip:
        days.add(day)
    else:
        days.discard(day)
    return [d.isoformat() for d in sorted(days)]


# -- timetable access ---------------------------------------------------------------

def _period_of(raw: dict, day: Any) -> int | None:
    """Lesson number (the timetable view's rule: the clock text, else the row)."""
    parsed = Lesson.from_legacy(raw, day=day)
    num = extract_lesson_num(parsed.time)
    if num is None:
        num = parsed.period
    try:
        return int(num) if num is not None else None
    except (TypeError, ValueError):
        return None


def _cancelled(raw: dict, day: Any) -> bool:
    return str(Lesson.from_legacy(raw, day=day).status or "").lower() == "cancelled"


def _index_days(timetable: dict | None) -> dict[date, list[dict]]:
    """``{date: lessons}`` from cache keys in any accepted day format."""
    out: dict[date, list[dict]] = {}
    for key, lessons in (timetable or {}).items():
        day = parse_cz_date(key)
        if day is not None and isinstance(lessons, list):
            out[day] = [r for r in lessons if isinstance(r, dict)]
    return out


def _lessons_for(days: dict[date, list[dict]], day: date,
                 stable_baseline: dict | None) -> list[dict]:
    """The day's lessons; past the cached weeks, the stable timetable's."""
    if day in days:
        return days[day]
    if stable_baseline and day.weekday() < 5:
        week = stable_template_week(stable_baseline, day - timedelta(days=day.weekday()))
        return [r for r in (week.get(day) or []) if isinstance(r, dict)]
    return []


@dataclass(frozen=True)
class _Slot:
    """A lesson number's usual clock: minutes since midnight plus its label."""

    start: int
    end: int
    label: str


def _period_slots(days: dict[date, list[dict]]) -> dict[int, _Slot]:
    """The most common clock of each lesson number across the cached weeks."""
    counts: dict[int, Counter] = {}
    for day, lessons in days.items():
        for raw in lessons:
            period = _period_of(raw, day)
            clock = lesson_clock(raw, day=day)
            if period is None or clock is None:
                continue
            label = short_time(Lesson.from_legacy(raw, day=day).time)
            counts.setdefault(period, Counter())[(clock[0], clock[1], label)] += 1
    return {p: _Slot(*c.most_common(1)[0][0]) for p, c in counts.items()}


def _clock_of(raw: dict, day: date, period: int | None,
              slots: dict[int, _Slot]) -> tuple[int, int] | None:
    """(start, end) minutes. A lesson without its own range takes its number's
    usual one, else its start alone (``1 (8:00)`` in the stable timetable)."""
    clock = lesson_clock(raw, day=day)
    if clock is None and period in slots:
        clock = (slots[period].start, slots[period].end)
    if clock is None:
        match = _START_RE.search(str(Lesson.from_legacy(raw, day=day).time or ""))
        if match and int(match.group(1)) < 24 and int(match.group(2)) < 60:
            start = int(match.group(1)) * 60 + int(match.group(2))
            clock = (start, start + _LESSON_MIN)
    return clock


# -- wake-up alarm --------------------------------------------------------------------

def _planned_off(day: date, period: int | None, planned: list[dict]) -> bool:
    """True when a planned absence covers lesson ``period`` on ``day``.

    The planner's rule: ``start_period`` limits the first day, ``end_period``
    the last, the days between are whole; a lesson without a number counts
    as covered.
    """
    for entry in planned:
        covered = entry_days(entry)
        if day not in covered:
            continue
        first = entry.get("start_period") if day == covered[0] else None
        last = entry.get("end_period") if day == covered[-1] else None
        if period is None:
            return True
        if (first is None or period >= first) and (last is None or period <= last):
            return True
    return False


def _first_lesson(lessons: list[dict], day: date, planned: list[dict],
                  slots: dict[int, _Slot]) -> tuple[int, int | None, dict] | None:
    """(start minutes, period, lesson) of the day's first attended lesson."""
    best: tuple[tuple[int, int], int | None, dict] | None = None
    for raw in lessons:
        if _cancelled(raw, day):
            continue
        period = _period_of(raw, day)
        if _planned_off(day, period, planned):
            continue
        clock = _clock_of(raw, day, period, slots)
        if clock is None:
            continue
        key = (clock[0], period if period is not None else 99)
        if best is None or key < best[0]:
            best = (key, period, raw)
    if best is None:
        return None
    return best[0][0], best[1], best[2]


def upcoming_wakeup_alarms(
    timetable: dict | None,
    config_data: dict | None = None,
    *,
    now: datetime | None = None,
    stable_baseline: dict | None = None,
    horizon_days: int = ALARM_HORIZON_DAYS,
) -> list[WakeupAlarm]:
    """The wake-up alarms from ``now`` up to ``horizon_days`` ahead, earliest first.

    One per school day, ``wakeup_minutes_before`` ahead of the first lesson
    actually attended: cancelled lessons and planned absences don't count,
    free days (school calendar) and ``wakeup_skip_dates`` get none. Past
    the cached weeks the stable timetable stands in. Alarms already past
    are left out; empty while the alarm is off.
    """
    cfg = config_data or {}
    if not cfg.get("wakeup_enabled"):
        return []
    now = now or datetime.now()
    minutes = clamp_wakeup_minutes(cfg.get("wakeup_minutes_before", DEFAULT_WAKEUP_MINUTES))
    skipped = skipped_days(cfg)
    try:
        free_days = effective_calendar(cfg, clip=False)[0]
    except Exception:  # noqa: BLE001 - a broken calendar must not stop the alarm
        free_days = set()
    planned = load_planned_skips(cfg)
    days = _index_days(timetable)
    slots = _period_slots(days)

    alarms: list[WakeupAlarm] = []
    for ahead in range(max(0, horizon_days) + 1):
        day = now.date() + timedelta(days=ahead)
        if day in skipped or day in free_days:
            continue
        first = _first_lesson(_lessons_for(days, day, stable_baseline), day, planned, slots)
        if first is None:
            continue
        start, period, raw = first
        lesson_dt = datetime.combine(day, dtime(start // 60, start % 60))
        alarm_dt = lesson_dt - timedelta(minutes=minutes)
        if alarm_dt <= now:
            continue
        parsed = Lesson.from_legacy(raw, day=day)
        alarms.append(WakeupAlarm(
            day=day,
            alarm_dt=alarm_dt,
            lesson_start_dt=lesson_dt,
            period=period,
            subject=str(parsed.subject or "?"),
            room=str(parsed.room or ""),
            minutes_before=minutes,
        ))
    return alarms


def next_wakeup_alarm(
    timetable: dict | None,
    config_data: dict | None = None,
    *,
    now: datetime | None = None,
    stable_baseline: dict | None = None,
) -> WakeupAlarm | None:
    """The next wake-up alarm, or None (see :func:`upcoming_wakeup_alarms`)."""
    alarms = upcoming_wakeup_alarms(timetable, config_data, now=now,
                                    stable_baseline=stable_baseline)
    return alarms[0] if alarms else None


def alarm_queue(alarms: list[WakeupAlarm], lang: str | None = None) -> list[dict]:
    """What ``AlarmReceiver`` rings: epoch ms (alarm, lesson start) and the texts."""
    queue: list[dict] = []
    for alarm in alarms:
        bits = [t("wakeup_alarm_period", lang=lang, n=alarm.period)
                if alarm.period is not None else t("wakeup_alarm_first", lang=lang)]
        if alarm.room:
            bits.append(t("wakeup_alarm_room", lang=lang, room=alarm.room))
        queue.append({
            "at": int(alarm.alarm_dt.timestamp() * 1000),
            "lesson": int(alarm.lesson_start_dt.timestamp() * 1000),
            "title": t("wakeup_alarm_title", lang=lang, subject=alarm.subject,
                       time=alarm.lesson_time_label),
            "text": " · ".join(bits),
        })
    return queue


# -- home-screen widget ---------------------------------------------------------------

def _unique(values) -> list[str]:
    out: list[str] = []
    for value in values:
        value = str(value or "").strip()
        if value and value not in out:
            out.append(value)
    return out


def _lessons_label(count: int, lang: str) -> str:
    if count == 1:
        key = "widget_lessons_one"
    elif 2 <= count <= 4:
        key = "widget_lessons_few"
    else:
        key = "widget_lessons_many"
    return t(key, lang=lang, n=count)


def _lesson_row(raws: list[dict], day: date, period: int | None, slots: dict[int, _Slot],
                stable_baseline: dict | None, stable_complete: bool, lang: str) -> dict:
    """One widget row; split-group lessons sharing a period are joined."""
    active = [r for r in raws if not _cancelled(r, day)] or raws
    parsed_all = [Lesson.from_legacy(r, day=day) for r in active]
    parsed = parsed_all[0]
    status = str(parsed.status or "").lower()
    if status in _STATUS_ROWS:
        badge_key, row_status = _STATUS_ROWS[status]
        badge = t(badge_key, lang=lang)
    else:
        try:
            diff = classify_lesson(active[0], day=day, baseline=stable_baseline or {},
                                   complete=stable_complete)
        except Exception:  # noqa: BLE001 - an unclassifiable lesson is shown plain
            diff = None
        changed = set(diff.changed) if diff is not None and diff.is_change else set()
        if not changed:
            badge, row_status = "", "normal"
        else:
            if "added" in changed:
                badge_key = "widget_added"
            elif "teacher" in changed:
                badge_key = "widget_substitution"
            elif "room" in changed and not changed - {"room", "notice"}:
                badge_key = "widget_room_change"
            else:
                badge_key = "widget_change"
            badge, row_status = t(badge_key, lang=lang), "change"
    clock = _clock_of(active[0], day, period, slots)
    time_label = short_time(parsed.time)
    if period in slots and (not time_label or lesson_clock(active[0], day=day) is None):
        time_label = slots[period].label  # the full range, not just "8:00"
    rooms = ", ".join(_unique(p.room for p in parsed_all))
    teachers = ", ".join(_unique(teacher_surname(p.teacher) for p in parsed_all))
    return {
        "kind": "lesson",
        "period": f"{period}." if period is not None else "",
        "time": time_label,
        "subject": " / ".join(_unique(p.subject for p in parsed_all)) or "?",
        "meta": " · ".join(part for part in (rooms, teachers) if part),
        "badge": badge,
        "status": row_status,
        "start": clock[0] if clock else -1,
        "end": clock[1] if clock else -1,
    }


def build_widget_day_rows(
    lessons: list[dict],
    day: date,
    *,
    slots: dict[int, _Slot] | None = None,
    stable_baseline: dict | None = None,
    stable_complete: bool = False,
    lang: str | None = None,
) -> list[dict]:
    """The day's widget rows: lessons in period order with the free periods
    between them (from period 1, or 0 when the day has one) as empty
    ``"pause"`` rows; lessons without a number come last."""
    lang = "en" if (lang or get_language()) == "en" else "cs"
    clean = [r for r in (lessons or []) if isinstance(r, dict)]
    if slots is None:
        slots = _period_slots({day: clean})
    by_period: dict[int, list[dict]] = {}
    unnumbered: list[dict] = []
    for raw in clean:
        period = _period_of(raw, day)
        if period is None:
            unnumbered.append(raw)
        else:
            by_period.setdefault(period, []).append(raw)

    rows: list[dict] = []
    if by_period:
        for period in range(min(1, min(by_period)), max(by_period) + 1):
            if period in by_period:
                rows.append(_lesson_row(by_period[period], day, period, slots,
                                        stable_baseline, stable_complete, lang))
                continue
            slot = slots.get(period)
            rows.append({
                "kind": "pause",
                "period": f"{period}.",
                "time": slot.label if slot else "",
                "subject": "",
                "meta": "",
                "badge": "",
                "status": "pause",
                "start": -1,
                "end": -1,
            })
    for raw in unnumbered:
        rows.append(_lesson_row([raw], day, None, slots, stable_baseline, stable_complete, lang))
    return rows


def build_widget_payload(
    timetable: dict | None,
    config_data: dict | None = None,
    *,
    now: datetime | None = None,
    stable_baseline: dict | None = None,
    stable_complete: bool = False,
    lang: str | None = None,
) -> dict:
    """The home-screen widget's data (JSON-serializable).

    Days run from this week's Monday for three weeks (weekends only with
    lessons). Nothing in it says "today" or "now": each day carries its ISO
    date and each lesson its clock minutes, and the widget picks the day to
    show and highlights the running / next lesson itself.
    """
    now = now or datetime.now()
    lang = "en" if (lang or get_language()) == "en" else "cs"
    try:
        free_days, free_labels, _ = effective_calendar(config_data or {}, clip=False)
    except Exception:  # noqa: BLE001 - a broken calendar must not hide the timetable
        free_days, free_labels = set(), {}
    days = _index_days(timetable)
    slots = _period_slots(days)
    names = _DAY_NAMES[lang]
    monday = now.date() - timedelta(days=now.weekday())

    out: list[dict] = []
    for offset in range(WIDGET_SPAN_DAYS):
        day = monday + timedelta(days=offset)
        lessons = _lessons_for(days, day, stable_baseline)
        if day.weekday() >= 5 and not lessons:
            continue
        rows = build_widget_day_rows(lessons, day, slots=slots, stable_baseline=stable_baseline,
                                     stable_complete=stable_complete, lang=lang)
        taught = [r for r in rows if r["kind"] == "lesson" and r["status"] != "cancelled"]
        free = day in free_days
        if free:
            subtitle = free_labels.get(day) or t("widget_day_off", lang=lang)
        elif taught:
            subtitle = _lessons_label(len(taught), lang)
        else:
            subtitle = t("widget_no_lessons", lang=lang)
        ends = [r["end"] for r in taught if r["end"] >= 0]
        out.append({
            "iso": day.isoformat(),
            "label": f"{names[day.weekday()]} {day.day}. {day.month}.",
            "subtitle": subtitle,
            "free": free,
            "taught": len(taught),
            "end": max(ends) if ends else -1,
            "rows": rows,
        })
    return {
        "today": t("widget_today", lang=lang),
        "tomorrow": t("widget_tomorrow", lang=lang),
        "empty": t("widget_no_lessons" if days else "widget_no_data", lang=lang),
        "days": out,
    }


# -- hand-over to the phone -----------------------------------------------------------

#: What the phone was last given (only changes are sent again).
_sent: dict[str, str] = {}


def sync_android(
    timetable: dict | None,
    config_data: dict | None = None,
    *,
    stable_baseline: dict | None = None,
    stable_complete: bool = False,
    now: datetime | None = None,
) -> None:
    """Hands the widget data and the alarm queue to the phone; a no-op elsewhere.

    Runs on every config save and cache reload, so only changes are sent.
    """
    from . import android

    if not android.available():
        return
    now = now or datetime.now()
    lang = "en" if get_language() == "en" else "cs"
    try:
        widget = json.dumps(
            build_widget_payload(timetable, config_data, now=now, stable_baseline=stable_baseline,
                                 stable_complete=stable_complete, lang=lang),
            ensure_ascii=False, sort_keys=True)
        if _sent.get("widget") != widget and android.update_timetable_widget(widget):
            _sent["widget"] = widget
    except Exception as exc:  # noqa: BLE001 - the widget is best effort
        print(f"Warning: widget sync failed ({type(exc).__name__}: {exc})")
    try:
        alarms = upcoming_wakeup_alarms(timetable, config_data, now=now,
                                        stable_baseline=stable_baseline)
        queue = json.dumps(alarm_queue(alarms, lang), ensure_ascii=False, sort_keys=True)
        if _sent.get("alarms") != lang + queue and android.set_wakeup_alarms(
                queue, t("wakeup_channel", lang=lang), t("wakeup_dismiss", lang=lang)):
            _sent["alarms"] = lang + queue
    except Exception as exc:  # noqa: BLE001
        print(f"Warning: wake-up alarm sync failed ({type(exc).__name__}: {exc})")
