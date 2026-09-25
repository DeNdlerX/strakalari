"""Year planner engine: budgets, pacing, bridges, terms, impact."""

from datetime import date, timedelta
from itertools import pairwise

from strakalari.core.models import SubjectState
from strakalari.core.planner import (
    FINAL_WEEK_DAYS,
    LessonSource,
    build_year_plan,
    entry_lessons,
    school_year_terms,
)

# Mon: M M F  | Tue: M F  | Wed: F  | Thu: M  | Fri: F F
TEMPLATE = {
    (0, 1): {"subject": "M"}, (0, 2): {"subject": "M"}, (0, 3): {"subject": "F"},
    (1, 1): {"subject": "M"}, (1, 2): {"subject": "F"},
    (2, 1): {"subject": "F"},
    (3, 1): {"subject": "M"},
    (4, 1): {"subject": "F"}, (4, 2): {"subject": "F"},
}
# One concrete day so the planner has a "timetable" at all.
TIMETABLE = {"07.09.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"}]}


def _states(m_pct=0.0, f_pct=0.0, m_taught=0.0, f_taught=0.0, limit=25.0):
    return [
        SubjectState(name="M", current_pct=m_pct, limit_pct=limit, weekly_hours=5,
                     taught_hours=m_taught),
        SubjectState(name="F", current_pct=f_pct, limit_pct=limit, weekly_hours=6,
                     taught_hours=f_taught),
    ]


def _plan(today=date(2026, 9, 21), planned=None, holidays=(), states=None, **kw):
    return build_year_plan(
        states or _states(), TIMETABLE, TEMPLATE, holidays, planned or [],
        today=today, sem1_close="25.01.2027", sem2_close="30.06.2027", **kw)


def test_terms_cover_both_semesters_until_closure():
    terms = school_year_terms(date(2026, 10, 1), "25.01.2027", "26.04.2027")
    assert terms == [("sem1", date(2026, 9, 1), date(2027, 1, 25)),
                     ("sem2", date(2027, 2, 1), date(2027, 4, 26))]


def test_next_semester_starts_fresh():
    plan = _plan(states=_states(m_pct=20.0, m_taught=15.0))
    sem1, sem2 = plan.term("sem1"), plan.term("sem2")
    assert sem1.active and sem1.has_data
    assert not sem2.active and not sem2.has_data
    assert sem1.budget_by_canon["m"].missed == 3.0
    assert sem2.budget_by_canon["m"].missed == 0.0
    assert sem2.capacity > 0 and sem2.recommended


def test_after_first_closure_the_planner_moves_to_semester_two():
    plan = _plan(today=date(2027, 1, 27))
    assert [t.key for t in plan.terms] == ["sem2"]
    assert plan.default_term.key == "sem2"
    assert plan.default_term.has_data is False



# -- which lessons a day holds (ported from the old skip suggester) -----------

def test_cancelled_lessons_cost_no_budget():
    source = LessonSource({"5.10.2099": [
        {"subject": "Matematika", "time": "1 (8:00 - 8:45)"},
        {"subject": "Fyzika", "time": "2 (8:55 - 9:40)", "status": "cancelled"},
    ]})
    assert [l.subject for l in source.lessons(date(2099, 10, 5))] == ["Matematika"]


def test_concrete_week_wins_over_the_template():
    from strakalari.core.schedule import baseline_from_stable_timetable

    baseline = baseline_from_stable_timetable({
        "Pondělí": [{"subject": "M", "teacher": "Novák", "room": "U12",
                     "time": "1 (8:00 - 8:45)"}],
        "Úterý": [{"subject": "F", "teacher": "Dvořák", "room": "F11",
                   "time": "1 (8:00 - 8:45)"}],
    })

    def _lesson(subject, period):
        return {"subject": subject, "teacher": "T", "room": "R",
                "time": f"{period} (8:00 - 8:45)"}

    timetable = {
        "31.08.2026": [_lesson("M", 1), _lesson("X", 2)],
        "07.09.2026": [_lesson("M", 1), _lesson("X", 2)],
        # Fetched week with a substitution: a 3rd lesson on Monday.
        "14.09.2026": [_lesson("M", 1), _lesson("X", 2),
                       {**_lesson("G", 3), "notice": "Suplování"}],
        # Known-but-empty concrete day: no school at all.
        "28.09.2026": [],
    }
    source = LessonSource(timetable, baseline)

    def subjects(day):
        return sorted(l.subject for l in source.lessons(day))

    # Concrete day: exactly its lessons, the change included.
    assert subjects(date(2026, 9, 14)) == ["G", "M", "X"]
    # Far-future day with no fetched week: the template.
    assert subjects(date(2026, 9, 21)) == ["M"]
    assert subjects(date(2026, 9, 28)) == []
    # Without a baseline the concrete day still wins.
    assert sorted(l.subject for l in LessonSource(timetable).lessons(date(2026, 9, 14)))         == ["G", "M", "X"]

