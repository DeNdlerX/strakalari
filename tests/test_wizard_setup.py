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
    assert state.wizard_step == wiz.STEP_DONE
    state.wizard_goto(-3)
    assert state.wizard_step == 0
    state.set_draft("wiz:bakalari_username", "novak")
    state.wizard_finished()
    assert state.wizard_dismissed is True
    assert not [k for k in state.drafts if k.startswith("wiz:")]


def test_wizard_stays_after_bakalari_step(state):
    """Regression: saving Bakalari creds must not eject the later steps."""
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


def test_wizard_builds_headless_all_steps(state):
    for step in range(wiz.STEPS_TOTAL):
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


def test_excuses_step_requires_signature(state):
    state.config.data["your_signature"] = ""
    assert wiz._save_signature(state) is False
    state.set_draft("wiz:signature", "  Jan Novák  ")
    assert wiz._save_signature(state) is True
    assert state.config.data["your_signature"] == "Jan Novák"


def test_limits_step_updates(state, monkeypatch):
    monkeypatch.setattr(wiz, "_limit_subjects", lambda s: ["Matematika", "Fyzika"])
    state.config.data.update({"subject_limits": {"Fyzika": 20.0, "Dějepis": 30.0},
                              "absence_critical_pct": 25.0})
    state.set_draft("wiz:limit:Matematika", "30,5")
    state.set_draft("wiz:limit:Fyzika", "")  # blank = the default limit
    assert wiz._limits_updates(state) == {
        "subject_limits": {"Matematika": 30.5, "Dějepis": 30.0},
        "absence_critical_pct": 25.0,
    }
    for bad in ("abc", "150", "-1"):
        state.set_draft("wiz:limit:Matematika", bad)
        assert wiz._limits_updates(state) is None


def test_limits_step_loads_subjects_once(state, monkeypatch):
    started = []
    monkeypatch.setattr(state, "start_refresh",
                        lambda scope="all": started.append(scope) or True)
    monkeypatch.setattr(wiz, "_limit_subjects", lambda s: [])
    state.wizard_step = wiz.STEP_LIMITS
    wiz.build(state, None)
    assert started == []  # no Bakaláři login yet
    state.config.data.update({"bakalari_url": "https://skola.bakalari.cz",
                              "bakalari_username": "novak", "bakalari_password": "x"})
    wiz.build(state, None)
    wiz.build(state, None)  # re-renders (progress, Back) never start another
    assert started == ["bakalari"]


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
    # No fetch may run here: with no credentials the worker must bail
    # out before logging in, and crucially without queueing the
    # missing-URL error popup over the wizard.
    assert state.demo_mode is True
    assert state._has_credentials() is False
    state._refresh_work("all")
    assert state.refresh_running is False
    assert state.error_dialog_pending is False
    assert state.last_error is None
    assert state.runs and state.runs[-1]["ok"] is False


def test_step_order():
    assert wiz.STEP_DISCLAIMER < wiz.STEP_BAKALARI < wiz.STEP_LIMITS < wiz.STEP_STRAVA < wiz.STEP_AI
    assert wiz.STEP_AI < wiz.STEP_CALENDAR < wiz.STEP_EXCUSES < wiz.STEP_DONE
    assert wiz.STEPS_TOTAL == wiz.STEP_DONE + 1


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


def test_begin_test_success_saves_and_advances(state, monkeypatch):

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


