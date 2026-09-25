"""Regressions from the code review: ignored excuses, blacklist edits,
per-day Gemini picks, login-field clearing, scheduler retry/interval,
config save locking and canonical lunch-order day keys."""
import json
from datetime import date, datetime

import pytest

from strakalari.core.automation import Strakalari, generate_excuses
from strakalari.core.models import excuse_tasks_from_lessons, lessons_from_timetable

TODAY = datetime(2026, 9, 20)


def _absent(time):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": "Absent", "absencetext": "Absence", "notice": ""}


def _ui_key(raw, period):
    """The exact key the UI stores when the user clicks Ignore."""
    tasks = excuse_tasks_from_lessons(lessons_from_timetable(raw))
    return next(t.key for t in tasks if t.period == period)


# -- 1. auto mode honors the UI ignore list -----------------------------------

class TestIgnoredExcuses:
    def test_ignored_lesson_is_never_auto_excused(self):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)"), _absent("2 (8:55-9:40)"),
                              _absent("3 (10:00-10:45)")]}
        key = _ui_key(raw, 2)
        excuses = generate_excuses(raw, delay_days=0, override_today=TODAY,
                                   ignored=[key])
        # No whole-day excuse (it would cover lesson 2), lesson 2 left out.
        assert {(e["type"], e.get("starting_lesson"), e.get("ending_lesson"))
                for e in excuses} == {("days and hours", 1, 1),
                                      ("days and hours", 3, 3)}

    def test_ignored_day_breaks_full_day_chain(self):
        raw = {"07.09.2026": [_absent("1 (8:00-8:45)")],
               "08.09.2026": [_absent("1 (8:00-8:45)")],
               "09.09.2026": [_absent("1 (8:00-8:45)")]}
        key = _ui_key({"08.09.2026": raw["08.09.2026"]}, 1)
        excuses = generate_excuses(raw, delay_days=0, override_today=TODAY,
                                   ignored=[key])
        assert [(e["starting_day"], e["ending_day"]) for e in excuses] == [
            ("07.09.2026", "07.09.2026"), ("09.09.2026", "09.09.2026")]

    def test_excuse_absence_passes_config_ignore_list(self, monkeypatch):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)")]}
        monkeypatch.setattr(Strakalari, "timetableData", property(lambda self: raw))
        app = Strakalari.__new__(Strakalari)
        app.excuse_mode = "auto"
        app.excuse_delay_days = 0
        app.cancel_requested = False
        app.config_data = {"ignored_excuses": [_ui_key(raw, 1)]}
        app.writeLog = lambda m: None
        app._send_excuse = lambda *a, **k: pytest.fail("ignored absence was sent")
        assert app.excuseAbsence() == 0

    def test_garbage_keys_are_ignored_safely(self):
        raw = {"08.09.2026": [_absent("1 (8:00-8:45)")]}
        assert generate_excuses(raw, delay_days=0, override_today=TODAY,
                                ignored=["nonsense", "2026-13-01|1|M", None]) == \
            generate_excuses(raw, delay_days=0, override_today=TODAY)


# -- 2. blacklist edits never overwrite an unreadable file --------------------

class TestBlacklistEdits:
    @pytest.fixture()
    def bl_state(self, state, tmp_path, monkeypatch):
        path = tmp_path / "strava_blacklist.json"
        monkeypatch.setattr(state, "_blacklist_path", lambda: str(path))
        monkeypatch.setattr(state, "apply_food_filter", lambda prefs: None)
        return state, path

    def test_add_refuses_on_corrupt_file(self, bl_state):
        state, path = bl_state
        original = '["vepřové", "houby", "játra",]'
        path.write_text(original, encoding="utf-8")
        assert state.add_blacklist_word("ryba") is False
        assert path.read_text(encoding="utf-8") == original
        assert state._blacklist_edit_error

    def test_remove_refuses_on_non_list(self, bl_state):
        state, path = bl_state
        path.write_text('{"houby": 1}', encoding="utf-8")
        assert state.remove_blacklist_word("houby") is False
        assert json.loads(path.read_text(encoding="utf-8")) == {"houby": 1}

    def test_add_and_remove_keep_existing_words(self, bl_state):
        state, path = bl_state
        path.write_text('["houby", "játra"]', encoding="utf-8")
        assert state.add_blacklist_word("ryba") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["houby", "játra", "ryba"]
        assert state.remove_blacklist_word("houby") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["játra", "ryba"]

    def test_add_to_missing_file_creates_it(self, bl_state):
        state, path = bl_state
        assert state.add_blacklist_word("ryba") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["ryba"]


# -- 4. Gemini picks must come from that day's menu -----------------------------