def test_future_hours_are_counted_day_by_day():
    # A holiday on every Thursday removes only M hours, never F hours.
    base = _plan()
    thursdays = {date(2026, 9, 21) + timedelta(days=3 + 7 * i) for i in range(20)}
    holed = _plan(holidays=thursdays)
    m0, m1 = base.term("sem1").budget_by_canon["m"], holed.term("sem1").budget_by_canon["m"]
    f0, f1 = base.term("sem1").budget_by_canon["f"], holed.term("sem1").budget_by_canon["f"]
    assert m1.future < m0.future
    assert f1.future == f0.future


def test_planned_days_reduce_the_budget_and_capacity():
    free = _plan()
    planned = _plan(planned=[{"start_date": "2026-10-05", "end_date": "2026-10-05"}])
    b0, b1 = free.term("sem1").budget_by_canon["m"], planned.term("sem1").budget_by_canon["m"]
    assert b1.planned == 2  # Monday holds two M lessons
    assert b1.free == b0.free - 2
    assert planned.term("sem1").capacity < free.term("sem1").capacity
    assert date(2026, 10, 5) not in planned.term("sem1").options


def test_partial_planned_day_counts_only_its_periods():
    source = LessonSource(TIMETABLE, TEMPLATE)
    entry = {"start_date": "2026-10-05", "end_date": "2026-10-05",
             "start_period": 3, "end_period": 3}
    lessons = entry_lessons(entry, source, set())
    assert [l.subject for l in lessons[date(2026, 10, 5)]] == ["F"]


def test_illness_buffer_covers_only_lessons_still_ahead():
    early = _plan(today=date(2026, 9, 21)).term("sem1").budget_by_canon["m"]
    late = _plan(today=date(2027, 1, 4), states=_states(m_taught=60.0, f_taught=70.0)
                 ).term("sem1").budget_by_canon["m"]
    assert early.buffer == early.future * 0.10
    assert late.buffer < early.buffer
    # Nothing missed so far: late in the term more of the limit is free.
    assert late.free / late.total > early.free / early.total


def test_blocked_days_are_never_recommended():
    # Late in the term with M at 30 % of taught lessons: no day holding
    # M fits any more (the few remaining lessons only dilute a little).
    plan = _plan(today=date(2027, 1, 4), states=_states(m_pct=30.0, m_taught=60.0))
    term = plan.term("sem1")
    assert term.budget_by_canon["m"].free < 1
    assert all("m" not in o.cost for o in term.recommended)
    assert any(not o.feasible for o in term.options.values())


