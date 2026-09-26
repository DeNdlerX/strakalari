"""The UI ignore list: auto mode honors it, and a failed save never leaves a memory-only ignore."""
from datetime import datetime

import pytest

from strakalari.core.automation import Strakalari, generate_excuses
from strakalari.core.models import excuse_tasks_from_lessons, lessons_from_timetable

TODAY = datetime(2026, 9, 20)


def _absent(time):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": "Absent", "absencetext": "Absence", "notice": ""}


def _ui_key(raw, period):
    """The exact key the UI stores when the user clicks Ignore."""
    tasks = excuse_tasks_from_lessons(lessons_from_timetable(raw))
    return next(t.key for t in tasks if t.period == period)


# -- auto mode honors the UI ignore list -----------------------------------

class TestIgnoredExcuses:
    def test_ignored_lesson_is_never_auto_excused(self):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)"), _absent("2 (8:55-9:40)"),
                              _absent("3 (10:00-10:45)")]}
        key = _ui_key(raw, 2)
        excuses = generate_excuses(raw, delay_days=0, override_today=TODAY,
                                   ignored=[key])
        # No whole-day excuse (it would cover lesson 2), lesson 2 left out.
        assert {(e["type"], e.get("starting_lesson"), e.get("ending_lesson"))
                for e in excuses} == {("days and hours", 1, 1),
                                      ("days and hours", 3, 3)}

    def test_ignored_day_breaks_full_day_chain(self):
        raw = {"07.09.2026": [_absent("1 (8:00-8:45)")],
               "08.09.2026": [_absent("1 (8:00-8:45)")],
               "09.09.2026": [_absent("1 (8:00-8:45)")]}
        key = _ui_key({"08.09.2026": raw["08.09.2026"]}, 1)
        excuses = generate_excuses(raw, delay_days=0, override_today=TODAY,
                                   ignored=[key])
        assert [(e["starting_day"], e["ending_day"]) for e in excuses] == [
            ("07.09.2026", "07.09.2026"), ("09.09.2026", "09.09.2026")]

    def test_excuse_absence_passes_config_ignore_list(self, monkeypatch):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)")]}
        monkeypatch.setattr(Strakalari, "timetableData", property(lambda self: raw))
        app = Strakalari.__new__(Strakalari)
        app.excuse_mode = "auto"
        app.excuse_delay_days = 0
        app.cancel_requested = False
        app.config_data = {"ignored_excuses": [_ui_key(raw, 1)]}
        app.write_log = lambda m: None
        app._send_excuse = lambda *a, **k: pytest.fail("ignored absence was sent")
        assert app.excuse_pending() == 0

    def test_garbage_keys_are_ignored_safely(self):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)")]}
        assert generate_excuses(raw, delay_days=0, override_today=TODAY,
                                ignored=["nonsense", "2026-13-01|1|M", None]) == \
            generate_excuses(raw, delay_days=0, override_today=TODAY)


# -- ignore list: a failed save must not leave a memory-only ignore ------------

def _failing_save(state, monkeypatch):
    def _boom():
        raise RuntimeError("lock busy")

    monkeypatch.setattr(state.config, "save", _boom)


def test_ignore_rolls_back_when_save_fails(state, monkeypatch):
    _failing_save(state, monkeypatch)
    assert state.ignore_excuse("2026-09-01|2|Matematika") == ""
    assert state.ignored_excuse_keys == set()
    # The config copy is rolled back too, so a later unrelated save
    # cannot persist the ignore behind the user's back.
    assert state.config.get("ignored_excuses", []) == []
    assert state.last_ignore_error


def test_unignore_rolls_back_when_save_fails(state, monkeypatch):
    assert state.ignore_excuse("2026-09-01|2|Matematika")
    _failing_save(state, monkeypatch)
    assert state.unignore_excuse("2026-09-01|2|Matematika") is False
    assert state.ignored_excuse_keys == {"2026-09-01|2|Matematika"}
    assert state.config.get("ignored_excuses") == ["2026-09-01|2|Matematika"]


def test_ignore_day_rolls_back_when_save_fails(state, monkeypatch):
    tasks = [{"key": "2026-09-01|1|A", "date": "2026-09-01"},
             {"key": "2026-09-01|2|B", "date": "2026-09-01"}]
    monkeypatch.setattr(state, "_all_excuse_tasks", lambda: tasks)
    _failing_save(state, monkeypatch)
    assert state.ignore_day("2026-09-01") == []
    assert state.ignored_excuse_keys == set()
    assert state.last_ignore_error


def test_ignore_saved_normally(state):
    assert state.ignore_excuse("2026-09-01|2|Matematika") == "2026-09-01|2|Matematika"
    assert state.last_ignore_error == ""
    assert state.unignore_keys(["2026-09-01|2|Matematika"]) is True
    assert state.ignored_excuse_keys == set()
