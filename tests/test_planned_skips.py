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


# -- lesson picker: selection -> entries -------------------------------------

def test_entry_covers_follows_the_planner_rule():
    from datetime import date

    from strakalari.core.planned_skips import entry_covers

    entry = {"start_date": "2026-11-09", "end_date": "2026-11-11",
             "start_period": 4, "end_period": 2}
    assert entry_covers(entry, date(2026, 11, 9), 5)
    assert not entry_covers(entry, date(2026, 11, 9), 3)  # before the start on day one
    assert entry_covers(entry, date(2026, 11, 10), 1)  # middle day: whole
    assert entry_covers(entry, date(2026, 11, 11), 2)
    assert not entry_covers(entry, date(2026, 11, 11), 3)  # after the end on the last day
    assert not entry_covers(entry, date(2026, 11, 12), 1)
    assert entry_covers(entry, date(2026, 11, 9), None)  # unnumbered lesson: covered


def _sel(picked, lessons=None):
    from datetime import date

    from strakalari.core.planned_skips import entries_for_selection

    days = {date.fromisoformat(k): v for k, v in picked.items()}
    order = {date.fromisoformat(k): v for k, v in (lessons or {}).items()}
    for day in days:
        order.setdefault(day, [1, 2, 3, 4, 5, 6])
    return [{k: v for k, v in e.items() if k != "template"}
            for e in entries_for_selection(days, order, template="tpl")]


def test_whole_days_in_a_row_merge_across_a_weekend():
    six = [1, 2, 3, 4, 5, 6]
    entries = _sel({"2026-11-12": six, "2026-11-13": six, "2026-11-16": six})
    assert entries == [{"start_date": "2026-11-12", "end_date": "2026-11-16"}]


def test_a_gap_day_splits_the_range():
    six = [1, 2, 3, 4, 5, 6]
    entries = _sel({"2026-11-10": six, "2026-11-12": six})
    assert [e["start_date"] for e in entries] == ["2026-11-10", "2026-11-12"]
    assert all(e["start_date"] == e["end_date"] for e in entries)


def test_range_may_start_late_and_end_early():
    # Leave after the 3rd lesson on Monday, whole Tuesday, back for the 3rd on Wednesday.
    entries = _sel({"2026-11-09": [4, 5, 6], "2026-11-10": [1, 2, 3, 4, 5, 6],
                    "2026-11-11": [1, 2]})
    assert entries == [{"start_date": "2026-11-09", "end_date": "2026-11-11",
                        "start_period": 4, "end_period": 2}]


def test_scattered_lessons_become_separate_entries():
    entries = _sel({"2026-11-09": [1, 2, 5]})
    assert entries == [
        {"start_date": "2026-11-09", "end_date": "2026-11-09", "end_period": 2},
        {"start_date": "2026-11-09", "end_date": "2026-11-09", "start_period": 5,
         "end_period": 5},
    ]


def test_free_periods_do_not_split_a_run():
    # No lesson in period 3: picking 2 and 4 is one block.
    entries = _sel({"2026-11-09": [2, 4]}, {"2026-11-09": [1, 2, 4, 5]})
    assert entries == [{"start_date": "2026-11-09", "end_date": "2026-11-09",
                        "start_period": 2, "end_period": 4}]


def test_a_partial_day_does_not_join_the_next_one():
    six = [1, 2, 3, 4, 5, 6]
    entries = _sel({"2026-11-09": [1, 2], "2026-11-10": six})
    assert [(e["start_date"], e["end_date"]) for e in entries] == [
        ("2026-11-09", "2026-11-09"), ("2026-11-10", "2026-11-10")]


def test_ranges_are_capped_at_31_days():
    from datetime import date, timedelta

    six = [1, 2, 3, 4, 5, 6]
    start = date(2026, 11, 2)
    picked = {}
    for n in range(40):
        day = start + timedelta(days=n)
        if day.weekday() < 5:
            picked[day.isoformat()] = six
    entries = _sel(picked)
    assert len(entries) == 2
    for e in entries:
        span = (date.fromisoformat(e["end_date"]) - date.fromisoformat(e["start_date"])).days
        assert span < 31


def test_entries_keep_the_template_and_lunch_choice():
    from datetime import date

    from strakalari.core.planned_skips import entries_for_selection

    day = date(2026, 11, 9)
    kept = entries_for_selection({day: [1]}, {day: [1, 2]}, template="T", cancel_lunch=False)
    assert kept == [{"start_date": "2026-11-09", "end_date": "2026-11-09",
                     "end_period": 1, "template": "T", "cancel_lunch": False}]


def test_plan_entries_saves_all_at_once(app_state):
    entries = [
        {"start_date": "2030-10-07", "end_date": "2030-10-08", "template": "a"},
        {"start_date": "2030-10-10", "end_date": "2030-10-10", "start_period": 3,
         "template": "a"},
        {"start_date": "2030-10-10", "end_date": "2030-10-10", "start_period": 3,
         "template": "a"},  # duplicate
        {"start_date": "2030-10-01", "end_date": "2030-11-15", "template": "a"},  # > 31 days
    ]
    assert app_state.plan_entries(entries) == 2
    assert len(app_state.planned_skips) == 2
    assert app_state.plan_entries(entries[:2]) == 0  # already planned


def test_plan_entries_rolls_back_on_persist_failure(app_state, monkeypatch):
    monkeypatch.setattr(app_state.config, "save",
                        lambda: (_ for _ in ()).throw(OSError("disk full")))
    assert app_state.plan_entries([{"start_date": "2030-10-07",
                                    "end_date": "2030-10-07", "template": "a"}]) == 0
    assert app_state.planned_skips == []
