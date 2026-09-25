"""Regression tests for the round-5 review fixes and Strava low-balance handling."""
from datetime import date, datetime, timedelta

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


# -- 1. auto mode never overrides the user ------------------------------------

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


# -- 2. planned day off keeps its cancellation after a restart ------------------

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


# -- 3. substitution feed never invents unscraped days ---------------------------

def test_feed_does_not_create_days():
    from strakalari.core.schedule import apply_substitution_feed

    timetable = {"22.09.2026": [{"subject": "M", "teacher": "X",
                                 "time": "1 (8:00 - 8:45)"}]}
    feed = [{"day": "1.10.2026", "period": 3, "badge": "O", "time": "10:00 - 10:45",
             "subject_short": "Ch", "description": "Odpadá"}]
    assert apply_substitution_feed(timetable, feed) == 0
    assert list(timetable) == ["22.09.2026"]


# -- 4. sent-excuse parser stays inside the header ------------------------------

def test_sent_excuse_hours_must_follow_their_date():
    from strakalari.core.extractors.bakalari import extract_sent_excuses

    html = ('<div data-testid="komens-message-detail-header">Od: 7.9.2026<br>'
            'Do: 9.9.2026</div><div>pozdní příchod (1. hod.). Do: 12.9.2026 (3. hod.)</div>')
    assert extract_sent_excuses(html) == [
        {"type": "pure days", "starting_day": "07.09.2026", "ending_day": "09.09.2026"}]


def test_sent_excuse_accepts_spaced_dates():
    from strakalari.core.extractors.bakalari import extract_sent_excuses

    html = '<div data-testid="komens-message-detail-header">Od: 7. 9. 2026 Do: 9. 9. 2026</div>'
    assert extract_sent_excuses(html)[0]["ending_day"] == "09.09.2026"


# -- 5. tray language -----------------------------------------------------------

def test_tray_uses_configured_language(monkeypatch, tmp_path):
    import strakalari.flet_ui.tray as tray_mod
    from strakalari.core import i18n

    monkeypatch.setattr(i18n, "_current_lang", "cs")
    tray_mod._apply_language({"language": "en"})
    try:
        assert i18n.get_language() == "en"
    finally:
        i18n.set_language("cs")


# -- 6. "Excuse day" only claims a whole day when the whole day was missed ------

def _day_state(state, lessons, tasks):
    state.demo_mode = False
    state.data = {"timetable": {"18.09.2026": lessons}}
    state.excuse_tasks = lambda: tasks
    return state


def _lesson(period, subject, absent=True):
    return {"subject": subject, "teacher": "T", "time": f"{period} (8:00 - 8:45)",
            "absenceType": "Absent" if absent else "NoAbsent"}


def _task(period, subject, kind="short"):
    return {"key": f"2026-09-18|{period}|{subject}", "kind": kind, "label": subject,
            "date": "2026-09-18", "period": period}


def test_fully_absent_day_is_one_whole_day_excuse(state):
    st = _day_state(state, [_lesson(1, "M"), _lesson(2, "F")],
                    [_task(1, "M"), _task(2, "F")])
    assert st.day_fully_absent("2026-09-18") is True
    assert st.day_excuse_plan("2026-09-18") == [
        {"type": "pure days", "starting_day": "18.09.2026", "ending_day": "18.09.2026"}]


def test_partial_day_becomes_lesson_ranges(state):
    st = _day_state(state,
                    [_lesson(1, "M"), _lesson(2, "F"), _lesson(3, "Ch", absent=False),
                     _lesson(4, "D"), _lesson(5, "Z")],
                    [_task(1, "M", kind="late"), _task(2, "F"), _task(4, "D"), _task(5, "Z")])
    assert st.day_fully_absent("2026-09-18") is False
    plan = st.day_excuse_plan("2026-09-18")
    assert {"type": "income", "starting_day": "18.09.2026", "ending_day": "18.09.2026",
            "starting_lesson": 1, "ending_lesson": 1} in plan
    ranges = [(p["starting_lesson"], p["ending_lesson"]) for p in plan
              if p["type"] == "days and hours"]
    assert sorted(ranges) == [(2, 2), (4, 5)]


