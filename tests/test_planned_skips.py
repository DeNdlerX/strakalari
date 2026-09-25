"""Planned skips: normalization and the planner accept/undo flow."""


def _seed_week(state):
    from datetime import timedelta

    base = __import__("datetime").date(2026, 9, 7)
    days = {}
    for week in range(3):
        for add in (0, 1):
            day = base + timedelta(days=week * 7 + add)
            days[day.strftime("%d.%m.%Y")] = [
                {"subject": "Matematika", "time": "1 (8:00 - 8:45)",
                 "room": "U12", "teacher": "Novak"},
            ]
    state.data = {"absence": {"Matematika": 5.0}, "timetable": days}
    state.demo_mode = False


def test_plan_custom_skip_reports_persist_failure(state, monkeypatch):
    _seed_week(state)

    def _boom():
        raise OSError("disk full")

    monkeypatch.setattr(state.config, "save", _boom)
    assert state.plan_custom_skip("2026-09-15", "2026-09-15", None, None, "tpl") is False
    # Memory rolls back to match disk: nothing was planned, nothing to unplan.
    assert state.planned_skips == []
    assert state.unplan_entry({"start_date": "2026-09-15",
                               "end_date": "2026-09-15",
                               "template": "tpl"}) is False


def test_plan_skip_reports_invalid_range(app_state):
    assert app_state.plan_skip("2026-09-08", "template") is True
    assert app_state.plan_skip("not-a-date", "template") is False


def test_unplan_entry_reports_stale(app_state):
    assert app_state.plan_skip("2026-09-08", "template") is True
    entry = dict(app_state.planned_skips[-1])
    assert app_state.unplan_entry(entry) is True
    assert app_state.unplan_entry(entry) is False  # already gone: no toast


def test_normalize_planned_entry_keeps_period_zero():
    from strakalari.core.planned_skips import normalize_planned_entry as _normalize_planned_entry

    entry = _normalize_planned_entry({
        "start_date": "2026-10-05", "end_date": "2026-10-05",
        "start_period": 0, "end_period": 0, "template": "t",
    })
    assert entry is not None
    assert entry["start_period"] == 0
    assert entry["end_period"] == 0


def test_plan_custom_skip_rolls_back_on_persist_failure(app_state, monkeypatch):
    monkeypatch.setattr(app_state.config, "save",
                        lambda: (_ for _ in ()).throw(OSError("disk full")))
    ok = app_state.plan_custom_skip("2030-10-05", "2030-10-05",
                                    None, None, "tpl", cancel_lunch=True)
    assert ok is False
    assert app_state.planned_skips == []
    assert app_state.cancelled_lunches == set()
    assert app_state.orders == {}
    assert app_state.pending_orders == set()


def test_unplan_entry_rolls_back_on_persist_failure(app_state, monkeypatch):
    assert app_state.plan_custom_skip("2030-10-05", "2030-10-05",
                                      None, None, "tpl") is True
    entry = app_state.planned_skips[0]
    monkeypatch.setattr(app_state.config, "save",
                        lambda: (_ for _ in ()).throw(OSError("disk full")))
    assert app_state.unplan_entry(entry) is False
    assert app_state.planned_skips == [entry]
