"""Regression tests: the 'Pouzit filtr' button must hide prefs-disliked
meals (not just blacklist ones) and stage first-allowed picks.

Config writes are stubbed out — these tests must never touch the real
user config on disk.
"""
from datetime import date, timedelta

import pytest

from strakalari.core.matching import prefs_ban_keywords
from strakalari.flet_ui.state import AppState


@pytest.fixture()
def state(monkeypatch):
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = AppState()
    app_state.save = lambda updates: updates
    app_state.demo_mode = False
    app_state.blacklist_words = lambda: []
    app_state._auto_lunch_is_open = lambda: (lambda day: True)
    return app_state


def _food(day):
    return {
        day: {
            "jidlo&1&x": "Vepřové maso na paprice",
            "jidlo&2&x": "Kuřecí prsa s rýží",
        }
    }


@pytest.fixture()
def future():
    return (date.today() + timedelta(days=7)).strftime("%d.%m.%Y")


class TestPrefsKeywords:
    def test_negation_clause_yields_keyword(self):
        assert prefs_ban_keywords("nemám rád vepřové") == ["vepřové"]

    def test_likes_clause_ignored(self):
        assert prefs_ban_keywords("mám rád kuřecí") == []
        assert prefs_ban_keywords("preferuji lehká jídla") == []

    def test_mixed_text_keeps_only_dislikes(self):
        words = prefs_ban_keywords("nemám rád vepřové, preferuji lehká jídla")
        assert words == ["vepřové"]

    def test_bez_form(self):
        assert prefs_ban_keywords("bez hub a česneku") == ["hub", "česneku"]

    def test_conjunction_like_segment_ignored(self):
        assert prefs_ban_keywords("nemám rád vepřové a mám rád kuřecí") == ["vepřové"]
        assert prefs_ban_keywords("mám rád kuřecí a nemám rád vepřové") == ["vepřové"]

    def test_english_no_form(self):
        assert prefs_ban_keywords("no pork") == ["pork"]

    def test_empty(self):
        assert prefs_ban_keywords("") == []
        assert prefs_ban_keywords(None) == []


class TestApplyFoodFilter:
    def test_prefs_hide_and_stage(self, state, future):
        state.data = {"absence": {"x": 1}, "food": _food(future)}
        state.apply_food_filter("nemám rád vepřové, preferuji lehká jídla")
        assert state.lunch_hidden == {"jidlo&1&x"}
        assert state.orders.get(future) == "jidlo&2&x"
        assert future in state.pending_orders

    def test_good_pick_not_clobbered(self, state, future):
        state.data = {"absence": {"x": 1}, "food": _food(future)}
        state.orders = {future: "jidlo&2&x"}
        state.apply_food_filter("nemám rád vepřové")
        assert state.orders.get(future) == "jidlo&2&x"

    def test_hidden_pick_replaced(self, state, future):
        state.data = {"absence": {"x": 1}, "food": _food(future)}
        state.orders = {future: "jidlo&1&x"}
        state.apply_food_filter("nemám rád vepřové")
        assert state.orders.get(future) == "jidlo&2&x"

    def test_cancelled_day_skipped(self, state, future):
        state.data = {"absence": {"x": 1}, "food": _food(future)}
        state.cancelled_lunches.add(future)
        state.apply_food_filter("nemám rád vepřové")
        assert state.lunch_hidden == {"jidlo&1&x"}
        assert future not in state.orders

    def test_closed_day_hides_but_stages_nothing(self, state, future):
        state.data = {"absence": {"x": 1}, "food": _food(future)}
        state._auto_lunch_is_open = lambda: (lambda day: False)
        state.apply_food_filter("nemám rád vepřové")
        assert state.lunch_hidden == {"jidlo&1&x"}
        assert state.orders == {}
