"""A lunch pick is a change only when it differs from the fetched order.

Regression test for: clicking the meal that is already ordered on Strava
marked the day "to send" (badge count on Obědy, re-sent on Odeslat).
"""
import pytest

import strakalari.flet_ui.state as state_mod
from strakalari.flet_ui.state import AppState
from strakalari.flet_ui.strings import S

DAY = "08.09.2026"
OTHER = "09.09.2026"
NO_LUNCH = "T1&-1&0"


@pytest.fixture
def state(monkeypatch):
    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    st = AppState()
    monkeypatch.setattr(st, "strava_enabled", lambda: True)
    monkeypatch.setattr(st, "is_lunch_order_open", lambda day, now=None: True)
    st.demo_mode = False
    # Fetched from Strava: meal A ordered on DAY, nothing on OTHER.
    st.web_orders = {DAY: "T1&A&0"}
    st.orders = dict(st.web_orders)
    st.pending_orders = set()
    return st


def _status(state, day):
    from strakalari.flet_ui.views.lunches import LunchView

    ordered = state.orders.get(day) or state.web_orders.get(day)
    badge = LunchView(state, None)._day_status(day, ordered)
    return None if badge is None else badge.content.value


def test_repicking_the_ordered_meal_is_no_change(state):
    assert state.order_lunch(DAY, "T1&A&0") is True
    assert state.pending_orders == set()
    assert state.pending_lunch_count == 0
    assert state.lunch_is_change(DAY) is False
    assert _status(state, DAY) == S("web_ordered")
    assert state.submit_orders() is False  # nothing to send


def test_a_different_meal_is_a_change_until_picked_back(state):
    state.order_lunch(DAY, "T1&B&0")
    assert state.pending_orders == {DAY} and state.pending_lunch_count == 1
    assert _status(state, DAY) == S("to_send")
    state.order_lunch(DAY, "T1&A&0")  # back to what Strava has
    assert state.pending_orders == set() and state.pending_lunch_count == 0
    assert _status(state, DAY) == S("web_ordered")


def test_no_lunch_compares_with_the_web_too(state):
    state.order_lunch(OTHER, NO_LUNCH)  # nothing ordered there anyway
    assert OTHER not in state.pending_orders
    assert _status(state, OTHER) is None
    state.order_lunch(DAY, NO_LUNCH)  # cancels the ordered meal A
    assert DAY in state.pending_orders and state.pending_lunch_count == 1


def test_submit_sends_only_picks_that_differ(state, monkeypatch):
    logged = []
    monkeypatch.setattr(state, "log", logged.append)
    monkeypatch.setattr(state, "_spawn", lambda target, args=(), name="": None)
    state.pending_orders = {DAY, OTHER}  # e.g. staged before this fix
    state.orders[OTHER] = "T2&C&0"
    assert state.submit_orders() is True
    assert f"{S('orders_sending')} (1)" in logged


def test_refresh_unstages_a_pick_the_web_now_reports(state, monkeypatch):
    state.order_lunch(DAY, "T1&B&0")
    assert DAY in state.pending_orders
    # Ordered meanwhile (website, another device): the fetch reports B.
    monkeypatch.setattr(state_mod, "load_data_cache",
                        lambda: {"strava_ordered": {"8.9.2026": "T1&B&0"}})
    state.reload_cache()
    assert state.pending_orders == set() and state.pending_lunch_count == 0
    assert state.orders[DAY] == "T1&B&0"
