"""First-run wizard: gating, per-step saves, headless build.

Config writes are stubbed — these tests never touch the real config.
"""

import pytest

from strakalari.flet_ui.state import AppState
from strakalari.flet_ui.views import wizard as wiz


@pytest.fixture()
def state(monkeypatch):
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = AppState()
    # Blank credentials: AppState() loads the real ./config.json otherwise.
    app_state.config.data.update({
        "bakalari_url": "", "bakalari_username": "", "bakalari_password": "",
        "bakalari_password_encrypted": False,
        "strava_username": "", "strava_password": "",
        "strava_password_encrypted": False, "strava_canteen_id": "",
        "gemini_api_key": "", "gemini_api_key_encrypted": False,
    })
    monkeypatch.setattr(app_state.config, "save", lambda: None)
    return app_state


def test_needs_setup_fresh_and_dismiss(state):
    assert state.needs_setup() is True
    state.dismiss_wizard()
    assert state.needs_setup() is False


def test_needs_setup_false_with_bakalari(state):
    state.config.data.update({
        "bakalari_url": "https://skola.bakalari.cz",
        "bakalari_username": "novak",
        "bakalari_password": "x",
    })
    assert state.needs_setup() is False


def test_bakalari_step_validation(state):
    assert wiz._save_bakalari(state) is False
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    assert wiz._save_bakalari(state) is False  # no password yet
    state.set_draft("wiz:bakalari_password", "secret")
    assert wiz._save_bakalari(state) is True
    assert state.config.data["bakalari_username"] == "novak"
    assert state.needs_setup() is False


def test_strava_disabled_skips_credentials(state):
    state.set_draft("wiz:strava_enabled", "")
    assert wiz._save_strava(state) is True
    assert state.config.data["use_strava"] is False


def test_strava_enabled_requires_fields(state):
    state.set_draft("wiz:strava_enabled", "1")
    assert wiz._save_strava(state) is False
    state.set_draft("wiz:strava_username", "jidelna")
    state.set_draft("wiz:strava_password", "pw")
    state.set_draft("wiz:strava_canteen_id", "123")
    assert wiz._save_strava(state) is True
    assert state.config.data["use_strava"] is True


def test_ai_optional(state):
    state.set_draft("wiz:ai_enabled", "")
    assert wiz._save_ai(state) is True
    state.set_draft("wiz:ai_enabled", "1")
    assert wiz._save_ai(state) is False  # enabled but no key anywhere
    state.set_draft("wiz:ai_key", "AIza-test")
    assert wiz._save_ai(state) is True


def test_wizard_goto_clamps_and_finish_clears(state):
    state.wizard_goto(99)
    assert state.wizard_step == 7
    state.wizard_goto(-3)
    assert state.wizard_step == 0
    state.set_draft("wiz:bakalari_username", "novak")
    state.wizard_finished()
    assert state.wizard_dismissed is True
    assert not [k for k in state.drafts if k.startswith("wiz:")]


def test_wizard_stays_after_bakalari_step(state):
    """Regression: saving Bakalari creds on step 3 must not eject steps 4-7."""
    from strakalari.flet_ui.app import Shell

    class FakePage:
        def __init__(self):
            self.controls = []

        def add(self, control):
            self.controls.append(control)

        def update(self):
            pass

    page = FakePage()
    shell = Shell(page, state)
    assert state.needs_setup() is True
    shell.render()
    assert shell._wizard_shown is True
    # Complete step 2 exactly like the wizard's Next handler does.
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "secret")
    assert wiz._save_bakalari(state) is True
    assert state.needs_setup() is False  # would previously eject the wizard
    state.wizard_goto(wiz.STEP_BAKALARI)
    shell.render()
    assert state.wizard_dismissed is False
    assert shell._wizard_shown is True
    state.wizard_finished()
    shell.render()
    assert shell._wizard_shown is False


def test_wizard_builds_headless_all_steps(state, monkeypatch):
    import strakalari.core.browser as browser_mod

    monkeypatch.setattr(browser_mod, "is_browser_installed", lambda: False)
    for step in range(8):
        state.wizard_step = step
        view = wiz.build(state, None)
        assert view is not None


