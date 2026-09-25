"""Tests for the Flet data wiring (real cache shapes, not demo shapes)."""

from datetime import date

from strakalari.core.models import (
    Lesson,
    canonical_day_key,
    excuse_tasks_from_lessons,
    lessons_from_timetable,
    parse_cz_date,
)


def test_parse_cz_date_accepts_weekday_suffix():
    assert parse_cz_date("10.9.2026 (čtvrtek)") == date(2026, 9, 10)
    assert parse_cz_date("7.9.2026 (pondělí)") == date(2026, 9, 7)
    assert parse_cz_date("07.09.2026") == date(2026, 9, 7)
    assert parse_cz_date("nonsense") is None


def test_canonical_day_key_unifies_formats():
    assert canonical_day_key("7.9.2026 (pondělí)") == "07.09.2026"
    assert canonical_day_key("07.09.2026") == "07.09.2026"
    assert canonical_day_key(date(2026, 9, 7)) == "07.09.2026"


def test_lesson_from_real_cache_row():
    raw = {
        "subject": "Matematika", "time": "3 (10:05 - 10:50)",
        "room": "III - (P06)", "teacher": "Mgr. Jana Tláskalová",
        "date": "10.9.2026 (čtvrtek)",
        "absenceType": "NoAbsent", "absencetext": "", "notice": "",
    }
    lesson = Lesson.from_legacy(raw, day="10.9.2026 (čtvrtek)")
    assert lesson.day == date(2026, 9, 10)
    assert lesson.status == ""
    assert lesson.excused is False


def test_lesson_status_mapping():
    base = {"subject": "M", "time": "1 (8:00 - 8:45)", "date": "7.9.2026 (pondělí)"}
    assert Lesson.from_legacy({**base, "absenceType": "Absent", "absencetext": "Absence"}).status == "absent"
    assert Lesson.from_legacy({**base, "absenceType": "AbsentLate", "absencetext": "Pozdní příchod"}).status == "late"
    assert Lesson.from_legacy({**base, "absenceType": "NoAbsent", "absencetext": "", "notice": "Suplování (Král)"}).change == "Suplování (Král)"
    assert Lesson.from_legacy({**base, "absenceType": "NoAbsent", "absencetext": "", "notice": "Odpadá"}).status == "cancelled"
    excused = Lesson.from_legacy({**base, "absenceType": "Omluveno", "absencetext": "Omluveno"})
    assert excused.status == "excused" and excused.excused is True
    # Demo rows keep working.
    demo = Lesson.from_legacy({"subject": "F", "time": "1. 8:00 - 8:45", "status": "late", "change": "X"}, day="07.09.2026")
    assert (demo.status, demo.change) == ("late", "X")


def test_excuse_tasks_from_real_absences():
    lessons = [
        Lesson(subject="M", day=date(2026, 9, 10), period=3, status="absent"),
        Lesson(subject="F", day=date(2026, 9, 10), period=4, status="late"),
        Lesson(subject="C", day=date(2026, 9, 10), period=5, status=""),
        Lesson(subject="E", day=date(2026, 9, 10), period=6, status="excused", excused=True),
    ]
    tasks = excuse_tasks_from_lessons(lessons)
    assert sorted(t.kind for t in tasks) == ["late", "short"]


def test_lessons_from_real_timetable_keys():
    raw = {
        "10.9.2026 (čtvrtek)": [
            {"subject": "Matematika", "time": "3 (10:05 - 10:50)",
             "absenceType": "NoAbsent", "absencetext": ""},
        ],
    }
    lessons = lessons_from_timetable(raw)
    assert len(lessons) == 1
    assert lessons[0].day == date(2026, 9, 10)


def test_state_uses_real_cache(tmp_path, monkeypatch):
    import json

    from strakalari.flet_ui.state import AppState

    cache = {
        "absence": {"Matematika": 5.0},
        "last_updated": "07.09.2026 13:34:13",
        "strava_meals": {"07.09.2026": {"a&1&0": "Guláš"}},
        "strava_ordered": {},
        "timetable": {
            "7.9.2026 (pondělí)": [
                {"subject": "Matematika", "time": "1 (8:00 - 8:45)",
                 "absenceType": "NoAbsent", "absencetext": ""},
            ],
        },
    }
    cache_file = tmp_path / "data_cache.json"
    cache_file.write_text(json.dumps(cache), encoding="utf-8")
    monkeypatch.setattr("strakalari.flet_ui.state.load_data_cache", lambda: json.loads(cache_file.read_text(encoding="utf-8")))
    state = AppState()
    assert state.demo_mode is False
    assert "07.09.2026" in state.timetable()
    assert "07.09.2026" in state.food()


def test_reload_prefers_web_truth_but_keeps_pending(monkeypatch):
    import json

    from strakalari.flet_ui.state import AppState

    backing = {"strava_ordered": {
        "07.09.2026": "web&1&0",
        "08.09.2026": "web&2&0",
        "09.09.2026": "web&1&0",
    }}
    monkeypatch.setattr(
        "strakalari.flet_ui.state.load_data_cache",
        lambda: json.loads(json.dumps(backing)))
    state = AppState()
    # Stale local pick, unsubmitted local pick, planned skip.
    state.orders = {"07.09.2026": "stale&9&0", "08.09.2026": "mine&3&0"}
    state.pending_orders = {"08.09.2026"}
    state.cancelled_lunches = {"09.09.2026"}
    state.reload_cache()
    # Web truth wins over the stale pick...
    assert state.orders["07.09.2026"] == "web&1&0"
    # ...the unsubmitted pick survives the refresh...
    assert state.orders["08.09.2026"] == "mine&3&0"
    # ...and the skip day gets no resurrected pick (it would void deorder).
    assert "09.09.2026" not in state.orders
    assert state.web_orders["07.09.2026"] == "web&1&0"


def test_order_lunch_marks_pending_until_cleared(monkeypatch):
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(
        "strakalari.flet_ui.state.load_data_cache", lambda: {})
    state = AppState()
    # Cutoff-independent: this test covers pending bookkeeping, not deadlines.
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)
    assert state.order_lunch("07.09.2026", "x&1&0") is True
    assert state.pending_orders == {"07.09.2026"}
    state.cancel_lunch_order("07.09.2026")
    assert state.pending_orders == set()
