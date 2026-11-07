"""The phone's always-on notification as a glanceable overview.

While background running is on, Android keeps the background service's
notification in the shade. Instead of only saying that the app runs, it
shows what the user picked under Settings → Background (``ITEMS``), a row
each (:class:`StatusRow`, drawn with an icon by the app's own notification
layout, mobile/strakalari_android: StatusViews.java):

- ``next_lesson``: the next lesson still ahead (period, subject, start,
  room and teacher, a substitution or room change marked), past today's
  last lesson the next school day's first one;
- ``lunch``: the lunch ordered for today until lunchtime is over (see
  :func:`lunch_over_at`), then the next one (the dish as Strava names it,
  or "not ordered");
- ``lunch_orders``: menu days still open for ordering with nothing
  ordered, and the earliest deadline;
- ``excuses``: how many excuses wait to be sent (also none, next to other rows);
- ``wakeup``: the next wake-up alarm (none while the alarm is off);
- ``updated``: when the data was last refreshed (the header's small text).

A row with nothing to say is left out; with no row at all the
notification keeps its plain "running in the background" text.

:func:`build_status` is pure (tests and the Settings preview run it anywhere).
:class:`StatusNotifier` keeps the phone's notification current: it
recomputes when the data or the settings change and when the clock moves
on to a new minute, and hands over only what changed.
"""

from __future__ import annotations

import json
import re
import threading
from dataclasses import dataclass, field
from datetime import date, datetime, time as dtime, timedelta
from typing import Any, Callable

from .i18n import get_language, t
from .models import canonical_day_key, parse_cz_date

#: Everything the notification can show, in the order it shows them.
ITEMS: tuple[str, ...] = ("next_lesson", "lunch", "lunch_orders", "excuses", "wakeup", "updated")
#: What a new install shows (``background_notification_items``).
DEFAULT_ITEMS: tuple[str, ...] = ("next_lesson", "lunch", "excuses", "wakeup")
#: Lunch is eaten in the first free period after this one (when lessons follow it).
LUNCH_AFTER_PERIOD = 4
#: On a day without lessons, the next lunch is shown from this time on.
LUNCH_SWITCH = dtime(15, 0)
#: How far ahead the lunch, the next lesson and open orders are looked for.
LUNCH_AHEAD_DAYS = 7
LESSON_AHEAD_DAYS = 7
ORDER_AHEAD_DAYS = 14
#: Open order days named before "and N more".
ORDER_DAYS_LISTED = 3

_DAY_SHORT = {
    "cs": ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"],
    "en": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
}
#: Weekdays as they follow a word ("Oběd v pondělí", "Lunch on Monday").
_DAY_AFTER = {
    "cs": ["v pondělí", "v úterý", "ve středu", "ve čtvrtek", "v pátek", "v sobotu", "v neděli"],
    "en": ["on Monday", "on Tuesday", "on Wednesday", "on Thursday", "on Friday",
           "on Saturday", "on Sunday"],
}
#: Weekdays standing alone ("order by Monday 12:00"); Czech keeps the "v".
_DAY_PLAIN = {
    "cs": _DAY_AFTER["cs"],
    "en": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
}
#: Trailing allergen list: "(1,3,7,9)", "(01, 07 )" (as on the Lunches screen).
_ALLERGENS_RE = re.compile(r"\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$")


def selected_items(config_data: dict | None) -> list[str]:
    """The items the user picked, in display order (unknown ids dropped)."""
    raw = (config_data or {}).get("background_notification_items", list(DEFAULT_ITEMS))
    if not isinstance(raw, (list, tuple)):
        raw = DEFAULT_ITEMS
    picked = {str(item) for item in raw}
    return [item for item in ITEMS if item in picked]


def with_item(config_data: dict | None, item: str, on: bool) -> list[str]:
    """``background_notification_items`` with ``item`` switched on or off."""
    picked = set(selected_items(config_data))
    if on:
        picked.add(item)
    else:
        picked.discard(item)
    return [i for i in ITEMS if i in picked]


@dataclass(frozen=True)
class StatusInputs:
    """What the overview is made of (a snapshot of the app's data)."""

    timetable: dict = field(default_factory=dict)
    #: ``{DD.MM.YYYY: {meal id: name}}`` (the Strava menu).
    food: dict = field(default_factory=dict)
    #: ``{DD.MM.YYYY: meal id}``: what Strava reported as ordered.
    web_orders: dict = field(default_factory=dict)
    config: dict = field(default_factory=dict)
    stable_baseline: dict | None = None
    stable_complete: bool = False
    pending_excuses: int = 0
    last_updated: datetime | None = None
    #: The school calendar's days off (None: worked out from ``config``,
    #: which reads the school presets from disk).
    free_days: frozenset | None = None