def test_calendar_step_requires_explicit_pick(state):
    # Nothing picked yet: save refuses, Continue stays disabled.
    assert wiz._cal_preset(state) == ""
    assert wiz._save_calendar(state) is False
    state.set_draft("wiz:cal_preset", "gekom_2026_2027")
    assert wiz._save_calendar(state) is True
    assert state.config.data["school_preset_id"] == "gekom_2026_2027"
    # Preset closures stay resolved from the preset, not copied.
    assert state.config.data["sem1_close"] == ""
    state.set_draft("wiz:cal_preset", "custom")
    assert wiz._save_calendar(state) is True
    assert state.config.data["school_preset_id"] == "custom"


def test_calendar_preset_lines_total(state):
    total, groups = wiz._preset_lines("gekom_2026_2027")
    assert total == 30
    assert sum(count for _, count in groups) == total
    assert ("Vánoční prázdniny", 12) in groups


def test_setup_pending_fresh_and_mid_wizard(state):
    # Fresh install: the wizard owns the screen, automation must wait.
    assert state.setup_pending is True
    # Bakalari step saves the login, but the later steps are still ahead.
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "secret")
    assert wiz._save_bakalari(state) is True
    assert state.needs_setup() is False
    state.wizard_shown = True
    assert state.setup_pending is True
    # Finishing releases automation.
    state.wizard_finished()
    assert state.setup_pending is False


def test_setup_pending_dismiss_releases(state):
    assert state.setup_pending is True
    state.dismiss_wizard()
    assert state.setup_pending is False


def test_setup_pending_false_with_credentials_never_shown(state):
    state.config.data.update({
        "bakalari_url": "https://skola.bakalari.cz",
        "bakalari_username": "novak",
        "bakalari_password": "x",
    })
    assert state.wizard_shown is False
    assert state.setup_pending is False


def test_scheduler_skips_refresh_while_setup_pending(state, monkeypatch):
    from strakalari.flet_ui.app import _register_jobs

    calls: list = []
    monkeypatch.setattr(
        state, "start_refresh",
        lambda scope="all": (calls.append(scope), True)[1],
    )
    runner = _register_jobs(state)
    assert state.setup_pending is True
    results = runner.run_now()
    assert len(results) == 1 and results[0].ok
    assert results[0].detail == "skipped (setup not finished)"
    assert calls == []
    # After finishing setup the same scheduler run starts a refresh.
    state.config.data.update({
        "bakalari_url": "https://skola.bakalari.cz",
        "bakalari_username": "novak",
        "bakalari_password": "x",
    })
    state.wizard_finished()
    results = runner.run_now()
    assert calls == ["all"]
    assert results[0].detail == "refresh finished"


def test_refresh_worker_aborts_without_credentials(state):
    # No browser/fetch may run here: with no credentials the worker
    # must bail out before ensure_browser(), and crucially without
    # queueing the missing-URL error popup over the wizard.
    assert state.demo_mode is True
    assert state._has_credentials() is False
    state._refresh_work("all")
    assert state.refresh_running is False
    assert state.error_dialog_pending is False
    assert state.last_error is None
    assert state.runs and state.runs[-1]["ok"] is False


def test_browser_step_comes_before_credentials():
    assert wiz.STEP_BROWSER < wiz.STEP_BAKALARI < wiz.STEP_STRAVA < wiz.STEP_AI
    assert wiz.STEP_AI < wiz.STEP_CALENDAR < wiz.STEP_DONE
    assert wiz.STEPS_TOTAL == 8