FOOD = {"01.10.2026": {"table1&1&0": "Guláš", "table1&2&0": "Rizoto"},
        "2.10.2026": {"table2&1&0": "Svíčková", "table2&2&0": "Salát"}}


def test_validate_recommendation_rejects_other_days_meal():
    from strakalari.core.gemini import validate_recommendation

    got = validate_recommendation({"01.10.2026": "table2&1&0",
                                   "02.10.2026": "table2&2&0"}, FOOD)
    assert got == {"2.10.2026": "table2&2&0"}


def test_merge_falls_back_to_filter_for_cross_day_pick():
    from strakalari.core.lunch_auto import merge_gemini_with_filter

    got = merge_gemini_with_filter({"01.10.2026": "table2&1&0"}, FOOD,
                                   today=date(2026, 9, 24))
    assert got["01.10.2026"] == "table1&1&0"  # filter pick, not 2.10.'s meal


# -- 3. login fields are cleared before typing ----------------------------------

class _Field:
    def __init__(self, value="", fill_works=True):
        self.value = value
        self.fill_works = fill_works

    def fill(self, text):
        if not self.fill_works:
            raise RuntimeError("fill ignored")
        self.value = text

    def press(self, key):
        if key == "Delete":
            self.value = ""


@pytest.mark.parametrize("fill_works", [True, False])
def test_clear_input_empties_field(fill_works):
    from strakalari.core.helpers import clear_input

    field = _Field("1234", fill_works=fill_works)
    clear_input(field)
    assert field.value == ""


def test_clear_input_propagates_cancel():
    from strakalari.core.helpers import clear_input

    class _Cancelled(_Field):
        def fill(self, text):
            raise InterruptedError("cancelled")

    with pytest.raises(InterruptedError):
        clear_input(_Cancelled("x"))


# -- 6/7. scheduler: live interval + reported failures retry early -------------

def test_interval_provider_is_polled():
    from strakalari.core.scheduler import PeriodicRunner

    runner = PeriodicRunner(interval_minutes=60, interval_provider=lambda: 15)
    runner._poll_interval()
    assert runner.interval_minutes == 15
    runner.interval_provider = lambda: None  # "unchanged"
    runner._poll_interval()
    assert runner.interval_minutes == 15


def test_job_failed_counts_as_failure_but_reported():
    from strakalari.core.scheduler import JobFailed, PeriodicRunner

    def job():
        raise JobFailed("login failed")

    seen = []
    runner = PeriodicRunner(interval_minutes=60, on_result=seen.append)
    runner.add_job("refresh", job)
    before = datetime.now()
    runner._run_all_once()
    assert seen[0].ok is False and seen[0].reported is True
    # Early retry: due in ~5 minutes, not a full interval.
    from strakalari.core.scheduler import next_due
    assert (next_due(runner._last_run, 60, before) - before).total_seconds() < 6 * 60


def test_window_job_raises_when_refresh_failed(state, monkeypatch):
    from strakalari.core.scheduler import JobFailed
    from strakalari.flet_ui.app import _register_jobs

    state.wizard_dismissed = True
    state.demo_mode = False
    monkeypatch.setattr(state, "start_refresh", lambda scope="all": (
        state.runs.append({"ok": False, "detail": "Login failed"}), True)[1])
    runner = _register_jobs(state)
    with pytest.raises(JobFailed):
        runner._jobs["refresh"]()



def test_window_job_ignores_cancelled_run_in_any_language(state, monkeypatch):
    from strakalari.flet_ui.app import _register_jobs

    state.wizard_dismissed = True
    state.demo_mode = False
    # The detail is translated text: only the flag may decide.
    monkeypatch.setattr(state, "start_refresh", lambda scope="all": (
        state.runs.append({"ok": False, "detail": "zrušeno uživatelem",
                           "cancelled": True}), True)[1])
    runner = _register_jobs(state)
    assert runner._jobs["refresh"]() == "refresh finished"


def test_window_job_stops_waiting_on_shutdown(state, monkeypatch):
    import threading

    from strakalari.flet_ui.app import _register_jobs

    state.wizard_dismissed = True
    state.demo_mode = False

    def _hang(scope="all"):
        state.refresh_running = True  # never finishes
        return True

    monkeypatch.setattr(state, "start_refresh", _hang)
    runner = _register_jobs(state)
    threading.Timer(0.2, runner.stop).start()
    assert runner._jobs["refresh"]() == "refresh still running at shutdown"


def test_window_job_gives_up_on_a_hung_refresh(state, monkeypatch):
    import strakalari.flet_ui.app as app_mod

    state.wizard_dismissed = True
    state.demo_mode = False
    monkeypatch.setattr(app_mod, "_REFRESH_JOB_WAIT_S", 0)

    def _hang(scope="all"):
        state.refresh_running = True
        return True

    monkeypatch.setattr(state, "start_refresh", _hang)
    runner = app_mod._register_jobs(state)
    with pytest.raises(RuntimeError, match="still running"):
        runner._jobs["refresh"]()

