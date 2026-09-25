"""Year-aware vacation planner (pure functions — no I/O, no UI).

Answers "which days can I stay home this school year without risking my
absence limits — and when should I take them?".

The model, per semester (term) and subject:

* ``total = taught + future`` — hours actually taught by the absence
  closure. ``taught`` comes from the absence overview (or an estimate),
  ``future`` is counted day by day from the concrete fetched weeks and the
  stable template, so holidays falling on one weekday only shrink the
  subjects taught that day.
* ``free = limit% * total - missed - planned - buffer`` — hours the planner
  may still hand out. ``planned`` are lessons on already planned future
  days off, ``buffer = reserve% * future`` is kept aside for illness and
  other unplanned absences. The buffer only covers lessons that are still
  ahead (the past is known), so it shrinks as the term goes on and budget
  is released gradually instead of being locked away until the closure.
* Days are scored by how much scarce budget they burn (hours weighted by
  ``1 / free`` of each subject), how many lessons they hold, whether they
  make a long weekend or bridge a holiday, and whether they fall into the
  risky final weeks before the closure.
* The recommended plan spreads the affordable days evenly across the rest
  of the term (one per window) instead of front-loading the next few days
  or leaving everything for the last week.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Iterable, Sequence

from .forecast import canon_subject, normalize_holidays, school_days_between
from .models import Lesson, SubjectState, parse_cz_date
from .planned_skips import entry_days, normalize_planned_entry

#: School days before the closure that the plan avoids (grading crunch,
#: no time left to recover from an unexpected illness).
FINAL_WEEK_DAYS = 5
#: The week before that is still allowed, just discouraged.
LATE_WEEK_DAYS = 10
#: Days with at most this many lessons count as "light".
LIGHT_DAY_LESSONS = 4

_EPS = 1e-9


# -- lesson source -----------------------------------------------------------

class LessonSource:
    """Which lessons a given date holds.

    Priority: (1) the concrete fetched week for that exact date —
    substitutions and cancellations win; (2) the stable template for the
    weekday; (3) the union of loaded weeks for that weekday when no
    baseline is known. ``None`` means "unknown" (nothing to go on).
    """

    def __init__(self, timetable: dict | None, stable_baseline: dict | None = None) -> None:
        self.concrete: dict[date, list[Lesson]] = {}
        for day_key, rows in (timetable or {}).items():
            day = parse_cz_date(day_key)
            if day is None:
                continue
            bucket = self.concrete.setdefault(day, [])
            for raw in rows or []:
                if not isinstance(raw, dict):
                    continue
                lesson = Lesson.from_legacy(raw, day=day_key)
                # Cancelled lessons cost no absence budget.
                if lesson.status != "cancelled" and lesson.subject.strip() not in ("", "?"):
                    bucket.append(lesson)
        self.template: dict[int, list[Lesson]] = {}
        for slot_key, slot_value in (stable_baseline or {}).items():
            try:
                weekday, period = slot_key
                weekday_i, period_i = int(weekday), int(period)
            except (TypeError, ValueError):
                continue
            variants = slot_value if isinstance(slot_value, list) else [slot_value]
            seen: set[str] = set()
            for variant in variants:
                if hasattr(variant, "subject"):
                    subject = str(variant.subject or "")
                elif isinstance(variant, dict):
                    subject = str(variant.get("subject", "") or "")
                else:
                    continue
                canon = canon_subject(subject)
                # Split-group slots: every distinct subject costs budget
                # once (mirrors schedule.stable_weekly_hours).
                if not canon or canon in seen:
                    continue
                seen.add(canon)
                self.template.setdefault(weekday_i, []).append(
                    Lesson(subject=subject, period=period_i))
        self.has_template = bool(self.template)
        self.union: dict[int, list[Lesson]] = {}
        if not self.has_template:
            # Legacy fallback: one representative week per weekday (the
            # latest loaded one) — merging all weeks would inflate counts.
            latest: dict[int, date] = {}
            for day in self.concrete:
                if day.weekday() < 5 and (day.weekday() not in latest or day > latest[day.weekday()]):
                    latest[day.weekday()] = day
            for weekday, day in latest.items():
                self.union[weekday] = list(self.concrete[day])

    def lessons(self, day: date) -> list[Lesson] | None:
        if day in self.concrete:
            return list(self.concrete[day])
        if self.has_template:
            return list(self.template.get(day.weekday(), []))
        if day.weekday() in self.union:
            return list(self.union[day.weekday()])
        return None

    @property
    def known(self) -> bool:
        return bool(self.concrete or self.template)


def _in_period_range(lesson: Lesson, start_period: int | None, end_period: int | None) -> bool:
    if lesson.period is None:
        return True
    if start_period is not None and lesson.period < start_period:
        return False
    if end_period is not None and lesson.period > end_period:
        return False
    return True


def entry_lessons(entry: dict, source: LessonSource, holidays: set[date],
                  from_day: date | None = None) -> dict[date, list[Lesson]]:
    """Lessons a planned entry skips, per school day (partial days honored).

    ``start_period`` limits the first day, ``end_period`` the last one;
    middle days are whole. Days before ``from_day`` are dropped (their
    absences are already in the school data).
    """
    norm = normalize_planned_entry(entry)
    if norm is None:
        return {}
    days = entry_days(norm)
    if not days:
        return {}
    start_p = norm.get("start_period")
    end_p = norm.get("end_period")
    out: dict[date, list[Lesson]] = {}
    for day in days:
        if day.weekday() >= 5 or day in holidays:
            continue
        if from_day is not None and day < from_day:
            continue
        lessons = source.lessons(day) or []
        first = start_p if day == days[0] else None
        last = end_p if day == days[-1] else None
        picked = [l for l in lessons if _in_period_range(l, first, last)]
        if picked:
            out[day] = picked
    return out


# -- models ------------------------------------------------------------------

@dataclass
class Budget:
    """One subject's absence budget for one term (hours)."""

    name: str
    canon: str
    limit_pct: float
    reserve_pct: float
    current_pct: float = 0.0
    taught: float = 0.0
    missed: float = 0.0
    future: float = 0.0
    planned: float = 0.0
    blocked: bool = False  # school flagged the subject unclassifiable
    weekly: float = 0.0  # normal lessons per week (for "tight" checks)
    peak: int = 1  # most lessons of this subject on one day (double periods)

    @property
    def days_left(self) -> float:
        """Roughly how many days holding this subject still fit the budget."""
        return self.free / max(1, self.peak)

    @property
    def total(self) -> float:
        return max(1.0, self.taught + self.future)

    @property
    def school_cap(self) -> float:
        """Hours missable over the whole term before hitting the limit."""
        return self.limit_pct / 100.0 * self.total

    @property
    def buffer(self) -> float:
        """Illness reserve: ``reserve%`` of the lessons still ahead."""
        return self.reserve_pct / 100.0 * self.future

    @property
    def free(self) -> float:
        """Hours the planner may still hand out (can go negative)."""
        if self.blocked:
            return min(0.0, self.school_cap - self.missed - self.planned - self.buffer)
        return self.school_cap - self.missed - self.planned - self.buffer

    @property
    def free_hours(self) -> int:
        return max(0, int(math.floor(self.free + _EPS)))

    @property
    def school_left(self) -> float:
        """Hours left before the school limit (buffer included)."""
        return self.school_cap - self.missed - self.planned

    @property
    def projected_pct(self) -> float:
        """Final % if every planned day happens and nothing else."""
        return (self.missed + self.planned) / self.total * 100.0

    @property
    def status(self) -> str:
        """ok / tight / reserve (eats into the buffer) / over (school limit)."""
        if self.school_left < -_EPS:
            return "over"
        if self.blocked or self.free < -_EPS:
            return "reserve"
        if self.free < max(1.0, float(self.peak)):
            return "tight"
        return "ok"

    def pace_ratio(self, elapsed: float) -> float | None:
        """Spent share of the term budget vs. share of the term elapsed.

        > 1 means absences so far run faster than an even spread would
        allow. ``None`` early in the term (too little data to judge).
        """
        if elapsed < 0.1 or self.taught <= 0:
            return None
        plan_cap = max(0.0, (self.limit_pct - self.reserve_pct)) / 100.0 * self.total
        if plan_cap <= _EPS:
            return None
        return (self.missed / plan_cap) / elapsed