@dataclass(frozen=True)
class StatusRow:
    """One row of the overview: what it is about (an ``ITEMS`` id, its icon),
    a label and a value ("Další hodina", "1. Matematika · 8:00 · 214");
    ``short``: the value in the collapsed notification, where rows show
    without labels and the short ones (a count, a time) share a line with
    the lunch (the value itself when empty)."""

    kind: str
    label: str
    value: str
    short: str = ""

    @property
    def line(self) -> str:
        return f"{self.label}: {self.value}"


@dataclass(frozen=True)
class StatusContent:
    """The notification: its rows, the header's small text, and the same
    as a plain title and text (the first row's label; its value and the
    other rows' lines) for wherever the rows aren't drawn."""

    title: str
    text: str = ""
    sub: str = ""
    rows: tuple[StatusRow, ...] = ()

    def rows_json(self) -> str:
        """The rows for the phone's notification layout ("" without rows)."""
        if not self.rows:
            return ""
        return json.dumps([{"kind": r.kind, "label": r.label, "value": r.value,
                            "short": r.short or r.value} for r in self.rows],
                          ensure_ascii=False)


def _lang(lang: str | None) -> str:
    return "en" if (lang or get_language()) == "en" else "cs"


def _date(day: date) -> str:
    """``9. 11.``, never broken across two lines."""
    return f"{day.day}.\u00a0{day.month}."


def _day_phrase(day: date, today: date, lang: str, *, plain: bool = False) -> str:
    """When ``day`` is: "dnes" / "zítra" / "v pondělí" ("today" / "tomorrow" / "on Monday")."""
    if day == today:
        return t("status_today", lang=lang)
    if day == today + timedelta(days=1):
        return t("status_tomorrow", lang=lang)
    names = _DAY_PLAIN if plain else _DAY_AFTER
    text = names[lang][day.weekday()]
    if day - today >= timedelta(days=7):
        text += f" {_date(day)}"
    return text


def _short_day(day: date, lang: str) -> str:
    return f"{_DAY_SHORT[lang][day.weekday()]} {_date(day)}"


def _clock(minutes: int) -> str:
    return f"{minutes // 60}:{minutes % 60:02d}"


def meal_text(name: Any) -> str:
    """A Strava meal name for one line: spacing tidied, allergens dropped.

    ``"oběd 1 - Polévka,Řízek(01, 07 )"`` -> ``"Oběd 1 - Polévka, Řízek"``.
    """
    text = re.sub(r",(\S)", r", \1", str(name or ""))
    text = re.sub(r"\s+\)", ")", re.sub(r"(\S)\(", r"\1 (", text))
    text = _ALLERGENS_RE.sub("", text.strip())
    text = re.sub(r"\s+", " ", text).strip(" ,;")
    return text[:1].upper() + text[1:]


def _real_meals(meals: Any) -> dict[str, str]:
    """A day's menu without the "no lunch" control (``…&-1&…``)."""
    if not isinstance(meals, dict):
        return {}
    return {str(mid): str(name) for mid, name in meals.items() if "&-1&" not in str(mid)}


def _ordered_meal(web_orders: dict, key: str) -> str:
    meal = str(web_orders.get(key) or "")
    return "" if "&-1&" in meal else meal


def _free_days(inputs: StatusInputs) -> frozenset:
    if inputs.free_days is not None:
        return inputs.free_days
    from .school_presets import effective_calendar

    try:
        return frozenset(effective_calendar(inputs.config, clip=False)[0])
    except Exception:  # noqa: BLE001 - a broken calendar must not hide the lines
        return frozenset()


def _menu_days(inputs: StatusInputs) -> dict[date, str]:
    """``{day: cache key}`` for days with a menu or an order."""
    out: dict[date, str] = {}
    for key in list(inputs.food) + list(inputs.web_orders):
        day = parse_cz_date(key)
        if day is None:
            continue
        canon = canonical_day_key(key)
        if _real_meals(inputs.food.get(canon)) or _ordered_meal(inputs.web_orders, canon):
            out[day] = canon
    return out


