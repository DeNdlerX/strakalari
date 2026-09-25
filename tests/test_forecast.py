"""Absence forecast and skip suggestions."""
from datetime import date

from strakalari.core import forecast as fc


class TestRareSubjects:
    def test_one_off_not_floored_to_one(self):
        from strakalari.core.forecast import weekly_hours_per_subject
        timetable = {f"{d:02d}.09.2026": [{"subject": "Common"}]
                     for d in range(1, 11)}
        timetable["01.09.2026"].append({"subject": "Rare"})
        hours = weekly_hours_per_subject(timetable)
        assert hours.get("Common") == 5
        assert "Rare" not in hours


class TestWarnThreshold:
    def test_explicit_warn_used(self):
        from strakalari.core.models import SubjectState
        state = SubjectState(name="M", current_pct=20.0, limit_pct=25.0, warn_pct=22.0)
        assert state.status == "ok"
        state2 = SubjectState(name="M", current_pct=20.0, limit_pct=25.0, warn_pct=18.0)
        assert state2.status == "warning"

    def test_fallback_stays_sixty_percent(self):
        from strakalari.core.models import SubjectState
        assert SubjectState(name="M", current_pct=14.0, limit_pct=25.0).status == "ok"
        assert SubjectState(name="M", current_pct=16.0, limit_pct=25.0).status == "warning"

    def test_forecast_passes_warn_through(self):
        from strakalari.core.forecast import forecast_all
        from datetime import date
        states, _days = forecast_all(
            {"M": 20.0}, {}, today=date(2026, 9, 7), warn_pct=22.0)
        assert states and states[0].warn_pct == 22.0
        assert states[0].status == "ok"


def test_nonstable_absence_subjects_are_free():
    from strakalari.core.forecast import forecast_all
    from strakalari.core.schedule import learn_stable_schedule
    from datetime import date

    timetable = {
        "01.09.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"}],
        "08.09.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"}],
    }
    baseline = learn_stable_schedule(timetable)
    states, days = forecast_all({"M": 10.0, "OneOff": 50.0}, timetable,
                                today=date(2026, 9, 7), stable_baseline=baseline)
    assert {s.name for s in states} == {"M"}  # OneOff: free, unbudgeted


def test_weekly_hours_counts_stable_week():
    timetable = {
        "01.09.2026": [{"subject": "Matematika"}, {"subject": "Matematika"}],
        "02.09.2026": [{"subject": "Fyzika"}],
    }
    assert fc.weekly_hours_per_subject(timetable) == {"Matematika": 2, "Fyzika": 1}


def test_school_days_skip_weekends_and_holidays():
    days = fc.school_days_between(date(2026, 9, 7), date(2026, 9, 13), {date(2026, 9, 8)})
    assert [d.weekday() for d in days] == [0, 2, 3, 4]  # Mon, Wed-Fri (Tue holiday)


def test_forecast_subject_math():
    state = fc.forecast_subject(
        current_pct=10.0, weekly_hours=4,
        school_days_left=50, school_days_total=100, limit_pct=30.0,
    )
    assert state.safe_hours_left > 0
    assert state.projected_pct <= 10.0
    assert state.status in ("ok", "warning")


def test_forecast_all_uses_per_subject_limits():
    absence = {"Matematika": 20.0, "Zeměpis": 20.0}
    timetable = {"01.09.2026": [{"subject": "Matematika"}, {"subject": "Zeměpis"}]}
    states, days = fc.forecast_all(
        absence, timetable, {"matematika": 30.0, "zeměpis": 20.0},
        today=date(2026, 9, 7),
    )
    by_name = {s.name: s for s in states}
    assert by_name["Matematika"].limit_pct == 30.0
    assert by_name["Zeměpis"].limit_pct == 20.0
    # Same current %, higher limit -> more hours left.
    assert by_name["Matematika"].safe_hours_left >= by_name["Zeměpis"].safe_hours_left
    assert len(days) > 0