def test_plan_is_spread_over_the_whole_term():
    term = _plan(target_days=6).term("sem1")
    days = [o.day for o in term.recommended]
    assert len(days) == 6
    span = (term.close - date(2026, 9, 21)).days
    # Not front-loaded: the picks reach the last third of the term ...
    assert days[-1] >= date(2026, 9, 21) + timedelta(days=span * 2 // 3)
    # ... and never cluster: no two picks within one school week.
    gaps = [(b - a).days for a, b in pairwise(days)]
    assert min(gaps) >= 7


def test_final_week_avoided_when_other_days_exist():
    term = _plan().term("sem1")
    final = set(term.school_days[-FINAL_WEEK_DAYS:])
    assert term.recommended
    assert not final & {o.day for o in term.recommended}


def test_target_counts_already_planned_days():
    planned = [{"start_date": "2026-10-07", "end_date": "2026-10-07"}]
    term = _plan(planned=planned, target_days=3).term("sem1")
    assert len(term.recommended) == 2
    assert term.target == 3


def test_bridge_day_before_a_holiday_monday():
    holiday = {date(2026, 9, 28)}  # Monday
    term = _plan(holidays=holiday).term("sem1")
    friday = term.options[date(2026, 9, 25)]
    assert friday.streak == 4
    assert "bridge" in friday.tags
    monday_after = term.options[date(2026, 10, 5)]
    assert "long_weekend" in monday_after.tags


def test_plan_varies_weekdays():
    term = _plan().term("sem1")
    weekdays = {o.day.weekday() for o in term.recommended}
    assert len(weekdays) >= 2


def test_impact_levels():
    plan = _plan(states=_states(m_pct=20.0, m_taught=20.0))
    term = plan.term("sem1")
    m = term.budget_by_canon["m"]
    # A range long enough to blow the school limit for M.
    impacts = plan.impact_of_entry({"start_date": "2026-10-05", "end_date": "2026-11-27"})
    rows = {r.name: r for r in impacts[0][1]}
    assert rows["M"].level == "over"
    assert rows["M"].cost > m.school_left
    # One Wednesday (F only) is fine.
    impacts = plan.impact_of_entry({"start_date": "2026-10-07", "end_date": "2026-10-07"})
    assert [r.level for r in impacts[0][1]] == ["ok"]


def test_planned_entry_over_limit_is_flagged():
    plan = _plan(states=_states(m_pct=20.0, m_taught=20.0),
                 planned=[{"start_date": "2026-10-05", "end_date": "2026-11-06"}])
    term = plan.term("sem1")
    assert term.planned and "m" in term.planned[0].over
    assert term.budget_by_canon["m"].status == "over"


def test_no_states_no_plan():
    plan = build_year_plan([], TIMETABLE, TEMPLATE, today=date(2026, 9, 21))
    assert plan.terms == []


# -- AppState wiring -----------------------------------------------------------

def _seed(app_state):
    days = {}
    for offset in range(5):
        day = date(2026, 9, 21) + timedelta(days=offset)
        days[day.strftime("%d.%m.%Y")] = [
            {"subject": "Matematika", "time": "1 (8:00 - 8:45)"},
            {"subject": "Fyzika", "time": "2 (8:55 - 9:40)"},
        ]
    app_state.data = {"absence": {"Matematika": 5.0, "Fyzika": 0.0}, "timetable": days}
    app_state.demo_mode = False


def test_plan_days_batches_one_save(app_state, monkeypatch):
    from datetime import datetime

    _seed(app_state)
    saves = []
    real_save = app_state.config.save
    monkeypatch.setattr(app_state.config, "save", lambda: saves.append(1) or real_save())
    n = app_state.plan_days(["2026-10-01", "2026-10-08", "2026-10-01", "bad"], "tpl",
                            cancel_lunch=False)
    assert n == 2 and len(saves) == 1
    assert len(app_state.planned_skips) == 2
    plan = app_state.year_plan(datetime(2026, 9, 24, 7, 0))
    assert date(2026, 10, 1) in plan.default_term.planned_dates


def test_year_plan_is_cached_until_inputs_change(app_state):
    from datetime import datetime

    _seed(app_state)
    now = datetime(2026, 9, 24, 7, 0)
    first = app_state.year_plan(now)
    assert app_state.year_plan(now) is first
    app_state.plan_skip("2026-10-01", "tpl", cancel_lunch=False)
    assert app_state.year_plan(now) is not first


def test_first_plannable_day_is_clock_aware(app_state):
    from datetime import datetime

    _seed(app_state)
    assert app_state.first_plannable_day(datetime(2026, 9, 24, 7, 0)) == date(2026, 9, 24)
    assert app_state.first_plannable_day(datetime(2026, 9, 24, 12, 0)) == date(2026, 9, 25)


def test_target_days_setting_limits_the_plan(app_state):
    from datetime import datetime

    _seed(app_state)
    now = datetime(2026, 9, 24, 7, 0)
    assert app_state.set_planner_target(2)
    assert len(app_state.year_plan(now).default_term.recommended) <= 2
    assert app_state.planner_target_days() == 2


def _walk(control):
    yield control
    for attr in ("controls", "content"):
        child = getattr(control, attr, None)
        if isinstance(child, list):
            for c in child:
                yield from _walk(c)
        elif child is not None and hasattr(child, "__dict__"):
            yield from _walk(child)


class _Page:
    def __init__(self):
        self.dialogs = []

    def show_dialog(self, dlg):
        dlg.open = True
        self.dialogs.append(dlg)

    def pop_dialog(self):
        return None

    def update(self):
        pass


def test_planner_view_builds_with_data_and_calendar_opens_dialog(state):
    from datetime import datetime

    from strakalari.flet_ui.views import absences, planner, today

    _seed(state)
    now = datetime(2026, 9, 24, 7, 0)
    page = _Page()
    view = planner.build(state, page, now=now)
    clickable = [c for c in _walk(view)
                 if getattr(c, "tooltip", None) and getattr(c, "on_click", None)]
    assert clickable, "the semester overview has clickable days"
    clickable[0].on_click(None)
    assert page.dialogs and page.dialogs[-1].open
    # Both semesters are offered.
    sem2 = state.year_plan(now).term("sem2")
    assert sem2 is not None
    state.select_planner_term("sem2")
    assert planner.build(state, page, now=now) is not None
    assert absences.build(state, page) is not None
    assert today.build(state, page, now=now) is not None