def lunch_over_at(inputs: StatusInputs, day: date) -> int | None:
    """Minute of ``day`` from which its lunch is over, None without lessons.

    Lunch is eaten in the first free period after the 4th lesson that has
    lessons after it, so it is over when that period ends (its usual clock,
    else when the next lesson starts). Without such a gap it is over when
    the classes end. A cancelled lesson leaves its period free.
    """
    from .wakeup import _cancelled, _clock_of, _index_days, _lessons_for, _period_of, _period_slots

    days = _index_days(inputs.timetable)
    lessons = [raw for raw in _lessons_for(days, day, inputs.stable_baseline)
               if not _cancelled(raw, day)]
    if not lessons:
        return None
    slots = _period_slots(days)
    taught: dict[int, tuple[int, int] | None] = {}
    ends: list[int] = []
    for raw in lessons:
        period = _period_of(raw, day)
        clock = _clock_of(raw, day, period, slots)
        if clock is not None:
            ends.append(clock[1])
        if period is not None and taught.get(period) is None:
            taught[period] = clock
    gaps = [p for p in range(LUNCH_AFTER_PERIOD + 1, max(taught, default=0)) if p not in taught]
    if gaps:
        gap = gaps[0]
        if gap in slots:
            return slots[gap].end
        after = taught[min(p for p in taught if p > gap)]
        if after is not None:
            return after[0]
    return max(ends) if ends else None


# -- the lines ---------------------------------------------------------------------------

def _short_when(day: date, today: date, lang: str) -> str:
    """When ``day`` is, for the collapsed notification: "" today, "zítra", "Po"."""
    if day == today:
        return ""
    if day == today + timedelta(days=1):
        return t("status_tomorrow", lang=lang)
    return _DAY_SHORT[lang][day.weekday()]


def _unless_today(day: date, today: date, lang: str, value: str) -> str:
    """``value``, for another day than today led by when ("zítra: …", "Po: …")."""
    when = _short_when(day, today, lang)
    return f"{when}: {value}" if when else value


def _lunch_row(inputs: StatusInputs, now: datetime, lang: str) -> StatusRow | None:
    """"Oběd dnes" / "Oběd 1 - Polévka, Řízek": the day and the dish."""
    today = now.date()
    over = lunch_over_at(inputs, today)
    if over is None:
        over = LUNCH_SWITCH.hour * 60 + LUNCH_SWITCH.minute
    first = today if now.hour * 60 + now.minute < over else today + timedelta(days=1)
    days = _menu_days(inputs)
    upcoming = sorted(d for d in days if first <= d <= today + timedelta(days=LUNCH_AHEAD_DAYS))
    if not upcoming:
        return None
    day = upcoming[0]
    key = days[day]
    meal = _ordered_meal(inputs.web_orders, key)
    name = (inputs.food.get(key) or {}).get(meal) if meal else None
    if not meal:
        value = t("status_lunch_none", lang=lang)
    else:
        value = meal_text(name) if name else t("status_lunch_ordered", lang=lang)
    return StatusRow("lunch", t("status_lunch", lang=lang, when=_day_phrase(day, today, lang)),
                     value, _unless_today(day, today, lang, value))


def _next_lesson_row(inputs: StatusInputs, now: datetime, lang: str) -> StatusRow | None:
    from .planned_skips import load_planned_skips
    from .wakeup import (
        _index_days, _lessons_for, _period_slots, _planned_off, build_widget_day_rows,
    )

    days = _index_days(inputs.timetable)
    if not days:
        return None
    free_days = _free_days(inputs)
    planned = load_planned_skips(inputs.config)
    slots = _period_slots(days)
    today = now.date()
    now_min = now.hour * 60 + now.minute
    for ahead in range(LESSON_AHEAD_DAYS + 1):
        day = today + timedelta(days=ahead)
        if day in free_days:
            continue
        lessons = _lessons_for(days, day, inputs.stable_baseline)
        if not lessons:
            continue
        rows = build_widget_day_rows(lessons, day, slots=slots,
                                     stable_baseline=inputs.stable_baseline,
                                     stable_complete=inputs.stable_complete, lang=lang)
        for row in rows:
            if row["kind"] != "lesson" or row["status"] == "cancelled":
                continue
            period = row["period"].rstrip(".")
            if _planned_off(day, int(period) if period.isdigit() else None, planned):
                continue
            if ahead == 0 and not row["start"] > now_min:
                continue  # already running or over (or no clock to tell)
            parts = [f"{row['period']} {row['subject']}".strip()]
            if row["start"] >= 0:
                parts.append(_clock(row["start"]))
            parts.extend(p for p in (row["meta"], row["badge"]) if p)
            lesson = " · ".join(parts)
            label = (t("status_lesson", lang=lang) if ahead == 0 else
                     t("status_lesson_on", lang=lang, when=_day_phrase(day, today, lang)))
            return StatusRow("next_lesson", label, lesson,
                             _unless_today(day, today, lang, lesson))
    return None


