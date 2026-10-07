"""Absence: the subject directory as the tracked set, school verdicts, taught-hour overrides.

The subject directory is the canonical absence-tracked set (the homeroom
hour shows up in the absence data but has no directory entry and is not
tracked for real).
"""

from datetime import date

from strakalari.core.forecast import canon_subject, forecast_all, forecast_subject
from strakalari.core.models import SubjectState


def test_canon_subject_collapses_nbsp_and_case():
    assert canon_subject("Seminář z matematiky S") == canon_subject("Seminář z matematiky S")
    assert canon_subject("Seminář z\xa0matematiky S") == "seminář z matematiky s"
    assert canon_subject("  M  ") == "m"


def _timetable():
    return {
        "07.09.2026": [
            {"subject": "Matematika", "teacher": "T", "room": "R",
             "time": "1 (8:00 - 8:45)"},
            {"subject": "Třídnická hodina", "teacher": "T", "room": "R",
             "time": "2 (8:55 - 9:40)"},
        ],
    }


def test_tracked_set_drops_homeroom_but_none_disables_filter():
    absence = {"Matematika": 10.0, "Třídnická hodina": 50.0}
    tracked = {"Matematika", "Anglický jazyk"}
    states, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                             tracked_subjects=tracked)
    assert {s.name for s in states} == {"Matematika"}
    # Unknown directory (None): no filtering at all.
    states, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                             tracked_subjects=None)
    assert {s.name for s in states} == {"Matematika", "Třídnická hodina"}


def test_school_badges_escalate_status():
    absence = {"Matematika": 5.0}
    details = {"Matematika": {"percent": 5.0, "total_hours": 8.0,
                              "missed_hours": 0.0, "approaching": True,
                              "unclassifiable": False}}
    states, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                             default_limit=25.0, absence_details=details)
    assert states[0].status == "warning"
    details["Matematika"]["unclassifiable"] = True
    states, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                             default_limit=25.0, absence_details=details)
    assert states[0].status == "critical"
    assert states[0].plan_status == "critical"


def test_taught_hours_override_beats_estimate():
    absence = {"Matematika": 50.0}
    plain, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                            default_limit=25.0)
    assert plain and plain[0].taught_hours == 0.0
    details = {"Matematika": {"percent": 50.0, "total_hours": 8.0,
                              "missed_hours": 4.0, "approaching": False,
                              "unclassifiable": False}}
    exact, _ = forecast_all(absence, _timetable(), today=date(2026, 9, 7),
                            default_limit=25.0, absence_details=details)
    assert exact[0].taught_hours == 8.0
    # Real elapsed hours (8) beat the calendar estimate, so the budget differs.
    assert exact[0].safe_hours_left != plain[0].safe_hours_left


def test_forecast_subject_taught_override_math():
    estimated = forecast_subject(50.0, 4, 100, 150, 25.0)
    exact = forecast_subject(50.0, 4, 100, 150, 25.0, taught_hours=8.0)
    # 50% of 8 taught = 4 missed vs 50% of the ~100-day estimate.
    assert exact.safe_hours_left > estimated.safe_hours_left


def test_state_defaults_keep_old_behavior():
    state = SubjectState(name="M", current_pct=5.0, limit_pct=25.0)
    assert state.status == "ok"
    assert state.plan_status == "ok"
    assert state.approaching is False
    assert state.unclassifiable is False
    assert state.taught_hours == 0.0