# -- 8. marks with minus grades count ------------------------------------------

def test_minus_grades_count_in_average():
    from strakalari.core import grades as gr

    assert gr.parse_raw("1-").value == 1.5
    assert gr.parse_raw("2+").value == 2.0
    assert gr.parse_raw("N") is None
    # "5-" can not be worse than the worst grade.
    assert gr.parse_raw("5-").value == 5.0
    assert gr.summarize("M", [{"Grade": "1"}, {"Grade": "2-"}]).average == pytest.approx(1.75)


# -- 9. Send only transmits staged picks ------------------------------------------

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

        def stravaOrderSelected(self, payload, source="manual"):
            calls.append(dict(payload))
            return True

        def close(self):
            pass

    import strakalari.core.automation as auto_mod

    monkeypatch.setattr(auto_mod, "Strakalari", _App)
    assert state.submit_orders() is True
    captured["t"]()
    assert calls == [{DAY2: "b&2&0"}]


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
    app.writeLog = app.logs.append
    return app


def test_ordering_stops_at_low_balance(monkeypatch):
    client = _BrokeClient()
    app = _app(client, monkeypatch)
    ok = app.stravaOrderSelected({DAY1: "a&1&0", DAY2: "b&1&0", DAY3: "c&1&0"})
    assert ok is False
    assert app.last_order_low_balance is True
    assert app.last_unfunded_days == [DAY2, DAY3]
    assert app.last_ordered_days == {DAY1}


def test_cancellations_go_first_and_still_work_when_broke(monkeypatch):
    client = _BrokeClient()
    app = _app(client, monkeypatch)
    app.stravaOrderSelected({DAY1: "a&1&0", DAY2: "b&-1&0"})
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

    def fetchBakalariData(self):
        pass

    def sync_web_excuses_to_history(self):
        pass

    def fetchStravaData(self):
        self.foodDict = dict(MENU)

    def stravaOrderSelected(self, orders, source="manual"):
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


# -- 12. a cancelled refresh keeps what was fetched -----------------------------

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


# -- 13. lunch deadlines see days off after the closure --------------------------

def test_unclipped_calendar_keeps_user_days_after_closure():
    from strakalari.core.school_presets import effective_calendar

    cfg = {"sem2_close": "26.04.2027", "user_free_days": ["14.05.2027"]}
    assert date(2027, 5, 14) not in effective_calendar(cfg)[0]
    assert date(2027, 5, 14) in effective_calendar(cfg, clip=False)[0]


# -- misc -------------------------------------------------------------------

def test_forget_key_removes_file_key(tmp_path):
    from strakalari.core.secret_store import KEY_FILE, forget_key, get_key

    get_key(str(tmp_path))
    assert (tmp_path / KEY_FILE).exists()
    assert forget_key(str(tmp_path)) is True
    assert not (tmp_path / KEY_FILE).exists()


def test_cache_label_follows_language():
    from strakalari.core import i18n
    from strakalari.core.cache import describe_cache

    stamp = (datetime.now() - timedelta(hours=3)).strftime("%d.%m.%Y %H:%M:%S")
    i18n.set_language("en")
    try:
        assert "h ago" in describe_cache({"last_updated": stamp}, 24)
    finally:
        i18n.set_language("cs")
    assert "před" in describe_cache({"last_updated": stamp}, 24)


def test_default_blacklist_template_is_empty():
    import json
    import os

    from strakalari.core.helpers import PROJECT_ROOT

    with open(os.path.join(PROJECT_ROOT, "strava_blacklist.example.json"), encoding="utf-8") as f:
        assert json.load(f) == []


def test_our_flet_view_attribution(tmp_path):
    from strakalari.flet_ui.single_instance import _is_our_flet_view

    ours = tmp_path / "assets"
    ours.mkdir()
    for name in ("tray-icon.svg", "tray-icon.png"):
        (ours / name).write_text("x")
    other = tmp_path / "other"
    other.mkdir()
    assert _is_our_flet_view(f'"flet.exe" http://x pid "{ours}"')
    assert not _is_our_flet_view(f'"flet.exe" http://x pid "{other}"')
    assert _is_our_flet_view(r'flet.exe http://x pid C:\Programs\Strakalari\assets')