def _orders_row(inputs: StatusInputs, now: datetime, lang: str) -> StatusRow | None:
    """Menu days still open for ordering with nothing ordered (planned days
    off whose lunch the planner cancels don't count)."""
    from .lunch_cutoff import is_lunch_order_open, lunch_order_deadline
    from .planned_skips import planned_lunch_days
    from .school_presets import resolve_lunch_cutoff

    today = now.date()
    cutoff = resolve_lunch_cutoff(inputs.config)
    free_days = _free_days(inputs)
    skipped = planned_lunch_days(inputs.config)
    open_days: list[tuple[date, datetime]] = []
    for key, meals in inputs.food.items():
        day = parse_cz_date(key)
        canon = canonical_day_key(key)
        if (day is None or not today <= day <= today + timedelta(days=ORDER_AHEAD_DAYS)
                or not _real_meals(meals) or _ordered_meal(inputs.web_orders, canon)
                or canon in skipped):
            continue
        if is_lunch_order_open(day, now, cutoff, free_days):
            open_days.append((day, lunch_order_deadline(day, cutoff, free_days)))
    if not open_days:
        return None
    open_days.sort()
    names = ", ".join(_short_day(day, lang) for day, _ in open_days[:ORDER_DAYS_LISTED])
    if len(open_days) > ORDER_DAYS_LISTED:
        names = t("status_orders_more", lang=lang, days=names,
                  n=len(open_days) - ORDER_DAYS_LISTED)
    deadline = min(d for _, d in open_days).replace(tzinfo=None)
    by = f"{_day_phrase(deadline.date(), today, lang, plain=True)} {deadline:%H:%M}"
    return StatusRow("lunch_orders", t("status_orders", lang=lang),
                     t("status_orders_value", lang=lang, days=names, deadline=by),
                     str(len(open_days)))


def _excuses_row(inputs: StatusInputs, now: datetime, lang: str) -> StatusRow:
    n = max(0, int(inputs.pending_excuses or 0))
    return StatusRow("excuses", t("status_excuses", lang=lang), str(n))


def _wakeup_row(inputs: StatusInputs, now: datetime, lang: str) -> StatusRow | None:
    from .wakeup import next_wakeup_alarm

    alarm = next_wakeup_alarm(inputs.timetable, inputs.config, now=now,
                              stable_baseline=inputs.stable_baseline)
    if alarm is None:
        return None
    time = _clock(alarm.alarm_dt.hour * 60 + alarm.alarm_dt.minute)
    return StatusRow("wakeup", t("status_wakeup", lang=lang),
                     t("status_wakeup_value", lang=lang,
                       when=_day_phrase(alarm.day, now.date(), lang, plain=True), time=time),
                     f"{_short_when(alarm.day, now.date(), lang)} {time}".strip())


def _updated_text(inputs: StatusInputs, now: datetime, lang: str) -> str:
    stamp = inputs.last_updated
    if stamp is None:
        return ""
    when = _clock(stamp.hour * 60 + stamp.minute)
    if stamp.date() != now.date():
        when = f"{_date(stamp.date())} {when}"
    return t("status_updated", lang=lang, time=when)


