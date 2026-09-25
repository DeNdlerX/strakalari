"""Strakalari.stravaOrderSelected never reports partial success."""
from strakalari.core.automation import Strakalari
from unittest.mock import MagicMock

DAY1 = "05.10.2099"
DAY2 = "06.10.2099"


class _Client:
    def __init__(self, order_ok, verified=None, click_on_order=True):
        self.foodDict = {DAY1: {"a&1&0": "A", "a&2&0": "B"},
                         DAY2: {"b&1&0": "C", "b&2&0": "D"}}
        self.orderedDict = {DAY1: "a&1&0", DAY2: "b&1&0"}
        self.clicks_made = 0
        self._order_ok = order_ok
        self._verified_ids = verified
        self._click_on_order = click_on_order
        self.restored = None
        self.saved = None

    def login(self):
        pass

    def fetch_data(self):
        pass

    def order(self, mid, all_ids=None):
        ok = self._order_ok.get(mid, False)
        if self._click_on_order and mid not in self.orderedDict.values():
            self.clicks_made += 1
        return ok

    def _verified(self, mid):
        return True if self._verified_ids is None else mid in self._verified_ids

    def _notice_suffix(self):
        return ""

    def _restore_original(self, failed, original):
        self.restored = [p["day"] for p in failed]

    def save_confirm(self, ids):
        self.saved = list(ids)
        return True


def _app(client):
    app = Strakalari.__new__(Strakalari)
    app.strava_enable = True
    app.strava_client = client
    app.cancel_requested = False
    app.strava_order_mode = "auto"
    app.config_data = {}
    app.logs = []
    app.writeLog = app.logs.append
    return app


def test_failed_day_without_clicks_is_not_success():
    # DAY1 already matches (no click), DAY2 never becomes clickable.
    client = _Client({"a&1&0": True}, click_on_order=False)
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&1&0", DAY2: "b&2&0"}) is False
    # DAY1 already held the pick: web truth, reported even though DAY2 failed.
    assert app.last_ordered_days == {DAY1}


def test_failed_run_reports_days_saved_by_immediate_frontend():
    # Current frontend (no save button): DAY1's click persisted at once,
    # so a failure on DAY2 must not hide that DAY1 really changed.
    client = _Client({"a&2&0": True})
    client._find_save_button = lambda timeout_ms=0: None
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}) is False
    assert client.restored == [DAY2]  # the failed day is still restored
    assert app.last_ordered_days == {DAY1}
    assert client.orderedDict[DAY1] == "a&2&0"


def test_failed_run_on_save_button_frontend_reports_nothing_clicked():
    # Legacy frontend: clicks are only saved by the (never pressed) save
    # button, so a clicked day did not change on the web.
    client = _Client({"a&2&0": True})
    client._find_save_button = lambda timeout_ms=0: object()
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}) is False
    assert client.restored == [DAY2]
    assert app.last_ordered_days == set()
    assert client.orderedDict[DAY1] == "a&1&0"


def test_all_failed_after_clicks_restores_originals():
    client = _Client({})
    app = _app(client)
    assert app.stravaOrderSelected({DAY2: "b&2&0"}) is False
    assert client.restored == [DAY2]
    assert client.saved is None


def test_lost_selection_fails_and_restores():
    client = _Client({"a&2&0": True, "b&2&0": True}, verified={"a&2&0"})
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}) is False
    assert client.restored == [DAY2]
    assert client.saved is None


def test_meal_not_on_menu_is_reported_but_others_placed():
    client = _Client({"a&2&0": True})
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "zzz&9&0"}) is False
    assert app.last_ordered_days == {DAY1}
    assert client.saved == ["a&2&0"]


def test_full_success_submits_and_records():
    client = _Client({"a&2&0": True, "b&2&0": True})
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}) is True
    assert client.saved == ["a&2&0", "b&2&0"]
    assert client.orderedDict == {DAY1: "a&2&0", DAY2: "b&2&0"}
    assert app.last_ordered_days == {DAY1, DAY2}


