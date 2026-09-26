"""A cancelled refresh keeps what it already fetched."""

import pytest

from tests.test_strava_low_balance import _LowBalanceApp


# -- a cancelled refresh keeps what was fetched -----------------------------

def test_cancel_after_fetch_keeps_fetched_data():
    from strakalari.core.cache import load_data_cache
    from strakalari.core.refresh import run_refresh

    class _App(_LowBalanceApp):
        strava_order_mode = "confirm"

        def __init__(self):
            super().__init__()
            self.timetableData = {"1.9.2099": [{"subject": "M"}]}
            self.absencePercentages = {"M": 2.0}

    flags = {"n": 0}

    def _cancel():
        flags["n"] += 1
        return flags["n"] > 2  # after Bakaláři + Strava fetch

    cfg = {"bakalari_url": "u", "bakalari_username": "s", "strava_username": "s",
           "strava_canteen_id": "1", "use_strava": True}
    with pytest.raises(InterruptedError):
        run_refresh(_App(), cfg, is_cancelled=_cancel)
    cache = load_data_cache()
    assert cache["absence"] == {"M": 2.0}
    assert "strava_meals" in cache