@dataclass
class DayOption:
    """One candidate day off."""

    day: date
    term: str
    lessons: list[str] = field(default_factory=list)
    cost: dict[str, int] = field(default_factory=dict)  # canon -> hours
    names: dict[str, str] = field(default_factory=dict)  # canon -> display
    streak: int = 1  # free block length (days) if taken
    final_week: bool = False
    late_week: bool = False
    feasible: bool = True
    blocked_by: list[str] = field(default_factory=list)
    score: float = 0.0

    @property
    def lessons_count(self) -> int:
        return len(self.lessons)

    @property
    def budget_hours(self) -> int:
        return sum(self.cost.values())

    @property
    def tags(self) -> list[str]:
        tags: list[str] = []
        if self.streak >= 4:
            tags.append("bridge")
        elif self.streak >= 3:
            tags.append("long_weekend")
        if not self.cost:
            tags.append("free")
        elif self.lessons_count <= LIGHT_DAY_LESSONS:
            tags.append("light")
        if self.final_week:
            tags.append("final_week")
        elif self.late_week:
            tags.append("late_week")
        return tags


@dataclass
class PlannedDay:
    """A planned entry's share inside one term."""

    entry: dict
    days: dict[date, list[str]] = field(default_factory=dict)
    cost: dict[str, int] = field(default_factory=dict)
    over: list[str] = field(default_factory=list)  # canon subjects past the school limit
    reserve: list[str] = field(default_factory=list)  # canon subjects eating the buffer

    @property
    def hours(self) -> int:
        return sum(len(v) for v in self.days.values())