class TestDryRunMenuMiss:
    def _app(self, food):
        from strakalari.core.automation import Strakalari
        app = Strakalari.__new__(Strakalari)
        app.strava_enable = True
        app.cancel_requested = False
        app.strava_order_mode = "dry_run"
        app.writeLog = lambda m: None
        client = MagicMock()
        client.foodDict = dict(food)
        app.strava_client = client
        return app

    def test_menu_miss_returns_false(self):
        app = self._app({"20.09.2030": {"m1": "A"}})
        assert app.stravaOrderSelected({"20.09.2030": "nope&9&x"}) is False

    def test_menu_hit_returns_true(self):
        app = self._app({"20.09.2030": {"m1": "A"}})
        assert app.stravaOrderSelected({"20.09.2030": "m1"}) is True


class TestCutoffUnavailable:
    def test_ordering_skipped_without_cutoff(self, monkeypatch):
        from strakalari.core import school_presets
        from strakalari.core.automation import Strakalari
        monkeypatch.setattr(
            school_presets, "effective_calendar",
            lambda cfg: (_ for _ in ()).throw(RuntimeError("boom")))
        app = Strakalari.__new__(Strakalari)
        app.strava_enable = True
        app.cancel_requested = False
        app.config_data = {}
        app.writeLog = lambda m: None
        client = MagicMock()
        client.foodDict = {"20.09.2030": {"m1": "A"}}
        app.strava_client = client
        assert app.stravaOrderSelected({"20.09.2030": "m1"}) is False
        client.order.assert_not_called()


class _FakeStravaClient:
    def __init__(self, ok_days):
        self.ok_days = set(ok_days)
        self.foodDict = {}
        self.orderedDict = {}
        self.clicks_made = 0
        self.cancel_requested = False

    def login(self):
        pass

    def fetch_data(self):
        pass

    def order(self, meal_id, all_ids):
        ok = meal_id in self.ok_days
        if ok:
            self.clicks_made += 1
        return ok

    def save_confirm(self, verify_ids):
        return True


def test_partial_order_is_not_success():
    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.strava_enable = True
    app.cancel_requested = False
    app.strava_order_mode = "confirm"
    app.writeLog = lambda *a: None
    app.strava_client = _FakeStravaClient(ok_days={"m1"})
    app.strava_client.foodDict = {"d1": {"m1": "A"}, "d2": {"m2": "B"}}
    assert app.stravaOrderSelected({"d1": "m1", "d2": "m2"}) is False


def test_dry_run_selects_without_submitting():
    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.strava_enable = True
    app.cancel_requested = False
    app.strava_order_mode = "dry_run"
    app.writeLog = lambda *a: None

    class _FakeDryClient:
        foodDict = {"20.09.2030": {"m1": "A"}}
        orderedDict = {}
        clicks_made = 0

        def login(self):
            pass

        def fetch_data(self):
            pass

        def order(self, meal_id, all_ids=None):
            raise AssertionError("dry-run must never click (immediate-save frontend)")

        def save_confirm(self):
            raise AssertionError("dry-run must never hit save/submit")

    app.strava_client = _FakeDryClient()
    assert app.stravaOrderSelected({"20.09.2030": "m1"}) is True
    assert app.strava_client.clicks_made == 0
    assert app.strava_client.orderedDict == {}


class TestOrderSelectedSubmit:
    def _app(self, order_results):
        from strakalari.core.automation import Strakalari

        app = Strakalari.__new__(Strakalari)
        app.strava_enable = True
        app.cancel_requested = False
        app.strava_order_mode = "confirm"
        app.config_data = {}
        app.writeLog = lambda m: None
        client = MagicMock()
        client.foodDict = {"01.01.2030": {"m1": "A"}, "02.01.2030": {"m2": "B"}}
        client.orderedDict = {}
        client.clicks_made = 0
        client._verified.return_value = True
        results = list(order_results)

        def _order(meal_id, all_ids=None):
            client.clicks_made += 1
            return results.pop(0)

        client.order.side_effect = _order
        client.save_confirm.return_value = True
        app.strava_client = client
        return app, client

    def test_success_submits(self):
        app, client = self._app([True])
        assert app.stravaOrderSelected({"01.01.2030": "m1"}) is True
        client.save_confirm.assert_called_once()

    def test_failed_day_aborts_submit(self):
        app, client = self._app([True, False])
        assert app.stravaOrderSelected({"01.01.2030": "m1", "02.01.2030": "m2"}) is False
        client.save_confirm.assert_not_called()

    def test_closed_day_is_skipped(self):
        app, client = self._app([True])
        client.foodDict["01.01.2020"] = {"m0": "X"}
        assert app.stravaOrderSelected({"01.01.2020": "m0"}) is False
        client.save_confirm.assert_not_called()
