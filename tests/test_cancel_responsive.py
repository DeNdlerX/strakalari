"""Cancelling a refresh is instant (and stays correct on slow links).

Regression tests for "cancelling isn't instant": every blocking Playwright
wait is chunked through ``strakalari.core.cancel``, so Zrušit preempts the
worker inside the running wait instead of after the full 15-60 s ceiling.
"""

import threading
import time

import pytest


class _Timeout(Exception):
    pass


class _SlowLocator:
    """Never becomes visible; honors the per-slice timeout like Playwright."""

    def __init__(self):
        self.calls = []

    @property
    def first(self):
        return self

    def wait_for(self, state=None, timeout=None):
        self.calls.append(timeout)
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout("still not visible")

    def click(self, timeout=None, **kwargs):
        self.calls.append(("click", timeout))
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout("not actionable")


class _SlowPage:
    def __init__(self):
        self.goto_calls = []
        self.fn_calls = []
        self.loc = _SlowLocator()

    def locator(self, selector):
        return self.loc

    def get_by_text(self, *args, **kwargs):
        return self.loc

    def goto(self, url, timeout=None, wait_until=None):
        self.goto_calls.append(timeout)
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout(f"Timeout {timeout}ms exceeded.")

    def wait_for_function(self, js, timeout=None):
        self.fn_calls.append(timeout)
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout("condition never true")

    def wait_for_timeout(self, ms):
        time.sleep(ms / 1000.0)

    def content(self):
        return "<html></html>"


def test_wait_visible_retries_until_budget_without_cancel():
    from strakalari.core.cancel import wait_visible

    loc = _SlowLocator()
    started = time.monotonic()
    with pytest.raises(_Timeout):
        wait_visible(loc, 1000, lambda: False)
    elapsed = time.monotonic() - started
    # Full ~1 s budget consumed across 250 ms slices (not one short wait).
    assert elapsed >= 0.9
    assert len(loc.calls) >= 3


def test_wait_visible_aborts_immediately_when_already_cancelled():
    from strakalari.core.cancel import wait_visible

    loc = _SlowLocator()
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        wait_visible(loc, 30000, lambda: True)
    assert time.monotonic() - started < 1.0
    assert loc.calls == []


def test_wait_visible_aborts_mid_wait():
    from strakalari.core.cancel import wait_visible

    flag = {"cancel": False}
    loc = _SlowLocator()

    def _cancel_soon():
        time.sleep(0.3)
        flag["cancel"] = True

    threading.Thread(target=_cancel_soon, daemon=True).start()
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        wait_visible(loc, 30000, lambda: flag["cancel"])
    elapsed = time.monotonic() - started
    # Cancel lands within ~one slice of the flag flip — not after 30 s.
    assert elapsed < 5.0


def test_sleep_aborts_mid_sleep():
    from strakalari.core.cancel import sleep

    flag = {"cancel": False}

    def _cancel_soon():
        time.sleep(0.2)
        flag["cancel"] = True

    threading.Thread(target=_cancel_soon, daemon=True).start()
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        sleep(_SlowPage(), None, 30, lambda: flag["cancel"])
    assert time.monotonic() - started < 5.0


def test_goto_issues_once_then_waits_without_renavigating():
    from strakalari.core import cancel as cancel_mod
    from strakalari.core.cancel import wrap_page

    raw = _SlowPage()
    page = wrap_page(raw, lambda: False)
    with pytest.raises(_Timeout) as exc_info:
        page.goto("https://example.com", timeout=11000,
                  wait_until="domcontentloaded")
    # ONE navigation: re-issuing goto would restart the load from zero,
    # so on a slow link the remaining budget waits for that same load
    # (passive load-state probes) instead of refreshing it.
    assert raw.goto_calls == [cancel_mod.GOTO_SLICE_MS]
    assert raw.fn_calls  # the rest of the budget went into waiting, not reloading
    assert "budget 11000ms" in str(exc_info.value)


def test_goto_stops_on_cancel_before_navigating():
    from strakalari.core.cancel import wrap_page

    page2 = wrap_page(_SlowPage(), lambda: True)
    with pytest.raises(InterruptedError):
        page2.goto("https://example.com", timeout=60000,
                   wait_until="domcontentloaded")
    assert page2._page.goto_calls == []


def test_goto_cancel_during_slow_navigation():
    from strakalari.core.cancel import wrap_page

    flag = {"cancel": False}
    raw = _SlowPage()
    page = wrap_page(raw, lambda: flag["cancel"])

    def _cancel_soon():
        time.sleep(0.3)
        flag["cancel"] = True

    threading.Thread(target=_cancel_soon, daemon=True).start()
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        page.goto("https://example.com", timeout=2500,
                  wait_until="domcontentloaded")
    assert time.monotonic() - started < 5.0


class _RefusedPage:
    """Setup dies (DNS/refused — nothing loading); the retry then succeeds."""

    def __init__(self, failures=1):
        self.failures = failures
        self.goto_calls = []

    def locator(self, selector):
        return _SlowLocator()

    def get_by_text(self, *args, **kwargs):
        return _SlowLocator()

    def goto(self, url, timeout=None, wait_until=None):
        self.goto_calls.append(timeout)
        if len(self.goto_calls) <= self.failures:
            raise RuntimeError("net::ERR_CONNECTION_REFUSED")
        return "loaded"

    def wait_for_function(self, js, timeout=None):
        raise _Timeout("condition never true")

    def wait_for_timeout(self, ms):
        time.sleep(ms / 1000.0)


