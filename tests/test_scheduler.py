"""PeriodicRunner scheduling."""
from datetime import datetime, timedelta
from strakalari.core.scheduler import PeriodicRunner, next_due
from strakalari.core.cache import last_updated_time, startup_seed
import strakalari.flet_ui.state as state_mod
from strakalari.flet_ui.app import _register_jobs
from strakalari.flet_ui.tray import TrayApp


class TestSchedulerStop:
    def test_stop_without_start_is_safe(self):
        from strakalari.core.scheduler import PeriodicRunner
        PeriodicRunner(interval_minutes=60).stop()


def test_scheduler_failed_run_retries_soon():
    from strakalari.core.scheduler import PeriodicRunner

    runner = PeriodicRunner(interval_minutes=60)
    runner.add_job("bad", lambda: 1 / 0)
    before = datetime.now()
    runner._run_all_once()
    due_in = (runner._last_run + timedelta(minutes=60) - before).total_seconds() / 60
    assert 0 < due_in <= 6  # ~5 min, not a full hour


def test_run_now_leaves_timer_alone():
    from strakalari.core.scheduler import PeriodicRunner

    runner = PeriodicRunner(interval_minutes=60)
    runner.add_job("good", lambda: "ok")
    assert runner._last_run is None
    runner.run_now()
    assert runner._last_run is None


def test_scheduler_next_due():
    from datetime import datetime

    now = datetime(2026, 9, 7, 12, 0)
    assert next_due(None, 60, now) == now
    last = datetime(2026, 9, 7, 11, 0)
    assert next_due(last, 60, now) == datetime(2026, 9, 7, 12, 0)


def test_scheduler_runs_jobs_and_captures_errors():
    calls = []
    runner = PeriodicRunner(interval_minutes=60)
    runner.add_job("good", lambda: calls.append(1) or "ok")
    runner.add_job("bad", lambda: 1 / 0)
    results = runner.run_now()
    assert calls == [1]
    by_name = {r.name: r for r in results}
    assert by_name["good"].ok is True
    assert by_name["bad"].ok is False
    assert by_name["bad"].error != ""


def _stamp(dt: datetime) -> str:
    return dt.strftime("%d.%m.%Y %H:%M:%S")


def test_last_updated_time_parses_formats():
    now = datetime.now()
    assert last_updated_time({"last_updated": _stamp(now)}) == now.replace(microsecond=0)
    assert last_updated_time({"last_updated": now.strftime("%Y-%m-%d %H:%M:%S")}) is not None
    assert last_updated_time({}) is None
    assert last_updated_time({"last_updated": "nonsense"}) is None


def test_startup_seed_needs_positive_evidence():
    now = datetime.now()
    fresh = startup_seed({"last_updated": _stamp(now - timedelta(minutes=10))}, now=now)
    assert fresh is not None
    assert now - fresh < timedelta(minutes=11)
    # Overdue stamp is still a seed (next_due puts it in the past -> run).
    assert startup_seed({"last_updated": _stamp(now - timedelta(hours=3))}, now=now) is not None
    # Unknown or future stamps fall back to refresh-on-start (None).
    assert startup_seed({}, now=now) is None
    assert startup_seed({"last_updated": "nonsense"}, now=now) is None
    assert startup_seed({"last_updated": _stamp(now + timedelta(hours=1))}, now=now) is None


def test_seed_defers_first_auto_run():
    now = datetime.now()
    fresh_seed = now - timedelta(minutes=10)
    assert next_due(fresh_seed, 60, now) > now  # next run in ~50 min, not at start
    stale_seed = now - timedelta(hours=3)
    assert next_due(stale_seed, 60, now) <= now  # overdue -> run on first tick
    assert next_due(None, 60, now) == now  # unknown -> old behavior


def test_runner_accepts_last_run_seed():
    seed = datetime.now() - timedelta(minutes=10)
    assert PeriodicRunner(interval_minutes=60, last_run=seed)._last_run == seed
    assert PeriodicRunner(interval_minutes=60)._last_run is None


def _make_state(monkeypatch):
    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = state_mod.AppState()
    app_state.wizard_dismissed = True
    return app_state


def test_register_jobs_seeds_from_fresh_cache(monkeypatch):
    state = _make_state(monkeypatch)
    state.data = {"last_updated": _stamp(datetime.now() - timedelta(minutes=10))}
    runner = _register_jobs(state)
    try:
        assert runner._last_run is not None
        assert state.scheduler_last_run == runner._last_run
        assert next_due(runner._last_run, 60, datetime.now()) > datetime.now()
    finally:
        runner.stop()


def test_register_jobs_empty_cache_refreshes_on_start(monkeypatch):
    state = _make_state(monkeypatch)
    state.data = {}
    runner = _register_jobs(state)
    try:
        assert runner._last_run is None
    finally:
        runner.stop()


def test_tray_startup_seed(monkeypatch):
    import strakalari.core.cache as cache_mod

    monkeypatch.setattr(
        cache_mod, "load_data_cache",
        lambda: {"last_updated": _stamp(datetime.now() - timedelta(minutes=10))},
    )
    assert TrayApp._startup_seed() is not None
    monkeypatch.setattr(cache_mod, "load_data_cache", lambda: {})
    assert TrayApp._startup_seed() is None


def test_scheduler_keeps_full_traceback(capsys):
    def inner():
        raise RuntimeError("deep cause")

    def outer():
        def middle():
            inner()
        middle()

    runner = PeriodicRunner(interval_minutes=60)
    runner.add_job("deep", outer)
    (result,) = runner.run_now()
    # The innermost frame is where the bug is — limit=3 used to cut it.
    assert "in inner" in result.error
    assert "RuntimeError: deep cause" in result.error
    assert "scheduled job 'deep' failed" in capsys.readouterr().out
