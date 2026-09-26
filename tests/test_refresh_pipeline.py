"""The shared refresh pipeline (core.refresh.run_refresh).

Both the UI and the tray run this, so the tray's background refresh
can no longer drift from the UI's (planned skips, web-excuse sync,
cache preservation).
"""
import pytest

from strakalari.core.cache import load_data_cache, save_data_cache
from strakalari.core.refresh import run_refresh

FUTURE_DAY = "05.10.2099"
OTHER_DAY = "06.10.2099"

CONFIG = {
    "bakalari_url": "https://bakalari.test",
    "bakalari_username": "student",
    "strava_username": "student",
    "strava_canteen_id": "1234",
    "use_strava": True,
    "planned_skips": [{"start_date": "2099-10-05", "end_date": "2099-10-05"}],
}


@pytest.fixture(autouse=True)
def _tmp_user_dir(monkeypatch, tmp_path):
    import strakalari.core.helpers as helpers_mod

    monkeypatch.setattr(helpers_mod, "get_user_data_dir", lambda: str(tmp_path))


class _StravaClient:
    def __init__(self):
        self.strava_blacklist_json = []
        self.blacklist_broken = False
        self.orderedDict = {}


class FakeApp:
    def __init__(self, calls, strava_error=None, menu=None, excuse_mode="confirm",
                 order_mode="confirm"):
        self.calls = calls
        self.strava_enable = True
        self.excuse_mode = excuse_mode
        self.strava_order_mode = order_mode
        self.timetableData = {"1.9.2099": [{"subject": "M"}]}
        self.absencePercentages = {"M": 2.0}
        self.grades = {}
        self.stableBaseline = {}
        self.absenceDetails = {}
        self.subjectDirectory = {}
        self.bakalari_client = None
        self.strava_client = _StravaClient()
        self.foodDict = {}
        self.orderedDict = {}
        self._strava_error = strava_error
        self._menu = menu if menu is not None else {
            FUTURE_DAY: {"t1&1&0": "Kuřecí řízek", "t1&-1&0": "x"},
            OTHER_DAY: {"t2&1&0": "Guláš", "t2&-1&0": "x"},
        }

    def fetch_bakalari_data(self):
        self.calls.append("bakalari")

    def sync_web_excuses_to_history(self):
        self.calls.append("sync")

    def excuse_pending(self):
        self.calls.append("excuse")
        return 1

    def fetch_strava_data(self):
        self.calls.append("strava")
        if self._strava_error:
            raise self._strava_error
        self.foodDict = dict(self._menu)

    def strava_order_selected(self, orders, source="manual"):
        self.calls.append(("order", dict(orders)))
        self.strava_client.orderedDict.update(orders)
        return True


def test_web_excuses_sync_before_auto_excuse():
    calls = []
    run_refresh(FakeApp(calls, excuse_mode="auto"), CONFIG)
    assert calls.index("sync") < calls.index("excuse")


def test_planned_skip_day_never_auto_ordered():
    calls = []
    run_refresh(FakeApp(calls, order_mode="auto"), CONFIG)
    orders = [c[1] for c in calls if isinstance(c, tuple) and c[0] == "order"]
    assert orders and FUTURE_DAY not in orders[0]
    assert OTHER_DAY in orders[0]


def test_broken_blacklist_orders_nothing():
    calls = []
    app = FakeApp(calls, order_mode="auto")
    app.strava_client.blacklist_broken = True
    run_refresh(app, CONFIG)
    assert not [c for c in calls if isinstance(c, tuple)]


def test_strava_failure_keeps_bakalari_data_and_reports():
    save_data_cache({"strava_meals": {"1.1.2099": {"a&1&0": "old"}},
                     "last_updated": "01.01.2000 00:00:00"})
    result = run_refresh(FakeApp([], strava_error=RuntimeError("login failed")), CONFIG)
    assert not result.ok
    cache = load_data_cache()
    assert cache["absence"] == {"M": 2.0}
    assert cache["strava_meals"] == {"1.1.2099": {"a&1&0": "old"}}
    # A failed full refresh never makes the cache look fresh.
    assert cache["last_updated"] == "01.01.2000 00:00:00"


def test_empty_menu_keeps_cached_menu():
    save_data_cache({"strava_meals": {"1.1.2099": {"a&1&0": "old"}}})
    result = run_refresh(FakeApp([], menu={}), CONFIG)
    assert result.ok
    assert load_data_cache()["strava_meals"] == {"1.1.2099": {"a&1&0": "old"}}


def test_unavailable_extras_survive_refresh():
    save_data_cache({
        "absence_details": {"M": {"total_hours": 10}},
        "subject_directory": {"M": "Novák"},
        "substitutions": [{"day": "1.9.2099"}],
    })
    run_refresh(FakeApp([]), CONFIG)
    cache = load_data_cache()
    assert cache["absence_details"] == {"M": {"total_hours": 10}}
    assert cache["subject_directory"] == {"M": "Novák"}
    assert cache["substitutions"] == [{"day": "1.9.2099"}]


def test_failed_absence_scrape_keeps_last_good_absence():
    from types import SimpleNamespace

    save_data_cache({"absence": {"M": 7.0}})
    app = FakeApp([])
    app.absencePercentages = {}
    app.bakalari_client = SimpleNamespace(absence_error="grid did not load",
                                          grades_error="", substitutions=None)
    run_refresh(app, CONFIG)
    assert load_data_cache()["absence"] == {"M": 7.0}


def test_gemini_fallback_is_not_a_gemini_run(monkeypatch):
    from strakalari.core import gemini, lunch_auto

    monkeypatch.setattr(gemini.urllib.request, "urlopen",
                        lambda *a, **k: (_ for _ in ()).throw(OSError("offline")))
    monkeypatch.setattr(gemini.time, "sleep", lambda s: None)
    cfg = dict(CONFIG, gemini_auto_enabled=True, gemini_api_key="k",
               gemini_api_key_encrypted=False)
    orders, used = lunch_auto.plan_auto_orders(
        {OTHER_DAY: {"t2&1&0": "Guláš"}}, cfg)
    assert used is False
    assert orders == {OTHER_DAY: "t2&1&0"}
