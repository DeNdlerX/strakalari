"""Week navigation in the timetable must not glitch.

Regression tests for: double full rebuild per click, stale build-time
index losing rapid clicks, no-op clicks rebuilding, and the old week's
scroll offset carrying into the new week.
"""

from datetime import date

import pytest

from strakalari.flet_ui.state import AppState


def _lesson():
    return {"subject": "Mat", "time": "1 (8:00 - 8:45)", "room": "U1",
            "teacher": "Novak"}


def _seed_3_weeks(state: AppState) -> list[date]:
    mondays = [date(2026, 9, 7), date(2026, 9, 14), date(2026, 9, 21)]
    days = {}
    for monday in mondays:
        days[monday.strftime("%d.%m.%Y")] = [_lesson()]
    state.data = {"timetable": days}
    state.demo_mode = False
    return mondays


@pytest.fixture()
def state():
    return AppState()


def _emit_counter(state: AppState):
    count = [0]

    def _tick():
        count[0] += 1

    state.listen(_tick)
    return count


def test_week_switch_emits_once(state):
    _seed_3_weeks(state)
    state.timetable_monday_iso = "2026-09-07"
    state.show_stable_timetable = True
    count = _emit_counter(state)
    state.go_timetable_week("2026-09-14")
    assert count[0] == 1
    assert state.timetable_monday_iso == "2026-09-14"
    assert state.show_stable_timetable is False


def test_week_switch_noop_emits_nothing(state):
    _seed_3_weeks(state)
    state.timetable_monday_iso = "2026-09-14"
    state.show_stable_timetable = False
    count = _emit_counter(state)
    state.go_timetable_week("2026-09-14")
    state.set_timetable_monday("2026-09-14")
    state.set_show_stable(False)
    assert count[0] == 0


def test_week_switch_resets_timetable_scroll(state):
    _seed_3_weeks(state)
    state.__dict__.setdefault("_scroll_offsets", {}).update({
        "timetable:table": 240.0,
        "timetable:list": 500.0,
        "lunches": 123.0,
    })
    state.go_timetable_week("2026-09-14")
    offsets = state.__dict__.get("_scroll_offsets", {})
    assert "timetable:table" not in offsets
    assert "timetable:list" not in offsets
    assert offsets.get("lunches") == 123.0


def test_rapid_next_clicks_advance_two_weeks(state):
    from strakalari.flet_ui.views import timetable as tt

    mondays = _seed_3_weeks(state)
    state.timetable_monday_iso = mondays[0].isoformat()
    view = tt.build(state, None)
    nav = view.controls[1]
    next_btn = nav.controls[2]
    # Two rapid clicks on the SAME built view (no rebuild in between —
    # this is where the stale build-time index used to lose a week).
    next_btn.on_click(None)
    assert state.timetable_monday_iso == mondays[1].isoformat()
    next_btn.on_click(None)
    assert state.timetable_monday_iso == mondays[2].isoformat()