def test_goto_hard_error_retries_once_then_raises():
    from strakalari.core.cancel import wrap_page

    raw = _RefusedPage(failures=1)
    page = wrap_page(raw, lambda: False)
    assert page.goto("https://example.com", timeout=5000) == "loaded"
    assert len(raw.goto_calls) == 2

    raw2 = _RefusedPage(failures=5)
    page2 = wrap_page(raw2, lambda: False)
    with pytest.raises(RuntimeError):
        page2.goto("https://example.com", timeout=5000)
    assert len(raw2.goto_calls) == 2


def test_wrap_page_leaves_mocks_untouched():
    from unittest.mock import MagicMock

    from strakalari.core.cancel import _Page, wrap_page

    mock_page = MagicMock()
    assert wrap_page(mock_page, lambda: False) is mock_page
    assert wrap_page(None, lambda: False) is None
    wrapped = wrap_page(_SlowPage(), lambda: False)
    assert isinstance(wrapped, _Page)
    assert wrap_page(wrapped, lambda: False) is wrapped


def test_wrapped_page_wait_for_and_click_cancel():
    from strakalari.core.cancel import wrap_page

    raw = _SlowPage()
    page = wrap_page(raw, lambda: True)
    with pytest.raises(InterruptedError):
        page.locator(".ico32-modul-vyuka").first.wait_for(
            state="visible", timeout=30000)
    with pytest.raises(InterruptedError):
        page.locator(".ico32-modul-vyuka").first.click(timeout=30000)


def test_bakalari_client_sleep_honors_live_callback():
    from strakalari.core.bakalari_client import BakalariClient

    state = {"cancel": False}
    bm = type("BM", (), {"page": _SlowPage()})()
    client = BakalariClient(bm, {}, logger=None)
    client.cancel_callback = lambda: state["cancel"]

    def _cancel_soon():
        time.sleep(0.2)
        state["cancel"] = True

    threading.Thread(target=_cancel_soon, daemon=True).start()
    started = time.monotonic()
    with pytest.raises(InterruptedError):
        client._sleep_s(30)
    assert time.monotonic() - started < 5.0


def test_strava_client_forwards_cancel_into_fetch(monkeypatch):
    from strakalari.core.automation import Strakalari

    seen = {}

    class _BM:
        page = None

    app = Strakalari.__new__(Strakalari)
    app.config_data = {"use_strava": True}
    app.cancel_requested = True
    app.cancel_callback = lambda: True

    class _Client:
        cancel_requested = False
        cancel_callback = None

        def fetch_data(self):
            seen["flag"] = self.cancel_requested
            cb = self.cancel_callback
            seen["callback"] = bool(cb() if callable(cb) else False)
            # The live predicate must abort the fetch promptly.
            from strakalari.core.cancel import raise_if_cancelled

            raise_if_cancelled(
                lambda: self.cancel_requested
                or (bool(self.cancel_callback()) if callable(self.cancel_callback) else False)
            )

    app.strava_client = _Client()
    app.strava_enable = True
    with pytest.raises(InterruptedError):
        app.fetchStravaData()
    assert seen == {"flag": True, "callback": True}


def test_cancel_refresh_gives_instant_feedback(monkeypatch):
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    monkeypatch.setattr(state, "save", lambda updates: updates)
    state.refresh_running = True
    state.current_step = "Stahuji data z Bakalářů…"
    state.cancel_refresh()
    assert state.cancel_requested is True
    # The spinner text flips to the cancelling state right away.
    assert state.current_step != "Stahuji data z Bakalářů…"
    assert state.log_lines and "Rušení" in state.log_lines[-1]


def test_cancel_refresh_noop_when_idle(monkeypatch):
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    monkeypatch.setattr(state, "save", lambda updates: updates)
    state.cancel_refresh()
    assert state.cancel_requested is False
    assert state.log_lines == []


class TestSingleAttemptClicks:
    def test_force_click_single_full_budget_attempt(self):
        from strakalari.core.cancel import _Locator
        seen = []

        class _Loc:
            def click(self, timeout=None, **kw):
                seen.append(timeout)
                raise TimeoutError("Timeout")

        loc = _Locator(_Loc(), lambda: False)
        with pytest.raises(TimeoutError):
            loc.click(timeout=5000, force=True)
        assert seen == [5000]

    def test_cancel_aborts_before_once_click(self):
        from strakalari.core.cancel import _Locator

        clicks = []

        class _Loc:
            def wait_for(self, state=None, timeout=None):
                raise TimeoutError("Timeout")

            def click(self, timeout=None, **kw):
                clicks.append(timeout)

        calls = {"n": 0}

        def _pred():
            calls["n"] += 1
            return calls["n"] >= 3

        loc = _Locator(_Loc(), _pred)
        with pytest.raises(InterruptedError):
            loc.click(timeout=60000, once=True)
        assert clicks == []

    def test_docstring_matches_goto_slice(self):
        import strakalari.core.cancel as cancel_mod
        assert "10 s" in (cancel_mod.__doc__ or "")


def test_core_log_never_reaches_the_status_bar(monkeypatch):
    """English core diagnostics go to the activity log, not the status bar."""
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    state._worker_log("Stahuji data z Bakalářů…")
    state._core_log("Stable view opened (testid:timetable-permanent-link).")
    assert state.current_step == "Stahuji data z Bakalářů…"
    assert "Stable view opened" in state.log_lines[-1]


def test_flet_locale_follows_app_language():
    """Flutter's own texts (dialogs, pickers) must not follow the OS locale."""
    import flet as ft

    from strakalari.core import i18n
    from strakalari.flet_ui.app import _apply_locale

    page = type("Page", (), {"locale_configuration": None})()
    try:
        i18n.set_language("cs")
        _apply_locale(page)
        assert page.locale_configuration.current_locale == ft.Locale("cs", "CZ")
        i18n.set_language("en")
        _apply_locale(page)
        assert page.locale_configuration.current_locale == ft.Locale("en", "US")
    finally:
        i18n.set_language("cs")
