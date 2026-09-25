"""Lunch ordering cutoff: order only until a set time on the previous business day.

Business day = Mon–Fri that is not a school free day (preset holidays +
user additions minus forced school days). The cutoff time comes from the
school preset (12:00 when the preset sets none) and can be overridden
per-user via ``lunch_order_cutoff_time`` (``HH:MM``, empty = follow preset).
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from typing import Iterable


def _last_sunday(year: int, month: int) -> date:
    """Date of the last Sunday in ``month`` (EU daylight-saving rule)."""
    import calendar as _calendar

    last_day = _calendar.monthrange(year, month)[1]
    day = date(year, month, last_day)
    return day - timedelta(days=(day.weekday() - 6) % 7)


def _prague_tz(day: date) -> timezone:
    """Fixed-offset Europe/Prague tz for ``day`` (no tz database needed).

    EU daylight saving: CEST (UTC+2) from the last Sunday in March up to
    the last Sunday in October, otherwise CET (UTC+1). Cutoffs always sit
    at midday, far from the ambiguous/overnight transition hours.
    """
    start = _last_sunday(day.year, 3)
    end = _last_sunday(day.year, 10)
    offset = timedelta(hours=2) if start <= day < end else timedelta(hours=1)
    return timezone(offset, name="Europe/Prague")


def _as_prague_moment(value: datetime) -> datetime:
    """Aware Prague datetime: naive inputs are Prague wall time, aware ones convert."""
    if value.tzinfo is None:
        return value.replace(tzinfo=_prague_tz(value.date()))
    try:
        return value.astimezone(_prague_tz(value.date()))
    except Exception:
        return value.replace(tzinfo=None)


def parse_cutoff_time(value: object, default: tuple[int, int] = (12, 0)) -> tuple[int, int]:
    """(hour, minute) from ``HH:MM``; default on anything unparseable."""
    try:
        text = str(value or "").strip()
    except Exception:
        return default
    if not text:
        return default
    parts = text.replace(".", ":").split(":")
    if len(parts) != 2:
        return default
    try:
        hour, minute = int(parts[0].strip()), int(parts[1].strip())
    except (TypeError, ValueError):
        return default
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return default
    return hour, minute


def is_valid_cutoff_time(value: object) -> bool:
    """True for empty (follow preset) or a strict ``HH:MM`` 24h time.

    Accepts the ``HH.MM`` spelling too — the runtime
    (:func:`parse_cutoff_time`) treats dots as colons, so the validator
    must accept whatever the runtime parses.
    """
    text = str(value or "").strip().replace(".", ":")
    if not text:
        return True
    import re

    if not re.fullmatch(r"\d{1,2}:\d{2}", text):
        return False
    try:
        hour, minute = int(text.split(":")[0]), int(text.split(":")[1])
    except (TypeError, ValueError):
        return False
    return 0 <= hour <= 23 and 0 <= minute <= 59


def normalize_cutoff_time(value: object, default: str = "12:00") -> str:
    """Canonical ``HH:MM`` (zero-padded) or default on bad input."""
    hour, minute = parse_cutoff_time(value, default=parse_cutoff_time(default))
    return f"{hour:02d}:{minute:02d}"


def _as_date(value: date | datetime) -> date:
    """Coerces datetimes to dates (``datetime == date`` is always False)."""
    if isinstance(value, datetime):
        return value.date()
    return value


def _normalize_free(
    free_days: set[date] | Iterable[date] | None,
) -> set[date]:
    try:
        return {_as_date(d) for d in (free_days or set())}
    except TypeError:
        return set()


def is_business_day(day: date, free_days: set[date] | Iterable[date] | None = None) -> bool:
    """Mon–Fri and not in the school free-day set."""
    day = _as_date(day)
    if day.weekday() >= 5:
        return False
    try:
        return day not in _normalize_free(free_days)
    except TypeError:
        return day.weekday() < 5


def previous_business_day(day: date, free_days: set[date] | Iterable[date] | None = None) -> date:
    """Nearest business day strictly before ``day`` (capped at 366 steps)."""
    day = _as_date(day)
    free = _normalize_free(free_days)
    cursor = day - timedelta(days=1)
    for _ in range(366):
        if is_business_day(cursor, free):
            return cursor
        cursor -= timedelta(days=1)
    # A year-long free-day span should not silently yield a non-business
    # day as "the" deadline day — return the oldest checked day so the
    # deadline stays fail-closed instead of pointing at a weekend.
    return cursor


def lunch_order_deadline(
    lunch_day: date,
    cutoff_time: object = "12:00",
    free_days: set[date] | Iterable[date] | None = None,
) -> datetime:
    """Deadline datetime for a lunch day: previous business day at cutoff time."""
    hour, minute = parse_cutoff_time(cutoff_time)
    prev = previous_business_day(lunch_day, free_days)
    return datetime(prev.year, prev.month, prev.day, hour, minute,
                    tzinfo=_prague_tz(prev))


def is_lunch_order_open(
    lunch_day: date | datetime,
    now: date | datetime | None = None,
    cutoff_time: object = "12:00",
    free_days: set[date] | Iterable[date] | None = None,
) -> bool:
    """True while ``now`` is at or before the ordering deadline."""
    if isinstance(lunch_day, datetime):
        lunch_day = lunch_day.date()
    if now is None:
        now_dt = datetime.now(_prague_tz(date.today()))
    elif isinstance(now, datetime):
        now_dt = _as_prague_moment(now)
    else:
        now_dt = datetime(now.year, now.month, now.day,
                          tzinfo=_prague_tz(date(now.year, now.month, now.day)))
    try:
        return now_dt <= lunch_order_deadline(lunch_day, cutoff_time, free_days)
    except Exception:
        # Fail-closed: an uncomputable deadline must never read as
        # "still open" (that ordered after the deadline). Callers treat
        # False as "closed / not orderable".
        return False
