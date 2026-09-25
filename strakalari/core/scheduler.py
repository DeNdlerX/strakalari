"""Periodic background runner for refresh / auto-excuse / lunch jobs.

The UI (or tray) registers callables; the runner executes them every
``interval_minutes`` in a daemon thread and reports results through an
optional callback. Jobs must never raise — failures are captured and
reported as ``JobResult`` with ``ok=False``.

A tiny pure helper (``next_due``) holds the scheduling math so it stays
unit-testable without threads or clocks.
"""

from __future__ import annotations

import threading
import traceback
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Callable


def next_due(last_run: datetime | None, interval_minutes: float, now: datetime) -> datetime:
    """When the next run should happen given the last one."""
    interval = max(1.0, float(60 if interval_minutes is None else interval_minutes))
    if last_run is None:
        return now
    return last_run + timedelta(minutes=interval)


class JobFailed(Exception):
    """A job failure the job itself already reported to the user.

    Counts as a failed run (early retry), but ``on_result`` callbacks
    should not notify about it a second time (``JobResult.reported``).
    """


@dataclass
class JobResult:
    name: str
    ok: bool
    finished_at: datetime = field(default_factory=datetime.now)
    detail: str = ""
    error: str = ""
    #: True when the job already surfaced the failure (see JobFailed).
    reported: bool = False


Job = Callable[[], Any]
ResultCallback = Callable[[JobResult], None]


class PeriodicRunner:
    """Runs registered jobs every ``interval_minutes`` in a daemon thread."""

    def __init__(
        self,
        interval_minutes: float = 60,
        on_result: ResultCallback | None = None,
        last_run: datetime | None = None,
        interval_provider: Callable[[], float] | None = None,
    ) -> None:
        self.interval_minutes = max(1.0, float(60 if interval_minutes is None else interval_minutes))
        self.on_result = on_result
        # Polled every tick so a setting saved elsewhere (e.g. the window
        # process while this runs in the tray) takes effect without a restart.
        self.interval_provider = interval_provider
        self._jobs: dict[str, Job] = {}
        # Seed for process starts: pass the last successful refresh time so
        # the first auto-run comes ``interval`` after it instead of firing
        # ~5 s after launch even with a fresh cache. None = run on first tick.
        self._last_run: datetime | None = last_run
        self._history: list[JobResult] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def add_job(self, name: str, job: Job) -> None:
        with self._lock:
            self._jobs[name] = job

    @property
    def history(self) -> list[JobResult]:
        with self._lock:
            return list(self._history)

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def _run_all_once(self, advance_timer: bool = True) -> list[JobResult]:
        with self._lock:
            jobs = list(self._jobs.items())
        results: list[JobResult] = []
        for name, job in jobs:
            try:
                detail = job()
                results.append(JobResult(name=name, ok=True, detail=str(detail or "")))
            except JobFailed as exc:
                results.append(JobResult(name=name, ok=False, error=str(exc), reported=True))
            except Exception:  # noqa: BLE001 - jobs must never kill the runner
                # Full traceback: ``limit=3`` kept only the outermost frames
                # and hid where the job actually broke. Printed too — in the
                # tray (no dialog) this lands in console.log, the only
                # trace a background failure otherwise leaves.
                tb = traceback.format_exc()
                from .error_report import redact_with_saved_config

                print(f"Error: scheduled job {name!r} failed at "
                      f"{datetime.now():%Y-%m-%d %H:%M:%S}:\n"
                      f"{redact_with_saved_config(tb)}")
                results.append(JobResult(name=name, ok=False, error=tb))
        now = datetime.now()
        with self._lock:
            self._history.extend(results)
            self._history = self._history[-50:]
            if advance_timer:
                if not results or all(r.ok for r in results):
                    self._last_run = now
                else:
                    # A failed run must not delay the retry a full interval:
                    # come back in ~5 minutes instead (manual runs never
                    # touch the timer at all — see run_now).
                    self._last_run = now + timedelta(minutes=5) - timedelta(
                        minutes=self.interval_minutes)
        if self.on_result:
            for result in results:
                try:
                    self.on_result(result)
                except Exception:  # noqa: BLE001 - UI callback issues stay local
                    print(f"Warning: scheduler result callback failed for {result.name}")
        return results

    def run_now(self) -> list[JobResult]:
        """Executes all jobs immediately (used by manual refresh too).

        Never touches the periodic timer, so a manual refresh neither
        postpones the next auto run nor masks a failed run's early retry.
        """
        return self._run_all_once(advance_timer=False)

    def start(self) -> None:
        if self.running:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="strakalari-scheduler", daemon=True)
        self._thread.start()

    def wait_stopped(self, timeout: float) -> bool:
        """Sleeps up to ``timeout`` seconds; True once :meth:`stop` was called.

        For jobs that wait on work running elsewhere: they wake up on
        shutdown instead of holding the scheduler thread.
        """
        return self._stop.wait(timeout)

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=10)
        # Drop a dead thread so a later start() actually restarts the
        # loop instead of early-returning on a stale handle.
        if thread is not None and not thread.is_alive():
            self._thread = None

    def _poll_interval(self) -> None:
        provider = self.interval_provider
        if not callable(provider):
            return
        try:
            value = provider()
            if value is not None:
                self.interval_minutes = max(1.0, float(value))
        except Exception:  # noqa: BLE001 - keep the last good interval
            pass

    def _loop(self) -> None:
        while not self._stop.wait(5):
            if self._stop.is_set():
                break
            self._poll_interval()
            due_at = next_due(self._last_run, self.interval_minutes, datetime.now())
            if datetime.now() >= due_at:
                self._run_all_once()
                # No extra sleep: the 5s tick above already paces the loop,
                # so intervals stay exact and stop() stays responsive.
