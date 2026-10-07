"""Cancelling a refresh is instant and reaches the clients.

The clients check the cancel flag (and the live predicate) before every
request, so Zrušit stops the run as soon as the request in flight returns.
"""

import pytest


def test_strava_client_forwards_cancel_into_fetch(monkeypatch):
    from strakalari.core.automation import Strakalari

    seen = {}

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
        app.fetch_strava_data()
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