def test_browser_step_shows_per_file_progress(state, monkeypatch):
    """File 1/4 at 50 % → bar 0.5 and a '50 % (1/4)' label."""
    import strakalari.core.browser as browser_mod

    monkeypatch.setattr(browser_mod, "is_browser_installed", lambda: False)
    state.wizard_browser_status = "working"
    state.wizard_browser_label = "Chrome"
    state.wizard_browser_progress = 0.5
    state.wizard_browser_pos = (1, 4)
    for step in (wiz.STEP_BROWSER,):
        state.wizard_step = step
        view = wiz.build(state, None)
        assert view is not None
    import flet as ft

    bars: list = []
    texts: list = []

    def _walk(control):
        if isinstance(control, ft.ProgressBar):
            bars.append(control)
        if isinstance(control, ft.Text):
            texts.append(control.value or "")
        for child in getattr(control, "controls", None) or []:
            _walk(child)
        content = getattr(control, "content", None)
        if isinstance(control, ft.Container) and content is not None:
            _walk(content)

    _walk(view)
    assert bars, "expected a ProgressBar in the working browser step"
    assert any(b.value == pytest.approx(0.5) for b in bars)
    # Counter in the title, overall percent beside it.
    assert any("1/4" in t for t in texts), f"got {texts!r}"
    assert "50 %" in texts, f"got {texts!r}"


def test_ready_helpers_use_drafts(state):
    assert wiz._ready_bakalari(state) is False
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "secret")
    assert wiz._ready_bakalari(state) is True
    # Strava/AI default to enabled-with-nothing → not ready until filled.
    assert wiz._ready_strava(state) is False
    state.set_draft("wiz:strava_enabled", "")
    assert wiz._ready_strava(state) is True
    assert wiz._ready_ai(state) is True  # no stored key → AI off by default


def test_fingerprint_changes_on_edit(state):
    state.set_draft("wiz:bakalari_url", "https://a.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "one")
    before = wiz._fp_for(state, "bakalari")
    state.set_draft("wiz:bakalari_password", "two")
    assert wiz._fp_for(state, "bakalari") != before


def test_begin_test_requires_browser_first(state, monkeypatch):
    monkeypatch.setattr(wiz, "_browser_ready", lambda _s: False)
    state.wizard_step = wiz.STEP_BAKALARI
    assert wiz._begin_wizard_test(state, None, "bakalari", wiz.STEP_BAKALARI) is False
    assert state.wizard_step == wiz.STEP_BROWSER
    assert state.testing == ""


def test_begin_test_success_saves_and_advances(state, monkeypatch):
    monkeypatch.setattr(wiz, "_browser_ready", lambda _s: True)

    def fake_test(service, overrides, on_done=None):
        assert service == "bakalari"
        assert overrides["bakalari_username"] == "novak"
        on_done(True, "ok")
        return True

    monkeypatch.setattr(state, "test_connection", fake_test)
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "secret")
    state.wizard_step = wiz.STEP_BAKALARI
    assert wiz._begin_wizard_test(state, None, "bakalari", wiz.STEP_BAKALARI) is True
    assert state.wizard_step == wiz.STEP_BAKALARI + 1
    assert state.wizard_verified.get("bakalari") == wiz._fp_for(state, "bakalari")
    assert state.config.data["bakalari_username"] == "novak"


def test_begin_test_failure_stays_put(state, monkeypatch):
    monkeypatch.setattr(wiz, "_browser_ready", lambda _s: True)

    def fake_test(service, overrides, on_done=None):
        on_done(False, "bad password")
        return True

    monkeypatch.setattr(state, "test_connection", fake_test)
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "wrong")
    state.wizard_step = wiz.STEP_BAKALARI
    assert wiz._begin_wizard_test(state, None, "bakalari", wiz.STEP_BAKALARI) is True
    assert state.wizard_step == wiz.STEP_BAKALARI
    assert "bakalari" not in state.wizard_verified


def test_ai_connection_test_path(state, monkeypatch):
    import strakalari.core.gemini as gemini_mod

    monkeypatch.setattr(gemini_mod, "test_api_key",
                        lambda key, model="m", timeout=20, language="cs": (True, "Klíč Gemini funguje (x)."))
    monkeypatch.setattr(state, "_spawn", lambda target, args=(), name="": target(*args))
    assert state.test_connection("ai", {"gemini_api_key": "AIza-test"}) is True
    assert state.last_test["service"] == "ai"
    assert state.last_test["ok"] is True
    assert state.testing == ""


