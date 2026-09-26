"""Strava low balance (Warning [5005]): detection, ordering stops, cancellations still run, one notice a day."""
from datetime import date, timedelta

import pytest

from strakalari.core.automation import Strakalari

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


# -- low balance (Strava Warning [5005]) --------------------------------------

LOW_BALANCE_TEXT = ("Warning [5005]\nYou do not have sufficient account balance to make "
                    "these changes. The canteen has an ordering limit E Account check.")


def test_low_balance_notice_detection():
    from strakalari.core.strava_client import _is_page_chrome_notice, is_low_balance_notice

    assert is_low_balance_notice(LOW_BALANCE_TEXT)
    assert is_low_balance_notice("Upozornění [5005] Nemáte dostatečný zůstatek na účtu.")
    assert not is_low_balance_notice("Máte 1 nepřečtených zpráv Otevřít zprávy")
    assert not is_low_balance_notice("")
    assert _is_page_chrome_notice("Máte 1 nepřečtených zpráv\nOtevřít zprávy")


class _Loc:
    def __init__(self, text="", visible=True):
        self._text, self._visible = text, visible
        self.first = self

    def inner_text(self):
        return self._text

    def is_visible(self):
        return self._visible

    def all(self):
        return [self] if self._text else []


class _NoticePage:
    """Body holds the inbox badge and (optionally) the coded warning."""

    def __init__(self, body, alerts=()):
        self._body, self._alerts = body, list(alerts)

    def locator(self, sel):
        if sel == "body":
            return _Loc(self._body)
        if sel == "[role='alert']" and self._alerts:
            loc = _Loc(self._alerts[0])
            loc.all = lambda: [_Loc(t) for t in self._alerts]
            return loc
        return _Loc("")


def _client_with(page):
    from strakalari.core.strava_client import StravaClient

    client = StravaClient.__new__(StravaClient)
    client.page = page
    return client


def test_notice_prefers_coded_warning_over_inbox_badge():
    page = _NoticePage("Máte 1 nepřečtených zpráv\nOtevřít zprávy\n" + LOW_BALANCE_TEXT,
                       alerts=["Máte 1 nepřečtených zpráv\nOtevřít zprávy"])
    notice = _client_with(page)._page_notice_text()
    assert notice.startswith("Warning [5005]")
    assert "sufficient account balance" in notice


def test_notice_ignores_inbox_badge_alone():
    page = _NoticePage("Máte 1 nepřečtených zpráv\nOtevřít zprávy",
                       alerts=["Máte 1 nepřečtených zpráv\nOtevřít zprávy"])
    assert _client_with(page)._page_notice_text() == ""


class _BrokeClient:
    """Orders the first meal, then Strava refuses everything for lack of money."""

    def __init__(self):
        self.foodDict = {d: {k: v for k, v in m.items()} for d, m in MENU.items()}
        self.orderedDict = {}
        self.clicks_made = 0
        self.insufficient_balance = False
        self.ordered = []

    def login(self):
        pass

    def fetch_data(self):
        pass

    def order(self, mid, all_ids=None):
        if "&-1&" in mid:
            self.ordered.append(mid)
            return True
        if self.ordered and not self.insufficient_balance:
            self.insufficient_balance = True
            return False
        if self.insufficient_balance:
            raise AssertionError("no meal order may be tried after a low-balance refusal")
        self.clicks_made += 1
        self.ordered.append(mid)
        return True

    def _verified(self, mid):
        return mid in self.ordered

    def _notice_suffix(self):
        return ""

    def _find_save_button(self, timeout_ms=500):
        return None

    def _restore_original(self, failed, original):
        raise AssertionError("a refused (unchanged) day needs no restore")

    def save_confirm(self, ids):
        return True


def _app(client, monkeypatch):
    import strakalari.core.school_presets as sp

    monkeypatch.setattr(sp, "resolve_lunch_cutoff", lambda cfg: "12:00")
    app = Strakalari.__new__(Strakalari)
    app.strava_enable = True
    app.strava_client = client
    app.cancel_requested = False
    app.cancel_callback = None
    app.strava_order_mode = "auto"
    app.config_data = {}
    app.logs = []
    app.write_log = app.logs.append
    return app


def test_ordering_stops_at_low_balance(monkeypatch):
    client = _BrokeClient()
    app = _app(client, monkeypatch)
    ok = app.strava_order_selected({DAY1: "a&1&0", DAY2: "b&1&0", DAY3: "c&1&0"})
    assert ok is False
    assert app.last_order_low_balance is True
    assert app.last_unfunded_days == [DAY2, DAY3]
    assert app.last_ordered_days == {DAY1}


def test_cancellations_go_first_and_still_work_when_broke(monkeypatch):
    client = _BrokeClient()
    app = _app(client, monkeypatch)
    app.strava_order_selected({DAY1: "a&1&0", DAY2: "b&-1&0"})
    assert client.ordered[0] == "b&-1&0"  # the refund-giving cancel went first


class _LowBalanceApp:
    strava_enable = True
    excuse_mode = "confirm"
    strava_order_mode = "auto"

    def __init__(self):
        from types import SimpleNamespace

        self.timetableData = {}
        self.absencePercentages = {}
        self.grades = {}
        self.stableBaseline = {}
        self.bakalari_client = None
        self.strava_client = SimpleNamespace(strava_blacklist_json=[], blacklist_broken=False,
                                             orderedDict={})
        self.foodDict = {}
        self.orderedDict = {}
        self.last_ordered_days = set()
        self.last_order_low_balance = False
        self.last_unfunded_days = []

    def fetch_bakalari_data(self):
        pass

    def sync_web_excuses_to_history(self):
        pass

    def fetch_strava_data(self):
        self.foodDict = dict(MENU)

    def strava_order_selected(self, orders, source="manual"):
        days = sorted(orders)
        self.last_ordered_days = {days[0]}
        self.strava_client.orderedDict[days[0]] = orders[days[0]]
        self.last_order_low_balance = True
        self.last_unfunded_days = days[1:]
        return False


def test_refresh_reports_low_balance_as_its_own_case(always_open):
    from strakalari.core.cache import load_data_cache
    from strakalari.core.refresh import LowBalanceError, run_refresh

    cfg = {"strava_username": "s", "strava_canteen_id": "1", "use_strava": True}
    result = run_refresh(_LowBalanceApp(), cfg, scope="strava")
    assert result.low_balance is True
    assert result.only_low_balance is True
    assert isinstance(result.automation_errors[0][1], LowBalanceError)
    cache = load_data_cache()
    assert cache["strava_low_balance"]["days"] == sorted([DAY2, DAY3])
    # The day that went through counts as handled; the unpaid ones retry.
    assert DAY1 in cache["auto_lunch_handled"]
    assert DAY2 not in cache["auto_lunch_handled"]


def test_low_balance_notice_is_claimed_once_a_day():
    from strakalari.core.refresh import claim_low_balance_notice

    today = date(2026, 9, 25)
    assert claim_low_balance_notice(today) is True
    assert claim_low_balance_notice(today) is False
    assert claim_low_balance_notice(today + timedelta(days=1)) is True


def test_ui_low_balance_is_a_warning_not_an_error(state, monkeypatch):
    notified = []
    monkeypatch.setattr(state, "_notify", lambda event, body: notified.append(event))
    state._warn_low_balance("no money")
    state._warn_low_balance("no money")
    assert notified == ["lunch_skipped"]  # once a day
