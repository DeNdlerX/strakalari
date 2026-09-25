"""Absence upgrade: full overview rows, subject directory, tracked set.

The overview table carries elapsed hours plus display:none-gated school
verdict badges per subject; the subject directory is the canonical
absence-tracked set (homeroom hour is listed in the overview but has no
directory entry and is not tracked for real).
"""

from datetime import date

from strakalari.core.extractors.bakalari import (
    extract_absence_details,
    extract_absence_percentages,
    parse_subject_directory,
)
from strakalari.core.forecast import canon_subject, forecast_all, forecast_subject
from strakalari.core.models import SubjectState


def _absence_html():
    def _row(subject, total, missed, pct, warn_visible=False, err_visible=False):
        def _badge(label, visible):
            style = "" if visible else ' style="display: none;"'
            return f'<span class="bk-badge warn"{style}>{label}</span>'

        return (
            "<tr>"
            f'<td aria-colindex="1">{subject}</td>'
            f'<td aria-colindex="2">{total}</td>'
            f'<td aria-colindex="3">{missed}</td>'
            f'<td aria-colindex="4">{pct}</td>'
            "<td aria-colindex=\"5\">"
            '<div data-options="dxTemplate: { name: \'percentBadge\'}">'
            + _badge("Blíží se limitu", warn_visible)
            + _badge("Nelze klasifikovat", err_visible)
            + "</div></td>"
            '<td aria-colindex="6"></td></tr>'
        )

    return (
        "<table>"
        + _row("Matematika", "8", "2", "25,0 %", warn_visible=True)
        + _row("Anglický jazyk", "6", "0", "0,00 %")
        + _row("Třídnická hodina", "4", "0", "0,00 %")
        + "</table>"
    )


def _directory_html():
    return (
        "<table>"
        "<tr><td>Matematika</td><td>Mgr. Jana Tláskalová</td></tr>"
        "<tr><td>Anglický jazyk</td><td>Mgr. Klára Perlíková Ph.D.</td></tr>"
        "<tr><td></td><td>Mgr. Nikdo Prázdný</td></tr>"
        "</table>"
    )


def test_details_parse_hours_and_badges():
    details = extract_absence_details(_absence_html())
    assert set(details) == {"Matematika", "Anglický jazyk", "Třídnická hodina"}
    math = details["Matematika"]
    assert math["percent"] == 25.0
    assert math["total_hours"] == 8.0
    assert math["missed_hours"] == 2.0
    assert math["approaching"] is True
    assert math["unclassifiable"] is False
    aj = details["Anglický jazyk"]
    assert aj["percent"] == 0.0
    # Hidden badges (display:none) mean no flag.
    assert aj["approaching"] is False
    assert aj["unclassifiable"] is False


def test_details_agree_with_legacy_percentages():
    details = extract_absence_details(_absence_html())
    legacy = extract_absence_percentages(_absence_html())
    assert legacy == {k: v["percent"] for k, v in details.items()}


def test_details_never_raise():
    assert extract_absence_details("") == {}
    assert extract_absence_details(None) == {}
    assert extract_absence_details("<html>no table</html>") == {}


def test_directory_parses_subject_teacher_pairs():
    directory = parse_subject_directory(_directory_html())
    assert directory == {
        "Matematika": "Mgr. Jana Tláskalová",
        "Anglický jazyk": "Mgr. Klára Perlíková Ph.D.",
    }


def test_directory_never_raises():
    assert parse_subject_directory("") == {}
    assert parse_subject_directory(None) == {}
    assert parse_subject_directory("<html>no table</html>") == {}


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