def test_tray_interval_follows_config_file(tmp_path, monkeypatch):
    import os

    import strakalari.flet_ui.tray as tray_mod
    from strakalari.core.config import ConfigManager

    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"check_interval_minutes": 60}), encoding="utf-8")
    monkeypatch.setattr(tray_mod, "ConfigManager",
                        lambda *a, **k: ConfigManager(config_path=str(cfg)))
    tray = tray_mod.TrayApp()
    assert tray._configured_interval() is None  # unchanged since start
    cfg.write_text(json.dumps({"check_interval_minutes": 15}), encoding="utf-8")
    os.utime(cfg, (1, 1))
    tray.runner._poll_interval()
    assert tray.runner.interval_minutes == 15


# -- 8. config save never writes without the inter-process lock ----------------

def test_config_save_refuses_when_lock_busy(tmp_path, monkeypatch):
    import strakalari.core.helpers as helpers
    from strakalari.core.config import ConfigManager

    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"theme": "dark"}), encoding="utf-8")
    manager = ConfigManager(config_path=str(cfg))
    manager.set("theme", "light")
    monkeypatch.setattr(helpers.InterProcessLock, "acquire", lambda self, timeout_s=0: False)
    with pytest.raises(RuntimeError):
        manager.save()
    assert json.loads(cfg.read_text(encoding="utf-8"))["theme"] == "dark"
    monkeypatch.undo()
    manager.save()  # the edit was kept and goes out with the next save
    assert json.loads(cfg.read_text(encoding="utf-8"))["theme"] == "light"


# -- 9. lunch-order day keys are canonical in the UI state ----------------------

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


# -- ignore list: a failed save must not leave a memory-only ignore ------------

def _failing_save(state, monkeypatch):
    def _boom():
        raise RuntimeError("lock busy")

    monkeypatch.setattr(state.config, "save", _boom)


def test_ignore_rolls_back_when_save_fails(state, monkeypatch):
    _failing_save(state, monkeypatch)
    assert state.ignore_excuse("2026-09-01|2|Matematika") == ""
    assert state.ignored_excuse_keys == set()
    # The config copy is rolled back too, so a later unrelated save
    # cannot persist the ignore behind the user's back.
    assert state.config.get("ignored_excuses", []) == []
    assert state.last_ignore_error


def test_unignore_rolls_back_when_save_fails(state, monkeypatch):
    assert state.ignore_excuse("2026-09-01|2|Matematika")
    _failing_save(state, monkeypatch)
    assert state.unignore_excuse("2026-09-01|2|Matematika") is False
    assert state.ignored_excuse_keys == {"2026-09-01|2|Matematika"}
    assert state.config.get("ignored_excuses") == ["2026-09-01|2|Matematika"]


def test_ignore_day_rolls_back_when_save_fails(state, monkeypatch):
    tasks = [{"key": "2026-09-01|1|A", "date": "2026-09-01"},
             {"key": "2026-09-01|2|B", "date": "2026-09-01"}]
    monkeypatch.setattr(state, "_all_excuse_tasks", lambda: tasks)
    _failing_save(state, monkeypatch)
    assert state.ignore_day("2026-09-01") == []
    assert state.ignored_excuse_keys == set()
    assert state.last_ignore_error


def test_ignore_saved_normally(state):
    assert state.ignore_excuse("2026-09-01|2|Matematika") == "2026-09-01|2|Matematika"
    assert state.last_ignore_error == ""
    assert state.unignore_keys(["2026-09-01|2|Matematika"]) is True
    assert state.ignored_excuse_keys == set()


# -- Gemini user texts follow the requested language ---------------------------

def test_gemini_texts_follow_language():
    from strakalari.core.gemini import local_fallback_recommendation, recommend_lunches, test_api_key

    assert recommend_lunches({}, "", "", language="en")[0] == "No menu to recommend from."
    assert recommend_lunches({}, "", "", language="cs")[0] == "Žádný jídelníček k doporučení."
    assert test_api_key("", language="en") == (False, "Missing API key.")
    html, _ = local_fallback_recommendation({"01.10.2026": {"1": "Polévka"}}, "", language="en")
    assert html.startswith("Local recommendation (no AI):")


def test_core_t_lang_override():
    from strakalari.core.i18n import get_language, t

    assert t("gemini_missing_key", lang="en") == "Missing API key."
    assert t("gemini_missing_key", lang="cs") == "Chybí API klíč."
    # The override never changes the active language.
    assert get_language() in ("cs", "en")