@dataclass
class ImpactRow:
    name: str
    cost: int
    free_after: float
    projected_after: float
    limit_pct: float
    level: str  # ok | reserve | over


@dataclass
class TermPlan:
    key: str  # "sem1" | "sem2"
    start: date
    close: date
    has_data: bool
    active: bool
    school_days: list[date] = field(default_factory=list)
    remaining_days: list[date] = field(default_factory=list)
    budgets: list[Budget] = field(default_factory=list)
    options: dict[date, DayOption] = field(default_factory=dict)
    planned: list[PlannedDay] = field(default_factory=list)
    planned_dates: set[date] = field(default_factory=set)
    recommended: list[DayOption] = field(default_factory=list)
    capacity: int = 0  # extra whole days affordable on top of the plans
    target: int = 0  # whole days off the plan aims for (incl. planned)

    @property
    def elapsed(self) -> float:
        if not self.school_days:
            return 0.0
        return 1.0 - len(self.remaining_days) / len(self.school_days)

    @property
    def budget_by_canon(self) -> dict[str, Budget]:
        return {b.canon: b for b in self.budgets}

    @property
    def tightest(self) -> Budget | None:
        if not self.budgets:
            return None
        return min(self.budgets, key=lambda b: (b.days_left, b.name))

    @property
    def fast_pace(self) -> list[Budget]:
        out = []
        for b in self.budgets:
            ratio = b.pace_ratio(self.elapsed)
            if ratio is not None and ratio > 1.25 and b.missed >= 2:
                out.append(b)
        return out

    def impact(self, by_day: dict[date, list[str]]) -> list[ImpactRow]:
        """What skipping these lessons does to each touched budget."""
        counts: Counter = Counter()
        for day, names in by_day.items():
            if day < self.start or day > self.close:
                continue
            counts.update(canon_subject(n) for n in names)
        rows: list[ImpactRow] = []
        budgets = self.budget_by_canon
        for canon, cost in counts.items():
            budget = budgets.get(canon)
            if budget is None:
                continue
            free_after = budget.free - cost
            school_after = budget.school_left - cost
            projected = (budget.missed + budget.planned + cost) / budget.total * 100.0
            level = "over" if school_after < -_EPS else ("reserve" if free_after < -_EPS else "ok")
            rows.append(ImpactRow(name=budget.name, cost=int(cost), free_after=free_after,
                                  projected_after=projected, limit_pct=budget.limit_pct,
                                  level=level))
        rows.sort(key=lambda r: ({"over": 0, "reserve": 1, "ok": 2}[r.level], r.free_after, r.name))
        return rows


@dataclass
class YearPlan:
    terms: list[TermPlan] = field(default_factory=list)
    today: date = field(default_factory=date.today)
    first_day: date = field(default_factory=date.today)
    source: LessonSource | None = None
    holidays: set[date] = field(default_factory=set)
    free_labels: dict[date, str] = field(default_factory=dict)

    def term(self, key: str | None) -> TermPlan | None:
        for term in self.terms:
            if term.key == key:
                return term
        return None

    @property
    def default_term(self) -> TermPlan | None:
        for term in self.terms:
            if term.active:
                return term
        return self.terms[0] if self.terms else None

    def lessons_on(self, day: date) -> list[str]:
        if self.source is None or day.weekday() >= 5 or day in self.holidays:
            return []
        return [l.subject for l in (self.source.lessons(day) or [])]

    def entry_breakdown(self, entry: dict) -> dict[date, list[str]]:
        if self.source is None:
            return {}
        raw = entry_lessons(entry, self.source, self.holidays, from_day=self.today)
        return {d: [l.subject for l in ls] for d, ls in raw.items()}

    def impact_of_entry(self, entry: dict) -> list[tuple[TermPlan, list[ImpactRow]]]:
        by_day = self.entry_breakdown(entry)
        out = []
        for term in self.terms:
            part = {d: v for d, v in by_day.items() if term.start <= d <= term.close}
            if part:
                out.append((term, term.impact(part)))
        return out