def test_disclaimer_must_be_acknowledged(state):
    import strakalari.flet_ui.views.wizard as wiz

    state.save = type(state).save.__get__(state)  # real save (tmp config)
    state.wizard_step = wiz.STEP_DISCLAIMER
    assert not wiz._disclaimer_ok(state)
    state.set_draft("wiz:disclaimer", "")
    assert not wiz._disclaimer_ok(state)
    state.set_draft("wiz:disclaimer", "1")
    assert wiz._disclaimer_ok(state)
    # A later run remembers the acknowledgment.
    state.save({"disclaimer_accepted": True})
    state.clear_drafts()
    assert wiz._disclaimer_ok(state)
    assert wiz.build(state, None) is not None


def test_browser_ready_trusts_status_while_downloading(state, monkeypatch):
    """Chrome's exe exists mid-install; the wizard must not call it ready."""
    import strakalari.core.browser as browser_mod

    calls: list = []
    monkeypatch.setattr(browser_mod, "is_browser_installed",
                        lambda: calls.append(1) or True)
    state.wizard_browser_status = "working"
    assert wiz._browser_ready(state) is False
    assert calls == []
    # Idle: probe once, then remember the answer (no driver per render).
    state.wizard_browser_status = ""
    assert wiz._browser_ready(state) is True
    assert wiz._browser_ready(state) is True
    assert calls == [1]
    assert state.wizard_browser_status == "ready"


def test_continue_while_downloading_queues_test(state, monkeypatch):
    """Continue mid-download stays on the step and tests once Chrome is in."""
    started: list = []

    def fake_test(service, overrides, on_done=None):
        started.append(service)
        return True

    monkeypatch.setattr(state, "test_connection", fake_test)
    state.set_draft("wiz:bakalari_url", "https://skola.bakalari.cz")
    state.set_draft("wiz:bakalari_username", "novak")
    state.set_draft("wiz:bakalari_password", "secret")
    state.wizard_step = wiz.STEP_BAKALARI
    state.wizard_browser_status = "working"
    assert wiz._begin_wizard_test(state, None, "bakalari", wiz.STEP_BAKALARI) is False
    assert state.wizard_step == wiz.STEP_BAKALARI  # no jump back
    assert state.wizard_pending_test == ("bakalari", wiz.STEP_BAKALARI)
    assert started == []
    assert wiz.build(state, None) is not None  # waiting row renders
    state.wizard_browser_status = "done"
    wiz._browser_finished(state)
    assert started == ["bakalari"]
    assert state.wizard_pending_test is None


def test_failed_download_drops_queued_test(state, monkeypatch):
    monkeypatch.setattr(state, "test_connection",
                        lambda *a, **k: pytest.fail("must not test without Chrome"))
    state.wizard_step = wiz.STEP_BAKALARI
    state.wizard_pending_test = ("bakalari", wiz.STEP_BAKALARI)
    state.wizard_browser_status = "error:network down"
    wiz._browser_finished(state)
    assert state.wizard_pending_test is None


def test_download_panel_on_later_steps(state):
    """The background download stays visible after leaving the browser step."""
    import flet as ft

    state.wizard_browser_status = "working"
    state.wizard_browser_label = "Chrome"
    state.wizard_browser_progress = 0.25
    state.wizard_browser_pos = (1, 4)
    state.wizard_step = wiz.STEP_AI
    view = wiz.build(state, None)
    bars: list = []

    def _walk(control):
        if isinstance(control, ft.ProgressBar):
            bars.append(control)
        for child in getattr(control, "controls", None) or []:
            _walk(child)
        content = getattr(control, "content", None)
        if isinstance(control, ft.Container) and content is not None:
            _walk(content)

    _walk(view)
    assert [b.value for b in bars] == [pytest.approx(0.25)]
    # Same control instance across renders: progress updates in place.
    assert wiz.build(state, None) is not None
    assert bars[0] is wiz._dl_widgets(state)["bar"]
