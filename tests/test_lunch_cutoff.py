"""Lunch ordering cutoff: previous business day at the set time (GEKOM 12:00)."""

from datetime import date, datetime

from strakalari.core import school_presets as sp
from strakalari.core.lunch_cutoff import (
    is_business_day,
    is_lunch_order_open,
    is_valid_cutoff_time,
    lunch_order_deadline,
    normalize_cutoff_time,
    parse_cutoff_time,
    previous_business_day,
)


def test_gekom_preset_cutoff_defaults_to_noon():
    assert sp.preset_lunch_cutoff("gekom_2026_2027") == "12:00"
    assert sp.preset_lunch_cutoff("custom") == ""
    assert sp.preset_lunch_cutoff("unknown-id") == ""


def test_resolve_lunch_cutoff_user_wins_then_preset():
    assert sp.resolve_lunch_cutoff({"school_preset_id": "gekom_2026_2027"}) == "12:00"
    cfg = {"school_preset_id": "gekom_2026_2027", "lunch_order_cutoff_time": "10:30"}
    assert sp.resolve_lunch_cutoff(cfg) == "10:30"
    # Invalid user value falls back to the preset, then to GEKOM 12:00.
    assert sp.resolve_lunch_cutoff({"school_preset_id": "gekom_2026_2027",
                                    "lunch_order_cutoff_time": "nope"}) == "12:00"
    assert sp.resolve_lunch_cutoff({"school_preset_id": "custom"}) == "12:00"


def test_parse_and_validate_cutoff():
    assert parse_cutoff_time("12:00") == (12, 0)
    assert parse_cutoff_time("9:05") == (9, 5)
    assert parse_cutoff_time("") == (12, 0)
    assert parse_cutoff_time("bogus") == (12, 0)
    assert parse_cutoff_time("25:00") == (12, 0)
    assert normalize_cutoff_time("9:05") == "09:05"
    assert is_valid_cutoff_time("") is True
    assert is_valid_cutoff_time("12:00") is True
    assert is_valid_cutoff_time("9:05") is True
    assert is_valid_cutoff_time("24:00") is False
    assert is_valid_cutoff_time("noon") is False


def test_previous_business_day_skips_weekend():
    # Monday lunch -> Friday deadline.
    assert previous_business_day(date(2026, 9, 7)) == date(2026, 9, 4)
    # Tuesday lunch -> Monday deadline.
    assert previous_business_day(date(2026, 9, 8)) == date(2026, 9, 7)
    # Sunday lunch -> Friday deadline.
    assert previous_business_day(date(2026, 9, 13)) == date(2026, 9, 11)


def test_previous_business_day_skips_free_days():
    free = {date(2026, 9, 4)}  # Friday off -> Thursday deadline.
    assert previous_business_day(date(2026, 9, 7), free) == date(2026, 9, 3)
    assert is_business_day(date(2026, 9, 4), free) is False
    assert is_business_day(date(2026, 9, 5)) is False  # Saturday
    assert is_business_day(date(2026, 9, 7), free) is True


def test_deadline_is_noon_previous_business_day():
    from datetime import timedelta, timezone

    cest = timezone(timedelta(hours=2), name="Europe/Prague")  # September
    assert lunch_order_deadline(date(2026, 9, 7), "12:00") == datetime(
        2026, 9, 4, 12, 0, tzinfo=cest)
    assert lunch_order_deadline(date(2026, 9, 8), "10:30") == datetime(
        2026, 9, 7, 10, 30, tzinfo=cest)


def test_is_open_until_cutoff_then_closed():
    lunch = date(2026, 9, 8)  # Tuesday; deadline Mon 07.09. 12:00.
    assert is_lunch_order_open(lunch, datetime(2026, 9, 7, 11, 59), "12:00") is True
    assert is_lunch_order_open(lunch, datetime(2026, 9, 7, 12, 0), "12:00") is True
    assert is_lunch_order_open(lunch, datetime(2026, 9, 7, 12, 1), "12:00") is False
    assert is_lunch_order_open(lunch, datetime(2026, 9, 8, 8, 0), "12:00") is False


def test_monday_deadline_is_friday_noon():
    lunch = date(2026, 9, 7)  # Monday; deadline Fri 04.09. 12:00.
    assert is_lunch_order_open(lunch, datetime(2026, 9, 4, 12, 0), "12:00") is True
    assert is_lunch_order_open(lunch, datetime(2026, 9, 6, 12, 0), "12:00") is False


def test_state_rejects_closed_day_and_filters_submit(monkeypatch):
    from strakalari.flet_ui.state import AppState
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    # Pin "now" past the deadline for 08.09.2026 (deadline Mon 07.09. 12:00).
    monkeypatch.setattr(state, "is_lunch_order_open",
                        lambda day, now=None: str(day) != "08.09.2026")
    assert state.order_lunch("08.09.2026", "m1") is False
    assert "08.09.2026" not in state.orders
    # A stale staged pick on a closed day is not transmitted, but stays
    # staged (a later cutoff re-opens it) — nothing is marked as sent.
    state.orders["08.09.2026"] = "m1"
    state.pending_orders.add("08.09.2026")
    assert state.submit_orders() is False
    assert state.orders["08.09.2026"] == "m1"
    assert "08.09.2026" in state.pending_orders


class TestCutoffSpelling:
    def test_dot_spelling_valid(self):
        from strakalari.core.lunch_cutoff import (
            is_valid_cutoff_time, parse_cutoff_time)
        assert is_valid_cutoff_time("12.30") is True
        assert parse_cutoff_time("12.30") == (12, 30)

    def test_garbage_still_invalid(self):
        from strakalari.core.lunch_cutoff import is_valid_cutoff_time
        assert is_valid_cutoff_time("noon") is False
        assert is_valid_cutoff_time("24.00") is False
        assert is_valid_cutoff_time("") is True
