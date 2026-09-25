"""Absence forecasting engine (pure functions — no I/O, no UI).

Answers: how many hours of each subject can the student still miss, what
will the final percentage be. Day-off planning lives in ``planner``.

Inputs are plain data (absence ``{subject: pct}``, legacy timetable dict,
holiday list, semester bounds) so every function is unit-testable.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Iterable

from .models import SubjectState


def _half_up(value: float) -> int:
    """Round-half-up for non-negative hour budgets (avoids banker's rounding)."""
    import math as _math

    return int(_math.floor(max(0.0, float(value)) + 0.5))


STANDARD_SEMESTER_WEEKS = 16


def normalize_holidays(holidays: Iterable[str | date] | None) -> set[date]:
    """Normalizes ``['25.12.2026', date(...), ...]`` into a set of dates."""
    from .models import parse_cz_date

    out: set[date] = set()
    for item in holidays or []:
        parsed = parse_cz_date(item)
        if parsed is not None:
            out.add(parsed)
    return out


def weekly_hours_per_subject(timetable: dict) -> dict[str, int]:
    """Counts lessons per subject across the loaded (stable) week(s).

    Counts only — the 4 h/2 h core-subject fallback for subjects missing
    from the timetable lives in :func:`_fallback_weekly_hours` (used by
    the forecast entry point), not here.
    """
    counts: dict[str, int] = {}
    totals = 0
    for lessons in (timetable or {}).values():
        for raw in lessons or []:
            name = str((raw or {}).get("subject", "")).strip()
            if name:
                counts[name] = counts.get(name, 0) + 1
                totals += 1
    # A multi-week timetable would inflate counts — normalize to one week.
    # No max(1, ...) floor: a subject seen once across many weeks is a
    # one-off, not a weekly hour — flooring it to 1 would inflate rare
    # subjects into full weekly budgets. Zero-count leftovers are dropped;
    # consumers fall back to the core-subject heuristic instead.
    day_count = max(1, len(timetable or {}))
    if day_count > 5:
        factor = 5.0 / day_count
        counts = {name: round(n * factor) for name, n in counts.items()}
        counts = {name: n for name, n in counts.items() if n > 0}
    return counts


def _fallback_weekly_hours(subject: str) -> int:
    lowered = subject.lower()
    if any(key in lowered for key in ("matem", "česk", "cesk", "angli", "němč", "nemč")):
        return 4
    return 2


def school_days_between(
    start: date, end: date, holidays: set[date] | None = None
) -> list[date]:
    """Weekdays in [start, end] minus holidays."""
    holidays = holidays or set()
    days: list[date] = []
    cursor = start
    while cursor <= end:
        if cursor.weekday() < 5 and cursor not in holidays:
            days.append(cursor)
        cursor += timedelta(days=1)
    return days


def semester_bounds(today: date) -> tuple[date, date]:
    """(first_day, last_day) of the running Czech semester for ``today``."""
    if today.month >= 9:
        return date(today.year, 9, 1), date(today.year + 1, 1, 31)
    if today.month == 1:
        return date(today.year - 1, 9, 1), date(today.year, 1, 31)
    if today.month >= 2:
        return date(today.year, 2, 1), date(today.year, 6, 30)
    return date(today.year - 1, 9, 1), date(today.year, 1, 31)


def canon_subject(name) -> str:
    """Canonical subject key: whitespace (incl. nbsp) collapsed, casefolded.

    The absence overview writes non-breaking spaces
    (Seminar z<nbsp>matematiky S) while the timetable and the directory
    use plain ones — comparisons must normalize or the same subject
    silently counts as two.
    """
    import re as _re

    return _re.sub(r"[\s\xa0]+", " ", str(name or "")).strip().casefold()


def forecast_subject(
    current_pct: float,
    weekly_hours: int,
    school_days_left: int,
    school_days_total: int,
    limit_pct: float,
    warn_pct: float | None = None,
    reserve_pct: float = 0.0,
    taught_hours: float | None = None,
) -> SubjectState:
    """Projects one subject to semester end.

    ``current_pct`` applies to the taught part so far; future lessons are
    assumed attended unless the caller subtracts planned skips first.
    ``taught_hours`` overrides the estimated already-taught hours with the
    real elapsed count from the absence overview (elapsed, never planned
    totals); None keeps the weekly-hours estimate.
    ``warn_pct`` overrides the derived 60%-of-limit warning threshold.
    ``reserve_pct`` (percentage points) is the safety reserve for vacation
    planning: the planner stops recommending the subject once it reaches
    ``limit_pct - reserve_pct`` instead of the bare school limit. The
    school truth (``limit_pct`` / ``safe_hours_left``) is unaffected —
    the reserve-aware budget lives in ``plan_limit_pct`` /
    ``plan_safe_hours_left``.
    """
    weekly_hours = max(1, int(weekly_hours))
    total_hours = max(1, round(weekly_hours * school_days_total / 5))
    if taught_hours is not None:
        try:
            taught_so_far = max(0.0, float(taught_hours))
        except (TypeError, ValueError):
            taught_so_far = max(1, round(weekly_hours * (school_days_total - school_days_left) / 5))
    else:
        taught_so_far = max(1, round(weekly_hours * (school_days_total - school_days_left) / 5))
    already_missed = (max(0.0, current_pct) / 100.0) * taught_so_far
    max_missable = (max(0.0, limit_pct) / 100.0) * total_hours
    # Half-up rounding (not banker's): x.5 budgets must not round to even.
    safe_left = max(0, _half_up(max_missable - already_missed))
    projected = (already_missed / total_hours) * 100.0
    reserve = max(0.0, float(reserve_pct or 0.0))
    plan_limit = max(0.0, round(max(0.0, limit_pct) - reserve, 1))
    plan_max_missable = (plan_limit / 100.0) * total_hours
    plan_safe = max(0, _half_up(plan_max_missable - already_missed))
    return SubjectState(
        name="",
        current_pct=round(current_pct, 1),
        limit_pct=limit_pct,
        weekly_hours=weekly_hours,
        safe_hours_left=safe_left,
        projected_pct=round(projected, 1),
        warn_pct=float(warn_pct) if warn_pct else 0.0,
        plan_limit_pct=plan_limit,
        plan_safe_hours_left=plan_safe,
    )


def forecast_all(
    absence: dict[str, float],
    timetable: dict,
    subject_limits: dict[str, float] | None = None,
    holidays: Iterable[str | date] | None = None,
    today: date | None = None,
    default_limit: float = 25.0,
    school_year_end: date | str | None = None,
    sem1_close: date | str | None = None,
    sem2_close: date | str | None = None,
    warn_pct: float | None = None,
    stable_baseline: dict | None = None,
    reserve_pct: float = 0.0,
    tracked_subjects: set | frozenset | list | tuple | None = None,
    absence_details: dict | None = None,
) -> tuple[list[SubjectState], list[date]]:
    """Full-semester forecast for every subject with absence data.

    Returns (subject_states, school_days_left_list). ``warn_pct`` is the
    explicit warning threshold (falls back to 60% of each limit).
    ``reserve_pct`` is the global planning reserve (see forecast_subject).
    ``tracked_subjects`` is the school-official subject set (the subject
    directory): absence entries outside it are dropped — only tracked
    subjects count toward limits, so anything else is always free to
    skip and needs no budget. ``absence_details`` carries the full
    overview rows (elapsed hours + school verdict badges) keyed by
    subject; elapsed hours replace the taught-hours estimate and the
    badges escalate the subject status.

    ``reserve_pct`` (percentage points, global planning reserve) lowers
    each subject's *planning* limit to ``limit - reserve`` — the planner
    stops recommending a subject earlier while the school truth
    (``limit_pct`` / ``safe_hours_left``) stays untouched.
    When ``stable_baseline`` (the scraped "Stálý" view) is
    given, weekly hours come from the stable timetable — cancellations,
    substitutions and one-off events in the raw weeks don't inflate or
    shrink a subject's hours. Absence entries for subjects the baseline
    never saw (renamed subjects, one-off events) are dropped: only stable
    subjects count toward absence limits, so anything else is always free
    to skip and needs no budget. Without a baseline the legacy raw-count
    + name-heuristic fallback applies (fresh installs, tests).
    """
    from .models import parse_cz_date

    today = today or date.today()
    holiday_set = normalize_holidays(holidays)
    first_day, semester_end = semester_bounds(today)
    # Absence/marks closure (e.g. final year ends sooner) replaces the
    # automatic semester bound. Legacy single ``school_year_end`` acts as
    # a fallback for the running semester.
    if first_day.month == 9:
        close_raw = sem1_close or school_year_end
    else:
        close_raw = sem2_close or school_year_end
    if close_raw:
        parsed_end = parse_cz_date(close_raw)
        if parsed_end is not None and parsed_end >= first_day:
            semester_end = parsed_end
    days_total = school_days_between(first_day, semester_end, holiday_set)
    days_left = [d for d in days_total if d >= today]

    weekly = weekly_hours_per_subject(timetable)
    stable_subjects: set[str] | None = None
    if stable_baseline:
        try:
            from .schedule import stable_weekly_hours

            stable_hours = stable_weekly_hours(stable_baseline)
        except Exception:
            stable_hours = {}
        if stable_hours:
            weekly = stable_hours
            # Only stable subjects count toward limits — one-offs never do.
            stable_subjects = {canon_subject(name) for name in stable_hours}
    limits = {canon_subject(k): float(v) for k, v in (subject_limits or {}).items()}
    try:
        tracked = None
        if tracked_subjects:
            tracked = {canon_subject(name) for name in tracked_subjects}
    except Exception:
        tracked = None
    try:
        details_by_subject = {}
        for detail_name, detail in (absence_details or {}).items():
            if isinstance(detail, dict):
                details_by_subject[canon_subject(detail_name)] = detail
    except Exception:
        details_by_subject = {}
    try:
        reserve = max(0.0, float(reserve_pct or 0.0))
    except (TypeError, ValueError):
        reserve = 0.0

    states: list[SubjectState] = []
    for subject, pct in (absence or {}).items():
        try:
            current = float(pct)
        except (TypeError, ValueError):
            continue
        canon = canon_subject(subject)
        if stable_subjects is not None and canon not in stable_subjects:
            # One-off / renamed subject: free to skip, no budget needed.
            continue
        if tracked is not None and canon not in tracked:
            # Not a school-tracked subject (e.g. homeroom hour): no
            # absence downside, always free to skip.
            continue
        hours = weekly.get(subject) or weekly.get(subject.strip())
        if not hours:
            # Case-insensitive fallback before giving up to the heuristic.
            match = next((h for name, h in weekly.items() if canon_subject(name) == canon), 0)
            hours = match or _fallback_weekly_hours(subject)
        limit = limits.get(canon, default_limit)
        detail = details_by_subject.get(canon, {})
        try:
            taught = detail.get("total_hours")
            taught = float(taught) if taught is not None else None
        except (TypeError, ValueError):
            taught = None
        state = forecast_subject(current, hours, len(days_left), len(days_total), limit, warn_pct=warn_pct,
                               reserve_pct=reserve, taught_hours=taught)
        state.name = subject
        try:
            state.approaching = bool(detail.get("approaching", False))
            state.unclassifiable = bool(detail.get("unclassifiable", False))
            state.taught_hours = float(taught) if taught is not None else 0.0
        except (TypeError, ValueError):
            pass
        states.append(state)
    states.sort(key=lambda s: -s.current_pct)
    return states, days_left