# -- terms -------------------------------------------------------------------

def school_year_terms(today: date, sem1_close=None, sem2_close=None,
                      school_year_end=None) -> list[tuple[str, date, date]]:
    """(key, first_day, closure) for both semesters of today's school year."""
    year = today.year if today.month >= 8 else today.year - 1
    sem1_start, sem1_end = date(year, 9, 1), date(year + 1, 1, 31)
    sem2_start, sem2_end = date(year + 1, 2, 1), date(year + 1, 6, 30)
    close1 = parse_cz_date(sem1_close) if sem1_close else None
    close2 = parse_cz_date(sem2_close or school_year_end) if (sem2_close or school_year_end) else None
    if close1 is not None and sem1_start <= close1 <= sem1_end + timedelta(days=14):
        sem1_end = close1
    if close2 is not None and sem2_start <= close2 <= sem2_end + timedelta(days=14):
        sem2_end = close2
    return [("sem1", sem1_start, sem1_end), ("sem2", sem2_start, sem2_end)]


def _free_streak(day: date, is_off) -> int:
    """Length of the contiguous off-block containing ``day`` once taken."""
    length = 1
    cursor = day - timedelta(days=1)
    while is_off(cursor) and length < 40:
        length += 1
        cursor -= timedelta(days=1)
    cursor = day + timedelta(days=1)
    while is_off(cursor) and length < 40:
        length += 1
        cursor += timedelta(days=1)
    return length


def _score(option: DayOption, free: dict[str, float], repeats: int = 0,
           streak: int | None = None) -> float:
    """Lower is better.

    ``repeats`` = days of the same weekday already in the plan: skipping
    every Thursday would always miss the same subjects, so each repeat
    costs a little (the plan varies weekdays when prices are close).
    ``streak`` overrides the option's free-block length (a pick next to
    another pick makes a longer vacation).
    """
    pain = sum(hours / max(free.get(canon, 0.0), 0.5) for canon, hours in option.cost.items())
    score = 10.0 * pain + 0.35 * option.lessons_count + 2.0 * repeats
    streak = option.streak if streak is None else streak
    if streak >= 4:
        score -= min(6.0, 4.0 + 0.5 * (streak - 4))
    elif streak >= 3:
        score -= 2.0
    if option.final_week:
        score += 6.0
    elif option.late_week:
        score += 2.0
    return score


def _fits(option: DayOption, free: dict[str, float]) -> bool:
    return all(hours <= free.get(canon, 0.0) + _EPS for canon, hours in option.cost.items())


def _spend(option: DayOption, free: dict[str, float]) -> None:
    for canon, hours in option.cost.items():
        free[canon] = free.get(canon, 0.0) - hours


def _capacity(options: list[DayOption], free: dict[str, float]) -> int:
    """How many more whole days fit (greedy, cheapest first)."""
    left = dict(free)
    count = 0
    for option in sorted(options, key=lambda o: (_score(o, free), o.day)):
        if _fits(option, left):
            _spend(option, left)
            count += 1
    return count


