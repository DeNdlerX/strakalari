"""Background work: refresh runs, connection tests, update checks, the activity log.

Mixin of :class:`strakalari.flet_ui.state.AppState` — it relies on the
state attributes and helpers defined there (``config``, ``data``,
``_emit``, ``_spawn``, ``log`` …).
"""

from __future__ import annotations

from datetime import date, datetime


class ActivityMixin:
    def log(self, message: str) -> None:
        stamp = datetime.now().strftime("%H:%M:%S")
        self.log_lines.append(f"[{stamp}] {message}")
        self.log_lines = self.log_lines[-300:]
        self._emit()

    def clear_log(self) -> None:
        self.log_lines = []
        self._emit()

    def report_error(
        self,
        operation: str,
        exc: BaseException | None = None,
        message: str = "",
        traceback_str: str = "",
        extra: dict | None = None,
    ) -> dict:
        """Records a failure with full diagnostics and queues the popup.

        The run history keeps a short one-liner; the traceback, the tail
        of the live log and the config presence (set/empty, never values)
        go into ``last_error``,
        which the Shell shows in an error dialog with a copy button.
        Never raises — reporting must not hide the original error.
        """
        try:
            from strakalari.core import error_report as er

            summary = str(message or "").strip() or er.short_summary(exc)
            user_message = (
                str(exc).splitlines()[0][:300]
                if isinstance(exc, er.UserError) and str(exc).strip()
                else ""
            )
            if not user_message and er.is_timeout_error(exc):
                # Slow/unstable connection, not a bug: the friendly
                # fix-it text (raise limits / faster net) goes on screen
                # while the full bundle stays one copy-tap away behind
                # the "not your fault?" line.
                user_message = er.timeout_user_message()
            tb = str(traceback_str or "").strip()
            if not tb and exc is not None:
                tb = er.current_traceback()
            # Tail taken before the traceback lands in the live log: the
            # report carries the traceback on its own, and appending first
            # spent up to 25 of the 60 tail lines on a duplicate of it,
            # pushing out what the app was doing before it broke.
            log_tail = list(self.log_lines[-er.LOG_TAIL_LINES:])
            if tb:
                stamp = datetime.now().strftime("%H:%M:%S")
                for line in tb.splitlines()[-25:]:
                    self.log_lines.append(f"[{stamp}] {line.rstrip()}")
                self.log_lines = self.log_lines[-500:]
            try:
                config_data = self.config.data if isinstance(self.config.data, dict) else {}
            except Exception:
                config_data = {}
            report = er.build_report(
                operation, summary, tb,
                log_tail=log_tail,
                config=config_data, extra=extra,
                user_message=user_message,
            )
            # The popup's bundle is lost on restart; the (already
            # redacted) copy in console.log survives for a later report.
            try:
                print("Error report:\n" + er.format_report(report))
            except Exception:
                pass
        except Exception:
            report = {
                "at": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
                "operation": str(operation or "?"),
                "summary": str(message or "unknown error"),
                "traceback": "", "log_tail": [], "config": {},
                # Fail closed: the redactor itself crashed, so raw extra
                # must not be stored or pasted.
                "context": {}, "extra": {}, "user_message": "",
            }
        self.last_error = report
        self.status = "error"
        self.error_dialog_pending = True
        self._emit()
        return report

    def error_report_text(self) -> str:
        """The copy-pasteable diagnostics bundle ("" when no error)."""
        if not isinstance(self.last_error, dict):
            return ""
        try:
            from strakalari.core import error_report as er

            return er.format_report(self.last_error)
        except Exception:
            return ""

    def acknowledge_error(self) -> None:
        """Marks the queued popup as shown (called by the Shell).

        Deliberately no ``_emit``: the caller is already rendering, and
        emitting here would re-enter ``Shell.render``.
        """
        self.error_dialog_pending = False

    @property
    def sending_label(self) -> str:
        """The label of a manual send in flight ("" when none is).

        Excuse sends and lunch orders run their own browser session; the
        top bar shows them like a refresh (spinner + label) so the user
        sees the app working instead of a silent wait for the snackbar.
        """
        from .strings import S

        if bool(getattr(self, "sending_excuses", None)):
            return S("excuse_sending")
        if bool(getattr(self, "order_running", False)):
            return S("orders_sending")
        return ""

    def status_kind(self) -> str:
        if self.refresh_running or self.sending_label:
            return "working"
        if self.status == "error":
            return "error"
        if self.runs and self.runs[-1].get("ok"):
            return "ok"
        return "idle"

    @property
    def last_run_label(self) -> str:
        if not self.runs:
            return "—"
        last = self.runs[-1]
        when = last.get("finished") or last.get("started") or "—"
        mark = "✓" if last.get("ok") else "✗"
        return f"{mark} {when}"

    @property
    def next_run_label(self) -> str:
        if self.scheduler_last_run is None:
            return "—"
        try:
            from strakalari.core.scheduler import next_due

            due = next_due(
                self.scheduler_last_run,
                float(self.get("check_interval_minutes", 60) or 60),
                datetime.now(),
            )
            return due.strftime("%d.%m. %H:%M")
        except Exception:
            return "—"

    @property
    def update_banner(self) -> dict | None:
        """Release info to show, or None (up to date / dismissed)."""
        info = self.update_info
        if not info or not isinstance(info, dict):
            return None
        try:
            from strakalari.core import update as _update_mod

            if not _update_mod.update_available(info):
                return None
        except Exception:
            return None
        if self.update_dismissed == str(info.get("version") or ""):
            return None
        return info

    def dismiss_update(self) -> None:
        if isinstance(self.update_info, dict):
            self.update_dismissed = str(self.update_info.get("version") or "")
        self._emit()

    @property
    def update_channel(self) -> str:
        """'stable' or 'beta' (beta also offers stable releases)."""
        try:
            from strakalari.core.update import default_channel, normalize_channel

            return normalize_channel(self.get("update_channel") or default_channel())
        except Exception:
            return "stable"

    def set_update_channel(self, channel: str) -> bool:
        """Persists the channel and re-evaluates the update banner.

        Both channels share one cached API response, so the switch shows
        the right release at once; the follow-up check only hits the
        network when that cache is stale.
        """
        from strakalari.core import update as _update_mod

        channel = _update_mod.normalize_channel(channel)
        if not self.save({"update_channel": channel}):
            return False
        self.update_dismissed = ""
        try:
            cached = _update_mod.load_cached(channel)
            self.update_info = cached if _update_mod.update_available(cached) else None
        except Exception:
            self.update_info = None
        if not self.start_update_check():
            self._emit()
        return True

    def start_update_check(self, force: bool = False) -> bool:
        """Fetches latest release in the background. Returns False if busy."""
        if self.update_check_running:
            return False
        self.update_check_running = True
        self._emit()
        self._spawn(self._update_work, (force,), name="strakalari-update-check")
        return True

    def _update_work(self, force: bool = False) -> None:
        try:
            from strakalari.core import update as _update_mod

            info = _update_mod.check_for_updates(force=force, channel=self.update_channel)
            if info and _update_mod.update_available(info):
                self.update_info = info
            elif force or info is not None:
                # Manual re-check with no newer release clears a stale banner.
                self.update_info = None
                self.update_dismissed = ""
        except Exception:
            pass
        finally:
            self.update_check_running = False
            self._emit()

    def start_refresh(self, scope: str = "all") -> bool:
        """Fetches fresh data in a background thread. Returns False if busy."""
        if not self._claim_flight("refresh_running"):
            return False
        if scope not in ("all", "bakalari", "strava"):
            scope = "all"
        # refresh_running already claimed atomically above.
        self.cancel_requested = False
        self.status = "working"
        self.current_step = ""
        self._emit()

        self._spawn(self._refresh_work, (scope,), name="strakalari-refresh")
        return True

    def cancel_refresh(self) -> None:
        from .strings import S

        if not self.refresh_running:
            return
        self.cancel_requested = True
        # Instant feedback without a full rebuild: log() would _emit and
        # re-mount every view (losing focus in half-typed settings
        # fields). The progress channel repaints topbar-only on settings
        # and falls back to a full render elsewhere.
        self._worker_log(S("cancel_refresh_log"))
        self._emit_progress()

    def _worker_log(self, message: str, *, step: bool = True) -> None:
        """Adds a log line; ``step`` also shows it in the status bar.

        Only translated progress messages are steps. The core's own log
        lines are English diagnostics (``_core_log``): shown in the status
        bar they flashed English through a Czech UI during every refresh.
        """
        import time

        stamp = datetime.now().strftime("%H:%M:%S")
        self.log_lines.append(f"[{stamp}] {str(message).strip()}")
        self.log_lines = self.log_lines[-300:]
        text = str(message).strip()
        if text and step:
            self.current_step = text.splitlines()[0][:120]
        # A refresh emits dozens of log lines — re-rendering the whole UI
        # per line flickers, burns CPU and resets scroll positions and
        # half-typed inputs. Throttle to ~1 Hz; completion always emits.
        # Ticks go through the progress channel (topbar-only repaint on
        # settings) so user actions during a refresh still rebuild fully
        # via _emit instead of being swallowed by the tick fast-path.
        now = time.monotonic()
        if now - self._last_log_emit < 1.0:
            return
        self._last_log_emit = now
        self._emit_progress()

    def _core_log(self, message: str) -> None:
        """Core (English diagnostic) log line: activity log only."""
        self._worker_log(message, step=False)

    def _refresh_work(self, scope: str) -> None:
        """Background refresh: the shared core pipeline + UI bookkeeping."""
        from .strings import S

        started = datetime.now()
        if self.demo_mode and not self._has_any_credentials():
            # No login yet (fresh install / setup not finished): abort
            # before touching the browser — a login would raise a
            # missing-credentials UserError and pop a modal over the
            # setup wizard. Recorded as a failed run, never a popup.
            self._worker_log(S("missing_credentials_log"))
            self._finish_run(started, scope, False,
                             "missing credentials (setup not finished)")
            return
        from strakalari.core.refresh import session_lock

        # One refresh at a time across processes: the tray runs its own
        # scheduler, and two parallel runs would both log in, both
        # auto-send and overwrite each other's cache.
        with session_lock() as held:
            if held:
                self._refresh_locked(scope, started)
                return
        self._worker_log(S("session_busy"))
        self._finish_run(started, scope, False, S("session_busy"))

    def _refresh_locked(self, scope: str, started: datetime) -> None:
        """The refresh proper; runs while :func:`session_lock` is held."""
        from strakalari.core.refresh import run_refresh

        from .strings import S

        detail = ""
        ok = False
        cancelled = False
        try:
            self._worker_log(S("refresh_started_log").format(scope=scope))
            from strakalari.core.automation import Strakalari
            from strakalari.core.browser import ensure_browser

            self._worker_log(S("checking_browser"))
            ensure_browser(log_callback=lambda m: None)
            if self.cancel_requested:
                # Browser setup (first-run download) is not preemptible —
                # abort here instead of fetching right after it.
                raise InterruptedError("cancelled")
            app = Strakalari(on_log=self._core_log, start_browser=True)
            try:
                app.cancel_callback = lambda: self.cancel_requested
                result = run_refresh(
                    app, app.config_data, scope=scope,
                    cancelled_lunch_days=set(self.cancelled_lunches or set()),
                    is_cancelled=lambda: self.cancel_requested,
                    emit=lambda key, **fmt: self._worker_log(S(key).format(**fmt)),
                    lunch_prompt=str(getattr(self, "lunch_prefs", "") or ""),
                )
            finally:
                try:
                    app.close()
                except Exception:
                    pass
            if result.used_gemini:
                try:
                    self.config.set("gemini_last_run", date.today().isoformat())
                    self.config.save()
                except Exception as exc:  # noqa: BLE001 - stamp only
                    print(f"Warning: could not stamp gemini_last_run: {exc}")
            if result.auto_ordered_days:
                # Auto-submitted days are web truth now — applied BEFORE
                # reload_cache emits so no frame shows a stale "to send".
                self.pending_orders.difference_update(result.auto_ordered_days)
            self.reload_cache()
            extras = []
            if result.excuses_sent:
                extras.append(S("auto_excuses_sent").format(n=result.excuses_sent))
            if result.lunches_ordered:
                extras.append(S("auto_lunch_sent").format(n=result.lunches_ordered))
            detail = " · ".join([S("subjects_count").format(n=len(self.absence()))] + extras)
            auto_errors = result.automation_errors
            fetch_errors = [e for e in result.errors if e not in auto_errors]
            if fetch_errors:
                phase, exc = fetch_errors[0]
                raise exc
            if auto_errors and result.only_low_balance:
                # An empty Strava account is the user's to fix, not a bug:
                # a warning (toast at most once a day, banner on Obědy)
                # instead of the error popup, and the run counts as done
                # so the scheduler does not retry every 5 minutes.
                _phase, exc = auto_errors[0]
                self._warn_low_balance(str(exc))
                auto_errors = []
            if auto_errors:
                # Fail loudly: something that should have been sent or
                # ordered under the user's account was not.
                phase, exc = auto_errors[0]
                detail = self._failure_detail(exc)
                self._worker_log(S("automation_failed_body").format(detail=detail))
                self._notify("automation_failed",
                             S("automation_failed_body").format(detail=detail))
                self.report_error(f"automation ({phase})", exc, message=detail,
                                  extra={"scope": scope})
                return
            ok = True
            self._notify("refresh_done", S("refresh_done_body"))
            self._worker_log(S("refresh_finished_log"))
        except InterruptedError:
            detail = S("cancelled_by_user")
            cancelled = True
            self._worker_log(S("refresh_cancelled_log"))
        except Exception as exc:  # noqa: BLE001 - surface, don't crash
            detail = self._failure_detail(exc)
            self._worker_log(S("refresh_failed_log").format(detail=detail))
            self.report_error(f"refresh ({scope})", exc, message=detail,
                             extra={"scope": scope})
            self._notify("refresh_failed",
                         S("refresh_failed_body").format(detail=detail))
        finally:
            # Latch release + run record for EVERY exit — including
            # BaseException, which neither except above catches.
            self._finish_run(started, scope, ok, detail, cancelled=cancelled)

    def _warn_low_balance(self, message: str) -> None:
        """Logs the empty-account warning; notifies at most once a day."""
        from strakalari.core.refresh import claim_low_balance_notice

        self._worker_log(message)
        if claim_low_balance_notice():
            self._notify("lunch_skipped", message)

    def low_balance_warning(self) -> dict | None:
        """``{"at", "days"}`` of the last "not enough money" rejection, or None.

        Read from the data cache so a detection by the tray shows here too.
        """
        from strakalari.core.models import parse_cz_date

        info = (self.data or {}).get("strava_low_balance")
        if not isinstance(info, dict) or not info.get("days"):
            return None
        # Days that are over cannot be ordered any more: no stale banner.
        today = date.today()
        days = [d for d in info.get("days") or []
                if (parse_cz_date(d) or today) >= today]
        if not days:
            return None
        return {**info, "days": days}

    @staticmethod
    def _failure_detail(exc: BaseException) -> str:
        from strakalari.core.error_report import UserError

        from .strings import S

        first = str(exc).splitlines()[0][:200] if str(exc).strip() else S("unknown_error")
        # User-fixable failures read better without the exception type.
        return first if isinstance(exc, UserError) else f"{type(exc).__name__}: {first}"

    def _notify(self, event: str, body: str) -> None:
        try:
            from strakalari.core import notify as notify_core

            notify_core.notify(event, body, self.get("notifications", {}))
        except Exception as exc:  # noqa: BLE001 - notifications are optional
            print(f"Warning: notification failed: {exc}")

    def _finish_run(self, started: datetime, scope: str, ok: bool, detail: str,
                    cancelled: bool = False) -> None:
        finished = datetime.now()
        self.runs.append({
            "started": started.strftime("%H:%M:%S"),
            "finished": finished.strftime("%d.%m. %H:%M"),
            # Machine-readable twins of the labels above (Activity shows
            # "12 min ago" and the run length from these).
            "at": finished.isoformat(timespec="seconds"),
            "seconds": max(0, round((finished - started).total_seconds())),
            "ok": ok, "scope": scope, "detail": detail,
            # Callers branch on this, never on the (translated) detail.
            "cancelled": bool(cancelled),
        })
        self.runs = self.runs[-20:]
        self.status = "idle" if ok else "error"
        self.current_step = ""
        self.refresh_running = False
        self.cancel_requested = False
        self._emit()

    def test_connection(self, service: str, overrides: dict | None = None,
                        on_done=None) -> bool:
        """Tests a login in a background thread. Returns False if busy.

        ``on_done`` (optional ``(ok, message)`` callable) runs in the
        worker thread after the result is recorded — the wizard uses it
        to auto-advance the step on success.
        """
        if service not in ("bakalari", "strava", "ai"):
            return False
        if not self._claim_flight("testing"):
            return False
        self.testing = service
        self._emit()

        self._spawn(self._test_work, (service, dict(overrides or {}), on_done),
                    name="strakalari-test-login")
        return True

    def _test_work(self, service: str, overrides: dict, on_done=None) -> None:
        from .strings import S

        ok, message = False, ""
        try:
            if service == "ai":
                from strakalari.core.gemini import test_api_key
                from strakalari.core.helpers import decrypt_strict
                from strakalari.core.i18n import get_language

                key = str((overrides or {}).get("gemini_api_key", "") or "").strip()
                model = str((overrides or {}).get(
                    "gemini_model",
                    self.get("gemini_model", "gemini-3.8-flash")) or "").strip()
                if not key and not (overrides or {}).get("gemini_api_key"):
                    raw = str(self.get("gemini_api_key", "") or "")
                    if raw and self.get("gemini_api_key_encrypted"):
                        raw = decrypt_strict(raw) or ""
                    key = raw.strip()
                if not model:
                    model = "gemini-3.8-flash"
                try:
                    language = get_language()
                except Exception:
                    language = "cs"
                self.log(S("test_ai_key_log").format(model=model))
                ok, message = test_api_key(key, model=model, language=language)
            else:
                from strakalari.core.automation import Strakalari

                self.log(S("test_login_log").format(service=service))
                app = Strakalari(config_data=overrides or None, start_browser=True)
                try:
                    if service == "bakalari":
                        ok, message = app.check_bakalari_login()
                    else:
                        ok, message = app.check_strava_login()
                finally:
                    try:
                        app.close()
                    except Exception:
                        pass
        except Exception as exc:  # noqa: BLE001 - report, don't crash
            first = str(exc).splitlines()[0][:200] if str(exc).strip() else "unknown error"
            ok, message = False, f"{type(exc).__name__}: {first}"
        except BaseException:
            self.testing = ""
            self._emit()
            raise
        self.last_test = {
            "service": service, "ok": bool(ok),
            "message": message, "at": datetime.now().strftime("%H:%M:%S"),
        }
        self.log(f"Test {service}: {S('connection_ok') if ok else S('connection_failed')} — {message}")
        self.testing = ""
        self._emit()
        if callable(on_done):
            try:
                on_done(bool(ok), message)
            except Exception as exc:  # noqa: BLE001 - never crash the worker
                print(f"Warning: test on_done failed: {exc}")
