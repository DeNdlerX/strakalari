"""Pending excuse tasks: listing, ignoring and one-click sending.

Mixin of :class:`strakalari.flet_ui.state.AppState` — it relies on the
state attributes and helpers defined there (``config``, ``data``,
``_emit``, ``_spawn``, ``log`` …).
"""

from __future__ import annotations

import threading
from datetime import date

from strakalari.core.excuse_history import task_covered


def _task_covered_by_history(task: dict, history: list) -> bool:
    """True when a one-click excuse task falls inside a persisted excuse."""
    try:
        task_day = date.fromisoformat(str((task or {}).get("date", "")))
    except ValueError:
        return False
    try:
        task_period = int((task or {}).get("period"))
    except (TypeError, ValueError):
        task_period = None
    return task_covered(task_day, task_period, history)


class ExcuseTasksMixin:
    def _all_excuse_tasks(self) -> list[dict]:
        if self.demo_mode:
            return []
        from strakalari.core.models import excuse_tasks_from_lessons, lessons_from_timetable

        return [
            {"key": t.key, "kind": t.kind, "label": t.label, "detail": t.detail,
             "date": t.date.isoformat() if t.date else "", "period": t.period,
             "status": "pending"}
            for t in excuse_tasks_from_lessons(lessons_from_timetable(self.timetable()))
        ]

    def excuse_tasks(self) -> list[dict]:
        tasks = self._all_excuse_tasks()
        sent_keys = {entry["key"] for entry in self.excuse_log}
        tasks = [t for t in tasks if t["key"] not in sent_keys]
        if self.ignored_excuse_keys:
            tasks = [t for t in tasks if t["key"] not in self.ignored_excuse_keys]
        # Also hide tasks already covered by the persisted excuse history
        # (already_excused_lessons.json) — otherwise a sent excuse reappears
        # after every restart and can be submitted twice.
        try:
            history = self.config.get_excuse_history()
        except Exception:
            history = []
        if history:
            tasks = [t for t in tasks if not _task_covered_by_history(t, history)]
        return tasks

    def ignored_tasks(self) -> list[dict]:
        """Currently ignored tasks (still present in the timetable)."""
        if not self.ignored_excuse_keys:
            return []
        return [t for t in self._all_excuse_tasks()
                if t["key"] in self.ignored_excuse_keys]

    def _persist_ignored(self, previous: set[str]) -> bool:
        """Saves the ignore list; on failure restores ``previous`` everywhere.

        The list gates automatic excusing (the tray reads it from disk), so
        an ignore that only lives in memory would still get the lesson
        auto-excused a second time — which cannot be taken back. A failed
        save therefore undoes the change instead of pretending it held.
        """
        from .strings import S

        self.last_ignore_error = ""
        try:
            self.config.set("ignored_excuses", sorted(self.ignored_excuse_keys))
            self.config.save()
            return True
        except Exception as exc:  # noqa: BLE001 - reported, memory rolled back
            self.ignored_excuse_keys = set(previous)
            try:
                self.config.set("ignored_excuses", sorted(previous))
            except Exception:  # noqa: BLE001 - memory is what the UI shows
                pass
            self.last_ignore_error = S("ignore_save_failed")
            self.log(f"{self.last_ignore_error} ({type(exc).__name__}: {exc})")
            return False

    def _change_ignored(self, add=(), remove=()) -> bool:
        """Applies one ignore-list edit, saves it and repaints.

        Returns False when the save failed (nothing changed then, and
        ``last_ignore_error`` says why); True otherwise, even for a no-op.
        """
        previous = set(self.ignored_excuse_keys)
        self.ignored_excuse_keys.update(str(k) for k in add if k)
        self.ignored_excuse_keys.difference_update(str(k) for k in remove)
        if self.ignored_excuse_keys == previous:
            return True
        ok = self._persist_ignored(previous)
        if ok and add:
            self.tutorial_event("excuse_done")  # Ignore counts as handling it
        self._emit()
        return ok

    def ignore_excuse(self, task_or_key: dict | str) -> str:
        """Hides one task (already excused manually in Bakaláři).

        Returns the hidden key, or "" when nothing was hidden (see
        ``last_ignore_error`` for a failed save).
        """
        self.last_ignore_error = ""
        key = str(task_or_key.get("key", "") if isinstance(task_or_key, dict)
                  else task_or_key or "")
        if not key or not self._change_ignored(add=[key]):
            return ""
        return key

    def unignore_excuse(self, key: str) -> bool:
        return self._change_ignored(remove=[str(key or "")])

    def ignore_day(self, day_iso: str) -> list[str]:
        """Hides every pending task of one day. Returns the hidden keys
        ([] when there was nothing to hide or the save failed)."""
        self.last_ignore_error = ""
        day_iso = str(day_iso or "")
        added = [t["key"] for t in self._all_excuse_tasks()
                 if str(t.get("date", "")) == day_iso
                 and t["key"] not in self.ignored_excuse_keys]
        if not added or not self._change_ignored(add=added):
            return []
        return added

    def unignore_keys(self, keys: list[str]) -> bool:
        return self._change_ignored(remove=[str(k or "") for k in keys or []])

    def mark_excused(self, task: dict, template: str = "", sent: bool = False,
                       emit: bool = True) -> None:
        self.excuse_log.append({"key": task["key"], "label": task["label"],
                                "template": template, "sent": bool(sent)})
        if emit:
            self._emit()

    def submit_excuse(self, task: dict, page=None, template: str = "") -> bool:
        """Submits one excuse to Bakaláři in a background thread.

        Returns False when a submit for the task is already running or the
        task lacks the data needed to build a request. Marks the task only
        after the server confirms — never optimistically. ``template`` is
        the user-chosen excuse text (sent verbatim); empty falls back to
        the configured default template.
        """
        from .strings import S

        key = str((task or {}).get("key", ""))
        lock = getattr(self, "_flight_lock", None)
        if lock is None:
            lock = self._flight_lock = threading.Lock()
        with lock:
            if not key or key in self.sending_excuses:
                return False
        day_iso = str((task or {}).get("date", ""))
        period = (task or {}).get("period")
        try:
            day_label = date.fromisoformat(day_iso).strftime("%d.%m.%Y")
        except ValueError:
            day_label = ""
        if not day_label or period is None:
            self.log(f"{S('excuse_failed')}: {task.get('label', key)}")
            return False
        if self.demo_mode and not self._has_credentials():
            self.log(S("need_credentials"))
            try:
                from .overlays import snack as _snack

                if page is not None:
                    _snack(page, S("need_credentials"))
            except Exception:
                pass
            return False
        try:
            period_int = int(period)
        except (TypeError, ValueError):
            self.log(f"{S('excuse_failed')}: {task.get('label', key)}")
            return False
        kind = str((task or {}).get("kind", "short")).lower()
        excuse = {
            # "early" (generic předčasný odchod) uses the same hour-based
            # web form as "soon" (brzký odchod); "income" is late arrival.
            "type": "soon" if kind in ("soon", "early") else ("income" if kind == "late" else "days and hours"),
            "starting_day": day_label,
            "ending_day": day_label,
            "starting_lesson": period_int,
            "ending_lesson": period_int,
        }
        with lock:
            if key in self.sending_excuses:
                return False
            self.sending_excuses.add(key)
        self.current_step = S("excuse_sending")
        self.log(f"{S('excuse_sending')}: {task.get('label', key)}")
        self.tutorial_event("excuse_done")
        self._emit()

        if page is not None:
            self.bind_page(page)
        custom_text = str(template or "").strip() or None

        def _on_sent() -> None:
            self.mark_excused(task, template=str(template or ""), sent=True)

        self._spawn(
            lambda: self._excuse_worker(
                [(excuse, custom_text)], key, str(task.get("label", key)), _on_sent,
                "excuse", {"label": str(task.get("label", key))}, page),
            name="strakalari-excuse")
        return True

    def day_fully_absent(self, day_iso: str) -> bool:
        """True when every lesson of the day that took place is a pending absence.

        Only then does a whole-day ("pure days") excuse describe what
        happened; a day the student partly attended, or was only late
        for, needs lesson-level excuses instead.
        """
        from strakalari.core.models import Lesson

        try:
            day = date.fromisoformat(str(day_iso))
        except ValueError:
            return False
        tasks = [t for t in self.excuse_tasks() if str(t.get("date", "")) == str(day_iso)]
        absent_keys = {t["key"] for t in tasks if t.get("kind") == "short"}
        lessons = [
            Lesson.from_legacy(raw, day=day.strftime("%d.%m.%Y"))
            for raw in (self.timetable().get(day.strftime("%d.%m.%Y"), []) or [])
            if isinstance(raw, dict)
        ]
        held = [ls for ls in lessons if ls.status != "cancelled"]
        if not held or not absent_keys:
            return False
        return all(f"{day.isoformat()}|{ls.period}|{ls.subject}" in absent_keys for ls in held)

    def day_excuse_plan(self, day_iso: str) -> list[dict]:
        """The excuses that cover every pending task of one day.

        A fully absent day is one "pure days" excuse. Otherwise consecutive
        absent lessons become "days and hours" ranges, late arrivals
        "income" and early leaves "soon" (the same shapes automatic
        excusing sends). [] when the day has no pending task.
        """
        try:
            day_label = date.fromisoformat(str(day_iso)).strftime("%d.%m.%Y")
        except ValueError:
            return []
        tasks = [t for t in self.excuse_tasks() if str(t.get("date", "")) == str(day_iso)]
        if not tasks:
            return []
        if self.day_fully_absent(day_iso):
            return [{"type": "pure days", "starting_day": day_label, "ending_day": day_label}]
        plan: list[dict] = []
        absent: list[int] = []
        for task in tasks:
            try:
                period = int(task.get("period"))
            except (TypeError, ValueError):
                continue
            kind = str(task.get("kind", "short")).lower()
            if kind == "short":
                absent.append(period)
                continue
            plan.append({"type": "soon" if kind in ("soon", "early") else "income",
                         "starting_day": day_label, "ending_day": day_label,
                         "starting_lesson": period, "ending_lesson": period})
        run: list[int] = []
        for period in sorted(set(absent)):
            if run and period != run[-1] + 1:
                plan.append({"type": "days and hours", "starting_day": day_label,
                             "ending_day": day_label, "starting_lesson": run[0],
                             "ending_lesson": run[-1]})
                run = []
            run.append(period)
        if run:
            plan.append({"type": "days and hours", "starting_day": day_label,
                         "ending_day": day_label, "starting_lesson": run[0],
                         "ending_lesson": run[-1]})
        return plan

    def submit_day_excuse(self, day_iso: str, template: str = "", page=None) -> bool:
        """Excuses every pending task of one day in one browser session.

        A fully absent day goes out as ONE whole-day request; a partly
        attended day as lesson ranges (see :meth:`day_excuse_plan`) — a
        whole-day excuse would claim lessons the student attended.
        ``template`` is used for the absence excuses; late arrivals and
        early leaves get their configured default text.
        """
        from .strings import S

        try:
            day_label = date.fromisoformat(str(day_iso)).strftime("%d.%m.%Y")
        except ValueError:
            return False
        key = f"day|{day_iso}"
        if key in self.sending_excuses:
            return False
        plan = self.day_excuse_plan(day_iso)
        if not plan:
            return False
        if self.demo_mode and not self._has_credentials():
            self.log(S("need_credentials"))
            try:
                from .overlays import snack as _snack

                if page is not None:
                    _snack(page, S("need_credentials"))
            except Exception:
                pass
            return False
        self.sending_excuses.add(key)
        self.current_step = S("excuse_sending")
        self.log(f"{S('excuse_sending')}: {day_label}")
        self.tutorial_event("excuse_done")
        self._emit()

        if page is not None:
            self.bind_page(page)
        custom_text = str(template or "").strip() or None
        # Snapshot now: once sent, the history hides these tasks.
        day_tasks = [t for t in self.excuse_tasks() if str(t.get("date", "")) == str(day_iso)]
        jobs = [(excuse, custom_text if excuse["type"] in ("pure days", "days and hours") else None)
                for excuse in plan]

        def _on_sent() -> None:
            for task in day_tasks:
                self.mark_excused(task, template=str(template or ""), sent=True,
                                  emit=False)

        self._spawn(
            lambda: self._excuse_worker(
                jobs, key, day_label, _on_sent,
                "excuse (whole day)", {"day": str(day_iso), "excuses": len(jobs)}, page),
            name="strakalari-excuse-day")
        return True

    def _excuse_worker(self, jobs: list, key: str, label: str, on_sent,
                       operation: str, extra: dict, page) -> None:
        """Background part of a manual excuse send (one lesson or one day).

        ``jobs`` are ``(excuse, custom_text or None)`` pairs sent in one
        browser session. Every outcome is visible: sent / already excused /
        dry run / failed go to the log and a snackbar, a failure also to a
        notification (the reason is in the log lines above it), a crash to
        the error dialog.
        """
        from .strings import S

        outcomes: list[str] = []
        dry = False
        crashed = False
        try:
            from strakalari.core.automation import Strakalari

            app = Strakalari(on_log=self._core_log, start_browser=True)
            try:
                dry = (getattr(app, "excuse_mode", "") == "dry_run")
                send = getattr(app, "send_excuse_outcome", None)
                for excuse, custom_text in jobs:
                    if callable(send):
                        outcomes.append(str(send(dict(excuse), custom_text)))
                    else:  # minimal clients (tests): bool-only API
                        sent = bool(app.excuse_single(dict(excuse), custom_text=custom_text))
                        outcomes.append(("dry_run" if dry else "sent") if sent else "failed")
            finally:
                try:
                    app.close()
                except Exception as exc:  # noqa: BLE001 - teardown only
                    print(f"Warning: browser close failed: {exc}")
        except Exception as exc:  # noqa: BLE001 - report, don't crash
            crashed = True
            self._worker_log(f"{S('excuse_failed')}: {type(exc).__name__}: {exc}".splitlines()[0][:200])
            self.report_error(operation, exc, extra=extra)
        except BaseException:
            self.sending_excuses.discard(key)
            self._emit()
            raise
        self.sending_excuses.discard(key)
        total = len(jobs)
        done = sum(1 for o in outcomes if o in ("sent", "covered"))
        ok = not crashed and total > 0 and done == total
        if dry and outcomes and all(o == "dry_run" for o in outcomes):
            # Dry run simulates success without sending — never mark sent.
            msg = S("excuse_dry_run")
        elif ok:
            on_sent()
            msg = (S("excuse_already_covered") if all(o == "covered" for o in outcomes)
                   else S("excuse_sent"))
        elif crashed:
            msg = S("excuse_failed")
        else:
            msg = S("excuse_failed")
            if total > 1 and done:
                msg = f"{msg} ({S('excuse_day_result').format(ok=done, n=total)})"
            self._notify("automation_failed", f"{msg}: {label}")
        if not crashed:
            self._worker_log(f"{msg}: {label}")
        if page is not None:
            try:
                from .overlays import snack as _snack

                _snack(page, msg)
                page.update()
            except Exception as exc:  # noqa: BLE001 - the log line above stands
                print(f"Warning: excuse snackbar failed: {exc}")
        self._emit()
