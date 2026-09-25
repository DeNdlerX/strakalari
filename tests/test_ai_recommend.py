"""AI Recommend must stage usable picks even when Gemini answers empty/garbage.

Regression: a 200-OK Gemini reply with no usable meal picks used to return
``{}`` straight to the worker, which staged nothing and reported "no
changes" — the local keyword fallback only ran on exceptions.
"""

import threading

import strakalari.core.gemini as gemini_mod
from strakalari.core.gemini import recommend_lunches
from strakalari.core.gemini import parse_recommendation_response, local_fallback_recommendation


FOOD = {
    "16.09.2026": {"a&1&0": "Kureci rizek", "a&2&0": "Veprova pecene"},
    "17.09.2026": {"b&1&0": "Rybi file", "b&2&0": "Sunkove koleno"},
}

# Local fallback always takes the first meal of each day (all scores tie).
EXPECTED = {"16.09.2026": "a&1&0", "17.09.2026": "b&1&0"}


class _FakeResp:
    def __init__(self, payload: bytes):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _gemini_reply_text(text: str) -> bytes:
    import json as _json

    body = {"candidates": [{"content": {"parts": [{"text": text}]}}]}
    return _json.dumps(body).encode("utf-8")


def _patch_gemini(monkeypatch, text: str, calls: list | None = None):
    def _fake_urlopen(req, timeout=None):
        if calls is not None:
            calls.append(True)
        return _FakeResp(_gemini_reply_text(text))

    monkeypatch.setattr(gemini_mod.urllib.request, "urlopen", _fake_urlopen)
    monkeypatch.setattr(gemini_mod.time, "sleep", lambda *a, **k: None)


def test_empty_gemini_answer_falls_back_to_local(monkeypatch):
    """A well-formed reply with no JSON block still stages local picks."""
    _patch_gemini(monkeypatch, "Dnes doporučuji lehké jídlo, dobrou chuť!")
    html, orders = recommend_lunches(FOOD, "", "KEY", retries=0)
    assert orders == EXPECTED
    assert html


def test_hallucinated_ids_fall_back_to_local(monkeypatch):
    """Unknown dates/IDs are dropped — and replaced by local picks."""
    _patch_gemini(monkeypatch, '```json {"99.99.9999": "zzz", "16.09.2026": "nope"}```')
    _, orders = recommend_lunches(FOOD, "", "KEY", retries=0)
    assert orders == EXPECTED


def test_partial_gemini_answer_is_kept(monkeypatch):
    """A reply with at least one real pick is used as-is (no fallback)."""
    calls: list = []
    _patch_gemini(
        monkeypatch,
        'Rybka je super. ```json {"17.09.2026": "b&1&0"}```',
        calls,
    )
    _, orders = recommend_lunches(FOOD, "", "KEY", retries=0)
    assert orders == {"17.09.2026": "b&1&0"}
    assert len(calls) == 1  # accepted on the first attempt, no retry


def _sync_thread(monkeypatch):
    real = threading.Thread

    class SyncThread:
        def __init__(self, target=None, args=(), **kw):
            self._t = target
            self._a = tuple(args or ())

        def start(self):
            self._t(*self._a)

    monkeypatch.setattr(threading, "Thread", SyncThread)
    return real


def _ai_state(monkeypatch, cutoff_open):
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    state.data = {"strava_meals": {
        "16.09.2026": dict(FOOD["16.09.2026"]),
        "17.09.2026": dict(FOOD["17.09.2026"]),
    }}
    state.demo_mode = False
    monkeypatch.setattr(
        gemini_mod, "recommend_lunches",
        lambda *a, **k: ("", {"16.09.2026": "a&1&0", "17.09.2026": "b&1&0"}),
    )
    monkeypatch.setattr(
        state, "is_lunch_order_open",
        lambda day, now=None: cutoff_open(str(day)),
    )
    _sync_thread(monkeypatch)
    return state


