"""Lunch-order day keys are canonical in the UI state and the cache."""




# -- lunch-order day keys are canonical in the UI state ----------------------

def test_cached_orders_use_canonical_day_keys(state, monkeypatch):
    state.cancelled_lunches = {"04.09.2026"}
    state.orders = {}
    state.data = {"absence": {"M": 1.0}, "strava_ordered": {
        "4.9.2026": "t&1&0", "5.9.2026": "t&2&0"}}
    import strakalari.flet_ui.state as state_mod
    monkeypatch.setattr(state_mod, "load_data_cache", lambda: state.data)
    state.reload_cache()
    # The planned-skip day never resurrects a pick; the other day is canonical.
    assert state.orders == {"05.09.2026": "t&2&0"}
    assert state.web_orders == {"04.09.2026": "t&1&0", "05.09.2026": "t&2&0"}


def test_record_web_orders_drops_other_spellings(state, monkeypatch):
    import strakalari.core.cache as cache_mod

    saved = {}
    monkeypatch.setattr(cache_mod, "load_data_cache",
                        lambda: {"strava_ordered": {"4.9.2026": "old", "6.9.2026": "x"}})
    monkeypatch.setattr(cache_mod, "save_data_cache", lambda d: saved.update(d))
    state._record_web_orders({"04.09.2026": "new"})
    assert saved["strava_ordered"] == {"6.9.2026": "x", "04.09.2026": "new"}


def test_store_ordered_replaces_other_spelling():
    from strakalari.core.automation import _store_ordered

    ordered = {"4.9.2026": "old", "5.9.2026": "keep"}
    _store_ordered(ordered, "04.09.2026", "new")
    assert ordered == {"5.9.2026": "keep", "04.09.2026": "new"}
