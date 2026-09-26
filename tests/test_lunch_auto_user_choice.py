"""Auto lunch ordering never overrides the user: it fills gaps only, respects planned days off and sends only staged picks."""
from datetime import date, timedelta

import pytest


FUTURE = (date.today() + timedelta(days=30))
DAY1 = FUTURE.strftime("%d.%m.%Y")
DAY2 = (FUTURE + timedelta(days=1)).strftime("%d.%m.%Y")
DAY3 = (FUTURE + timedelta(days=2)).strftime("%d.%m.%Y")
MENU = {
    DAY1: {"a&1&0": "Guláš", "a&2&0": "Kuře", "a&-1&0": "x"},
    DAY2: {"b&1&0": "Řízek", "b&2&0": "Rizoto", "b&-1&0": "x"},
    DAY3: {"c&1&0": "Polévka", "c&2&0": "Těstoviny", "c&-1&0": "x"},
}


@pytest.fixture()
def always_open(monkeypatch):
    import strakalari.core.lunch_auto as la

    monkeypatch.setattr(la, "order_window_predicate", lambda cfg, now=None: (lambda d: True))


# -- auto mode never overrides the user ------------------------------------

class TestAutoFillsGapsOnly:
    def test_existing_order_is_never_switched(self, always_open):
        from strakalari.core.lunch_auto import plan_auto_orders

        orders, _ = plan_auto_orders(MENU, {}, ordered={DAY1: "a&2&0"})
        assert DAY1 not in orders  # the user's meal 2 stays
        assert orders[DAY2] == "b&1&0"

    def test_handled_day_is_not_reordered_after_web_cancel(self, always_open):
        from strakalari.core.lunch_auto import plan_auto_orders

        orders, _ = plan_auto_orders(MENU, {}, ordered={}, handled=[DAY2])
        assert DAY2 not in orders
        assert DAY1 in orders and DAY3 in orders

    def test_planned_day_off_gets_its_lunch_cancelled(self, always_open):
        from strakalari.core.lunch_auto import plan_auto_orders

        orders, _ = plan_auto_orders(MENU, {}, ordered={DAY3: "c&1&0"},
                                     cancelled_days={DAY3})
        assert orders[DAY3] == "c&-1&0"

    def test_planned_day_off_without_order_gets_nothing(self, always_open):
        from strakalari.core.lunch_auto import plan_auto_orders

        orders, _ = plan_auto_orders(MENU, {}, ordered={}, cancelled_days={DAY3})
        assert DAY3 not in orders

    def test_handled_days_remember_orders_but_not_failures(self):
        from strakalari.core.lunch_auto import update_handled_days

        days = update_handled_days([], {DAY1: "a&2&0"}, [DAY2])
        assert set(days) == {DAY1, DAY2}
        old = (date.today() - timedelta(days=30)).strftime("%d.%m.%Y")
        assert old not in update_handled_days([old], {}, [])


class TestPlannedSkipLunchChoice:
    def test_keep_lunch_choice_is_stored_and_honored(self):
        from strakalari.core.planned_skips import normalize_planned_entry, planned_lunch_days

        keep = normalize_planned_entry({"start_date": "2099-10-05", "cancel_lunch": False})
        cancel = normalize_planned_entry({"start_date": "2099-10-06", "cancel_lunch": True})
        legacy = normalize_planned_entry({"start_date": "2099-10-07"})
        assert keep["cancel_lunch"] is False
        assert "cancel_lunch" not in cancel and "cancel_lunch" not in legacy
        days = planned_lunch_days({"planned_skips": [keep, cancel, legacy]})
        assert days == {"06.10.2099", "07.10.2099"}


# -- planned day off keeps its cancellation after a restart ------------------

def test_restart_does_not_resurrect_meal_on_planned_day(monkeypatch, tmp_path):
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache",
                        lambda: {"strava_ordered": {DAY1: "a&1&0"}, "strava_meals": MENU})
    cfg_path = str(tmp_path / "config.json")
    real_cm = state_mod.ConfigManager
    iso = FUTURE.isoformat()

    def _cm(*a, **k):
        cm = real_cm(config_path=cfg_path)
        cm.data["planned_skips"] = [{"start_date": iso, "end_date": iso}]
        return cm

    monkeypatch.setattr(state_mod, "ConfigManager", _cm)
    st = state_mod.AppState()
    assert DAY1 in st.cancelled_lunches
    assert DAY1 not in st.orders  # the web meal is not the local pick
    assert st.web_orders[DAY1] == "a&1&0"


# -- Send only transmits staged picks ------------------------------------------

def test_send_only_transmits_pending_picks(state, monkeypatch):
    state.demo_mode = False
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)
    captured = {}
    monkeypatch.setattr(state, "_spawn", lambda target, args=(), name="": captured.setdefault("t", target))
    state.orders = {DAY1: "a&1&0", DAY2: "b&2&0"}  # DAY1 = known web order
    state.web_orders = {DAY1: "a&1&0"}
    state.pending_orders = {DAY2}
    calls = []

    class _App:
        strava_order_mode = "confirm"
        last_ordered_days = set()

        def __init__(self, *a, **k):
            pass

        def strava_order_selected(self, payload, source="manual"):
            calls.append(dict(payload))
            return True

        def close(self):
            pass

    import strakalari.core.automation as auto_mod

    monkeypatch.setattr(auto_mod, "Strakalari", _App)
    assert state.submit_orders() is True
    captured["t"]()
    assert calls == [{DAY2: "b&2&0"}]