def test_worker_reports_closed_days_separately(monkeypatch):
    from strakalari.flet_ui.strings import S

    state = _ai_state(monkeypatch, lambda day: day != "16.09.2026")
    assert state.start_ai_recommend(None) is True
    assert state.orders == {"17.09.2026": "b&1&0"}
    last_log = state.log_lines[-1]
    assert S("to_send") in last_log
    assert S("lunch_closed_count") in last_log
    assert S("skipped_reason") not in last_log  # vacation counter stays out


def test_worker_says_closed_when_everything_is_past_cutoff(monkeypatch):
    from strakalari.flet_ui.strings import S

    state = _ai_state(monkeypatch, lambda day: False)
    assert state.start_ai_recommend(None) is True
    assert state.orders == {}
    assert S("lunch_order_closed") in state.log_lines[-1]


def test_recommend_respects_skip_and_marks_pending(state, monkeypatch):
    """AI picks must skip vacation days and land in pending_orders."""
    import threading

    import strakalari.core.gemini as gemini_mod
    from strakalari.flet_ui.views.lunches import LunchView

    state.data = {
        "strava_meals": {
            "07.09.2026": {"m1": "Kureci", "m2": "Vepro"},
            "08.09.2026": {"m3": "Ryba", "m4": "Testoviny"},
        }
    }
    state.demo_mode = False
    state.cancelled_lunches = {"07.09.2026"}
    # recommend() needs a stored key before it runs (CI has no config.json).
    monkeypatch.setitem(state.config.data, "gemini_api_key", "AIza-test")
    # Cutoff-independent: this test covers skip-vs-stage logic, not deadlines.
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)

    monkeypatch.setattr(
        gemini_mod, "recommend_lunches",
        lambda *a, **k: ("", {"07.09.2026": "m1", "08.09.2026": "m3"}),
    )
    # Run the worker inline instead of on a background thread.
    class SyncThread:
        def __init__(self, target=None, args=(), **kw):
            self._target = target
            self._args = tuple(args or ())

        def start(self):
            self._target(*self._args)

    monkeypatch.setattr(threading, "Thread", SyncThread)

    class FakePage:
        def update(self):
            pass

    view = LunchView(state, FakePage())
    view.page = FakePage()
    import strakalari.flet_ui.views.lunches as lunches_mod

    monkeypatch.setattr(lunches_mod, "snack", lambda *a, **k: None)
    view.recommend()
    assert state.ai_running is False  # flag cleared when the run ends
    assert any("AI" in line or "K odeslání" in line for line in state.log_lines)
    assert "07.09.2026" not in state.orders  # planned skip owns the day
    assert state.orders.get("08.09.2026") == "m3"
    assert "08.09.2026" in state.pending_orders


def test_recommend_busy_guard_snacks_instead_of_rerunning(state, monkeypatch):
    from strakalari.flet_ui.views.lunches import LunchView

    state.ai_running = True
    calls = []
    import strakalari.flet_ui.views.lunches as lunches_mod

    monkeypatch.setattr(lunches_mod, "snack",
                        lambda *a, **k: calls.append(True))

    class FakePage:
        def update(self):
            pass

    LunchView(state, FakePage()).recommend()
    assert calls, "double-click while running must give feedback"


class TestGemini:
    def test_parse_json_block(self):
        text = '• Monday pick\n```json {"01.09.2026": "abc"} ```'
        clean, orders = parse_recommendation_response(text)
        assert orders == {"01.09.2026": "abc"}
        assert "Monday" in clean

    def test_local_fallback_picks_non_banned(self):
        food = {"01.09.2026": {"id1": "Kuřecí prsa", "id2": "Vepřová pečeně"}}
        html, orders = local_fallback_recommendation(food, "hodně bílkovin")
        assert orders.get("01.09.2026") == "id1"
        assert html


def test_validate_recommendation_drops_hallucinations():
    from strakalari.core.gemini import validate_recommendation

    food = {"07.09.2026": {"id1": "Meal one", "id2&A": "Deorder"}}
    got = validate_recommendation({"07.09.2026": "nope", "99.99.9999": "id1",
                                   "7.9.2026": "id1"}, food)
    assert got == {"07.09.2026": "id1"}  # bad id + bad day dropped, padding canonicalized
