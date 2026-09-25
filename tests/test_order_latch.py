"""Order-submit latch + excuse-kind mapping (audit fixes).

submit_orders() claims the ``order_running`` latch; every staging exit
that does NOT hand the payload to the worker must release it again,
or Odeslat stays dead until restart. submit_excuse() must map the new
task kind ``early`` to the hour-based ``soon`` web excuse type (the
same form as ``soon``; ``income`` is late arrival).
"""
import pytest

import strakalari.flet_ui.state as state_mod
from strakalari.flet_ui.state import AppState


@pytest.fixture
def state(monkeypatch):
    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    st = AppState()
    monkeypatch.setattr(st, "strava_enabled", lambda: True)
    # A configured install: the data dir is empty in tests, which would
    # otherwise leave the state in demo mode without credentials.
    st.demo_mode = False
    return st


def test_empty_payload_releases_latch(state, monkeypatch):
    # Staged pick on a closed day filters to an empty payload -> False,
    # but the latch must be free for the next attempt.
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: False)
    state.orders["08.09.2026"] = "m1"
    state.pending_orders.add("08.09.2026")  # only staged picks are sent
    assert state.submit_orders() is False
    assert state.order_running is False
    # A later (open) attempt must not be stuck behind the leaked latch.
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)
    monkeypatch.setattr(state, "_spawn", lambda target, args=(), name="": None)
    assert state.submit_orders() is True
    assert state.order_running is True


def test_demo_no_credentials_releases_latch(state, monkeypatch):
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)
    state.orders["08.09.2026"] = "m1"
    state.demo_mode = True
    monkeypatch.setattr(state, "_has_any_credentials", lambda: False)
    assert state.submit_orders() is False
    assert state.order_running is False


def test_nothing_pending_releases_latch(state):
    state.orders = {}
    state.cancelled_lunches = set()
    assert state.submit_orders() is False
    assert state.order_running is False


def _run_excuse(state, monkeypatch, kind):
    """Runs submit_excuse inline with a stubbed browser backend."""
    captured = {}

    class _StubApp:
        excuse_mode = ""

        def __init__(self, on_log=None, start_browser=True):
            pass

        def excuse_single(self, excuse, custom_text=None):
            captured.update(excuse)
            captured["custom_text"] = custom_text
            return True

        def close(self):
            pass

    import strakalari.core.automation as automation_mod

    monkeypatch.setattr(automation_mod, "Strakalari", _StubApp)
    monkeypatch.setattr(state, "_spawn",
                        lambda target, args=(), name="": target())
    state.demo_mode = False
    task = {"key": f"k-{kind}", "kind": kind, "label": "M",
            "date": "2026-09-10", "period": 2}
    assert state.submit_excuse(task, template="Omluvte prosím.") is True
    return captured


@pytest.mark.parametrize(("kind", "expected"), [
    ("early", "soon"),
    ("soon", "soon"),
    ("late", "income"),
    ("short", "days and hours"),
])
def test_excuse_kind_to_web_type(state, monkeypatch, kind, expected):
    captured = _run_excuse(state, monkeypatch, kind)
    assert captured["type"] == expected
    assert captured["starting_lesson"] == 2
    assert captured["ending_lesson"] == 2