def build_status(
    inputs: StatusInputs,
    now: datetime | None = None,
    *,
    fallback: tuple[str, str] = ("Strakaláři", ""),
    lang: str | None = None,
) -> StatusContent:
    """The notification for ``now``: a row per picked item with something
    to say; without any, ``fallback`` (title, text). Never raises for a
    broken item: that row is left out."""
    now = now or datetime.now()
    lang = _lang(lang)
    items = selected_items(inputs.config)
    strava = bool(inputs.config.get("use_strava", True))
    builders: dict[str, Callable[[], StatusRow | None]] = {
        "next_lesson": lambda: _next_lesson_row(inputs, now, lang),
        "lunch": lambda: _lunch_row(inputs, now, lang) if strava else None,
        "lunch_orders": lambda: _orders_row(inputs, now, lang) if strava else None,
        "excuses": lambda: _excuses_row(inputs, now, lang),
        "wakeup": lambda: _wakeup_row(inputs, now, lang),
    }
    rows: list[StatusRow] = []
    for item in items:
        build = builders.get(item)
        if build is None:
            continue
        try:
            row = build()
        except Exception as exc:  # noqa: BLE001 - one broken row must not blank the rest
            print(f"Warning: notification line {item!r} failed ({type(exc).__name__}: {exc})")
            continue
        if row is not None and row.value:
            rows.append(row)
    if all(row.kind == "excuses" and row.value == "0" for row in rows):
        rows = []  # "none to send" alone says nothing: the plain text instead
    sub = _updated_text(inputs, now, lang) if "updated" in items else ""
    if not rows:
        return StatusContent(title=fallback[0], text=fallback[1], sub=sub)
    text = "\n".join([rows[0].value, *(row.line for row in rows[1:])])
    return StatusContent(title=rows[0].label, text=text, sub=sub, rows=tuple(rows))


# -- keeping the phone's notification current -------------------------------------------

class StatusNotifier:
    """Recomputes the notification and hands over changes, in a daemon thread.

    ``gather()`` returns a fresh :class:`StatusInputs`, or None while the
    notification isn't shown (background running off): nothing is posted
    then. It runs again after :meth:`poke` (data or settings changed), on
    a new day and every ``max_age_s`` as a safety net; in between, a new
    minute recomputes from the inputs it has (the next lesson moves on,
    the lunch switches to tomorrow's). ``post(content)`` delivers; False
    means it didn't, and it is tried again a minute later.

    The loop wakes every ``tick_s`` seconds: a phone asleep in Doze runs
    no thread, and a short tick catches up within seconds of waking.
    """

    def __init__(
        self,
        gather: Callable[[], StatusInputs | None],
        post: Callable[[StatusContent], bool],
        fallback: Callable[[], tuple[str, str]] = lambda: ("Strakaláři", ""),
        *,
        tick_s: float = 5.0,
        settle_s: float = 1.0,
        max_age_s: float = 600.0,
    ) -> None:
        self.gather = gather
        self.post = post
        self.fallback = fallback
        self.tick_s = tick_s
        self.settle_s = settle_s
        self.max_age_s = max_age_s
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._dirty = True
        self._inputs: StatusInputs | None = None
        self._gathered_at: datetime | None = None
        self._minute: tuple | None = None
        self._last: StatusContent | None = None

    def poke(self) -> None:
        """The data or the settings changed: recompute soon."""
        self._dirty = True
        self._wake.set()

    def current(self, now: datetime | None = None) -> StatusContent | None:
        """Recomputes now and returns the content (counted as delivered: for
        the caller that hands it over itself, e.g. when starting the service).
        None while ``gather`` says the notification isn't shown."""
        with self._lock:
            content = self._compute(now or datetime.now(), force=True)
            if content is not None:
                self._last = content
            return content

    def tick(self, now: datetime | None = None) -> bool:
        """Recomputes when due and posts a change. True when something was posted."""
        now = now or datetime.now()
        with self._lock:
            minute = (now.date(), now.hour, now.minute)
            if not self._dirty and self._minute == minute and self._inputs is not None:
                return False
            content = self._compute(now)
            if content is None or content == self._last:
                return False
            if not self.post(content):
                return False
            self._last = content
            return True

    def _compute(self, now: datetime, force: bool = False) -> StatusContent | None:
        stale = (self._gathered_at is None or self._gathered_at.date() != now.date()
                 or abs((now - self._gathered_at).total_seconds()) >= self.max_age_s)
        if force or self._dirty or stale or self._inputs is None:
            self._dirty = False  # a poke while gathering marks it dirty again
            try:
                self._inputs = self.gather()
            except Exception:
                self._dirty = True  # try again on the next tick
                raise
            self._gathered_at = now
        self._minute = (now.date(), now.hour, now.minute)
        if self._inputs is None:
            self._last = None  # shown again later: post it afresh
            return None
        return build_status(self._inputs, now, fallback=self.fallback())

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="strakalari-status",
                                        daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception as exc:  # noqa: BLE001 - never let the thread die
                print(f"Warning: background notification update failed "
                      f"({type(exc).__name__}: {exc})")
            if self._wake.wait(self.tick_s) and not self._stop.is_set():
                self._wake.clear()
                self._stop.wait(self.settle_s)  # let a burst of changes settle