def spread_plan(options: list[DayOption], free: dict[str, float], quota: int,
                span: list[date], taken: Iterable[date] = (),
                is_off=None) -> list[DayOption]:
    """Picks up to ``quota`` days spread evenly across ``span``.

    ``span`` (remaining school days) is cut into equal windows, one per
    day off wanted in total (``taken`` = days already planned). Windows
    already holding a planned day are skipped; every other window gets
    its best affordable day, re-scored against the budgets left after
    the earlier picks. Days crowding an earlier pick pay a proximity
    penalty (unless they join it into one longer vacation — ``is_off``
    tells weekends/holidays apart). Leftover quota (windows with nothing
    affordable) is filled with the affordable days farthest from every
    pick.
    """
    if quota <= 0 or not options or not span:
        return []
    taken = sorted(set(taken))
    left = dict(free)
    index = {day: i for i, day in enumerate(span)}
    windows_n = quota + len([d for d in taken if d in index])
    length = len(span)
    ideal = max(1.0, length / max(1, windows_n))
    picks: list[DayOption] = []
    by_day = {o.day: o for o in options}
    weekdays: Counter = Counter(d.weekday() for d in taken)
    chosen: set[date] = set(taken)

    def _rank(o: DayOption) -> float:
        streak = None
        joined = False
        if is_off is not None and chosen:
            streak = _free_streak(o.day, lambda d: is_off(d) or d in chosen)
            joined = streak > o.streak
        penalty = 0.0
        if not joined and o.day in index:
            near = [abs(index[o.day] - index[d]) for d in chosen if d in index]
            if near:
                penalty = 4.0 * max(0.0, 1.0 - min(near) / ideal)
        return _score(o, left, weekdays[o.day.weekday()], streak) + penalty

    def _take(best: DayOption) -> None:
        picks.append(best)
        chosen.add(best.day)
        weekdays[best.day.weekday()] += 1
        _spend(best, left)

    for w in range(windows_n):
        if len(picks) >= quota:
            break
        lo = (w * length) // windows_n
        hi = max(lo + 1, ((w + 1) * length) // windows_n)
        window_days = span[lo:hi]
        if any(d in taken for d in window_days):
            continue
        pool = [by_day[d] for d in window_days if d in by_day and _fits(by_day[d], left)]
        if not pool:
            continue
        _take(min(pool, key=lambda o: (_rank(o), o.day)))
    while len(picks) < quota:
        pool = [o for o in options if o.day not in chosen and _fits(o, left)]
        if not pool:
            break

        def _gap(o: DayOption) -> int:
            if not chosen:
                return 10_000
            return min(abs((o.day - d).days) for d in chosen)

        _take(min(pool, key=lambda o: (-min(_gap(o), 21), _rank(o), o.day)))
    picks.sort(key=lambda o: o.day)
    return picks


# -- entry point -------------------------------------------------------------

def build_year_plan(
    states: Sequence[SubjectState],
    timetable: dict | None,
    stable_baseline: dict | None = None,
    holidays: Iterable[str | date] | None = None,
    planned: Sequence[dict] | None = None,
    today: date | None = None,
    first_day: date | None = None,
    sem1_close=None,
    sem2_close=None,
    school_year_end=None,
    reserve_pct: float = 10.0,
    target_days: int = 0,
    free_labels: dict | None = None,
) -> YearPlan:
    """Budgets, candidate days and a balanced plan for the school year.

    ``states`` (from :func:`forecast.forecast_all`) define which subjects
    count and their limits/current %. ``first_day`` is the first date that
    can still be planned (today, or tomorrow once today's lessons began).
    ``target_days`` caps the whole days off per term (0 = as many as the
    budgets allow). The term holding today uses the school's absence data;
    the next term starts from a clean slate.
    """
    today = today or date.today()
    first_day = max(today, first_day or today)
    holiday_set = normalize_holidays(holidays)
    try:
        reserve = max(0.0, float(reserve_pct or 0.0))
    except (TypeError, ValueError):
        reserve = 0.0
    source = LessonSource(timetable, stable_baseline)
    plan = YearPlan(today=today, first_day=first_day, source=source, holidays=holiday_set,
                    free_labels={d: str(v) for d, v in (free_labels or {}).items()
                                 if isinstance(d, date)})
    if not states:
        return plan

    entries = [e for e in (normalize_planned_entry(x) for x in (planned or [])) if e]
    planned_lessons: list[tuple[dict, dict[date, list[Lesson]]]] = [
        (entry, entry_lessons(entry, source, holiday_set, from_day=today)) for entry in entries
    ]
    planned_dates_all: set[date] = set()
    for entry in entries:
        for day in entry_days(entry):
            planned_dates_all.add(day)

    def _is_off(day: date) -> bool:
        return day.weekday() >= 5 or day in holiday_set or day in planned_dates_all

    for key, start, close in school_year_terms(today, sem1_close, sem2_close, school_year_end):
        if close < today:
            continue  # closed term: nothing left to plan
        is_current = start <= today <= close
        school_days = school_days_between(start, close, holiday_set)
        remaining = [d for d in school_days if d >= today]
        term = TermPlan(key=key, start=start, close=close, has_data=is_current,
                        active=is_current, school_days=school_days, remaining_days=remaining)

        # Future hours per subject, counted day by day.
        future: Counter = Counter()
        unknown_days = 0
        for day in remaining:
            lessons = source.lessons(day)
            if lessons is None:
                unknown_days += 1
                continue
            future.update(canon_subject(l.subject) for l in lessons)

        names: dict[str, str] = {}
        for state in states:
            canon = canon_subject(state.name)
            if not canon or canon in names:
                continue
            names[canon] = state.name
            weekly = float(max(1, int(state.weekly_hours or 0)))
            fut = float(future.get(canon, 0)) + weekly * unknown_days / 5.0
            if is_current:
                taught = float(state.taught_hours or 0.0)
                if taught <= 0:
                    elapsed_days = len(school_days) - len(remaining)
                    taught = weekly * elapsed_days / 5.0
                current = max(0.0, float(state.current_pct or 0.0))
                missed = current / 100.0 * taught
                blocked = bool(getattr(state, "unclassifiable", False))
            else:
                taught, current, missed, blocked = 0.0, 0.0, 0.0, False
            budget = Budget(name=state.name, canon=canon, limit_pct=float(state.limit_pct),
                            reserve_pct=reserve, current_pct=current, taught=taught,
                            missed=missed, future=fut, blocked=blocked, weekly=weekly)
            term.budgets.append(budget)
        budgets = term.budget_by_canon

        # Already planned days inside this term.
        for entry, by_day in planned_lessons:
            in_term = {d: ls for d, ls in by_day.items() if start <= d <= close}
            touches = [d for d in entry_days(entry) if start <= d <= close]
            if not touches:
                continue
            row = PlannedDay(entry=entry,
                             days={d: [l.subject for l in ls] for d, ls in in_term.items()})
            counts: Counter = Counter()
            for ls in in_term.values():
                counts.update(canon_subject(l.subject) for l in ls if canon_subject(l.subject) in budgets)
            row.cost = dict(counts)
            for canon, hours in counts.items():
                budgets[canon].planned += hours
            term.planned.append(row)
            term.planned_dates.update(d for d in touches if d.weekday() < 5 and d not in holiday_set)
        for row in term.planned:
            for canon in row.cost:
                status = budgets[canon].status
                if status == "over":
                    row.over.append(canon)
                elif status == "reserve":
                    row.reserve.append(canon)

        # Candidate days.
        free = {b.canon: b.free for b in term.budgets}
        # The closing weeks, flagged only when they really are the term's
        # last weeks (a short horizon mid-term is not the grading crunch).
        final_set = set(school_days[-FINAL_WEEK_DAYS:]) if len(school_days) > FINAL_WEEK_DAYS else set()
        late_set = (set(school_days[-LATE_WEEK_DAYS:-FINAL_WEEK_DAYS])
                    if len(school_days) > LATE_WEEK_DAYS else set())
        for day in remaining:
            if day < first_day or day in planned_dates_all:
                continue
            lessons = source.lessons(day)
            if not lessons:
                continue  # unknown or no lessons: nothing to plan
            subjects = [l.subject for l in lessons]
            counts = Counter(canon_subject(n) for n in subjects)
            cost = {c: n for c, n in counts.items() if c in budgets}
            option = DayOption(
                day=day, term=key, lessons=subjects, cost=cost,
                names={c: budgets[c].name for c in cost},
                streak=_free_streak(day, _is_off),
                final_week=day in final_set,
                late_week=day in late_set,
            )
            option.blocked_by = [c for c, n in cost.items() if n > free.get(c, 0.0) + _EPS]
            option.feasible = not option.blocked_by
            option.score = _score(option, free)
            term.options[day] = option

        for option in term.options.values():
            for canon, hours in option.cost.items():
                if hours > budgets[canon].peak:
                    budgets[canon].peak = hours

        # Balanced plan: capacity from the non-final days (the final week
        # only when nothing else is left), then spread evenly.
        feasible = [o for o in term.options.values() if o.feasible]
        use_final = not any(not o.final_week for o in feasible)
        pool = feasible if use_final else [o for o in feasible if not o.final_week]
        term.capacity = _capacity(pool, free)
        already = len(term.planned_dates & set(remaining))
        wanted = term.capacity
        if target_days and target_days > 0:
            wanted = min(term.capacity, max(0, int(target_days) - already))
        term.target = already + wanted
        span = [d for d in remaining
                if d >= first_day and (use_final or d not in final_set)]
        term.recommended = spread_plan(pool, free, wanted, span, taken=term.planned_dates,
                                       is_off=_is_off)
        term.budgets.sort(key=lambda b: (b.days_left, b.name))
        plan.terms.append(term)
    return plan
