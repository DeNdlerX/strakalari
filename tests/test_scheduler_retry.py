"""Scheduler: the interval is read live and a failed refresh retries early."""
import json
from datetime import datetime

import pytest



# -- scheduler: live interval + reported failures retry early -------------

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
