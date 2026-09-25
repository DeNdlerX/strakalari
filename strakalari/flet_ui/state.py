"""Application state for the Flet UI.

Loads real data (config + ``data_cache.json``) when present. With no
cached data every accessor returns empty (no fictional demo rows) so
fresh installs show an empty state prompting a refresh. Views read
from here; writes (settings, excuse outbox, planned skips) go through
here too.
"""

from __future__ import annotations

import threading
from datetime import datetime
from typing import Any, Callable

from strakalari.core.cache import describe_cache, load_data_cache
from strakalari.core.config import ConfigManager
from strakalari.core.i18n import set_language
from strakalari.core.models import canonical_day_key
from strakalari.core.planned_skips import (
    cancels_lunch,
    entry_days,
    load_planned_skips,
)

from .state_activity import ActivityMixin
from .state_excuses import ExcuseTasksMixin
from .state_lunches import LunchMixin
from .state_marks import MarksMixin
from .state_planner import PlannerMixin
from .state_tutorial import TutorialMixin
from .theme import Tokens, normalize_mode, tokens


# Flet raises "An attempt to fetch destroyed session" when a background
# emit fires after the window was closed — benign (nothing left to
# paint), so it must stay silent instead of printing like a real bug.
_DEAD_SESSION_NEEDLES = ("destroyed session", "fetch destroyed")


def _canonical_orders(orders: dict) -> dict[str, str]:
    """``{DD.MM.YYYY: meal_id}`` — Strava day spellings collapsed."""
    return {canonical_day_key(k): str(v) for k, v in orders.items() if v}


class AppState(ExcuseTasksMixin, LunchMixin, MarksMixin, PlannerMixin, ActivityMixin,
               TutorialMixin):
    def __init__(self) -> None:
        self.config = ConfigManager()
        self.data: dict = load_data_cache()
        # Bumped whenever ``data`` is replaced: the cache key for anything
        # derived from it (an ``id()`` can be reused once the old dict is freed).
        self.data_rev: int = 0
        self._listeners: list[Callable[[], None]] = []
        # Progress ticks from the background refresh worker (~1 Hz). A
        # separate channel from _listeners so the Shell can repaint only
        # the topbar for ticks (preserving half-typed settings inputs)
        # while user actions still trigger a full render through _emit.
        self._progress_listeners: list[Callable[[], None]] = []
        # Called after every config save, including quiet ones that skip
        # the re-render (e.g. the Shell syncing the scheduler interval).
        self._config_listeners: list[Callable[[], None]] = []
        # Per-thread "don't re-render" flag set by save_quiet(): a quiet
        # settings save on the UI thread must not swallow a background
        # worker's emit that happens at the same moment.
        self._quiet = threading.local()
        # Flet page bound by the Shell. Background workers must run via
        # ``page.run_thread`` (the page's executor) — a raw
        # ``threading.Thread`` leaves ``page.update()`` painting nothing
        # until the next UI-thread render (e.g. navigation), which is why
        # the status pill stayed stale on "refreshing".
        self._page: Any = None
        # Guards the check-then-set flight flags below (refresh_running,
        # testing, order_running, ai_running): the scheduler thread and the
        # UI thread could otherwise both pass the guard and spawn twins.
        self._flight_lock = threading.Lock()
        # No cached absence/timetable yet (fresh install) — views show an
        # empty state prompting a refresh instead of fictional rows.
        self.demo_mode = not bool(self.data.get("absence") or self.data.get("timetable"))
        # Canonical normalize_planned_entry shape.
        self.planned_skips: list[dict] = load_planned_skips(self.config.data)
        self.cancelled_lunches: set[str] = set()  # day strings "DD.MM.YYYY"
        for entry in self.planned_skips:
            if not cancels_lunch(entry):
                continue  # the user chose to keep the lunch on this day off
            for day in entry_days(entry):
                self.cancelled_lunches.add(day.strftime("%d.%m.%Y"))
        self.ignored_excuse_keys: set[str] = set()
        try:
            stored_ignored = self.config.get("ignored_excuses", [])
            if isinstance(stored_ignored, list):
                self.ignored_excuse_keys = {
                    str(k) for k in stored_ignored if str(k or "").strip()
                }
        except Exception:
            pass
        # Why the last ignore/restore did not stick (failed save), or "".
        self.last_ignore_error: str = ""
        self.excuse_log: list[dict] = []  # sent excuses (undo window)
        self.sending_excuses: set[str] = set()  # task keys with a submit in flight
        self.order_running: bool = False  # Strava submit in flight
        self.ai_running: bool = False  # AI lunch recommendation in flight
        self.orders: dict[str, str] = {}  # day -> meal_id
        cached_orders = self.data.get("strava_ordered")
        if isinstance(cached_orders, dict):
            self.orders.update(_canonical_orders(cached_orders))
        # What the Strava WEB reports as ordered (refreshed on cache reload
        # and after a successful submit). ``orders`` is the local working
        # copy — comparing the two shows "to send" vs "ordered" states.
        self.web_orders: dict[str, str] = dict(self.orders)
        # A planned day off owns its lunch (same rule as reload_cache): the
        # web meal must not stay the local pick, or Send would re-confirm
        # it instead of cancelling it.
        for day in self.cancelled_lunches:
            if "&-1&" not in str(self.orders.get(day, "&-1&")):
                self.orders.pop(day, None)
        # Days with an unsubmitted local pick. On reload the web truth
        # overwrites every other day, but pending picks survive it.
        self.pending_orders: set[str] = set()
        self.timetable_monday_iso: str | None = None  # week nav persists across renders
        self.show_stable_timetable: bool = False  # template view toggle (in-memory)
        self.timetable_view: str = str(self.get("timetable_view", "table") or "table")
        if self.timetable_view not in ("table", "list"):
            self.timetable_view = "table"
        # -- activity / automation status -------------------------------------
        self.status: str = "idle"  # idle | working | error
        self.current_step: str = ""
        self.log_lines: list[str] = []
        self.runs: list[dict] = []  # {started, finished, ok, scope, detail}
        self.last_error: dict | None = None  # full diagnostics for the error popup
        self.error_dialog_pending: bool = False  # Shell shows + acknowledges it
        self.refresh_running: bool = False
        self.cancel_requested: bool = False
        self.last_test: dict = {}  # {service, ok, message, at}
        self.testing: str = ""  # service currently being tested, "" when idle
        self.scheduler_last_run: datetime | None = None
        self.pending_route: str | None = None  # view asking the shell to navigate
        self._refresh_tokens()
        self.lunch_hidden: set[str] = set()  # meal_ids hidden by the filter
        self.lunch_reasons: dict[str, str] = {}
        self.lunch_prefs: str = ""
        # -- per-render UI memory (in-memory only, survives re-renders) -----
        self.picked_templates: dict[str, int] = {}  # excuse task/day key -> template idx
        self.settings_section: str = "accounts"  # active settings category
        self.lunches_sidebar_open: bool = True  # AI + blacklist side panel
        self.show_past_calendar: bool = False  # past free days hidden by default
        self.show_past_lunches: bool = False  # past menu days hidden by default
        self.drafts: dict[str, str] = {}  # unsaved field text (no re-render on typing)
        self.wizard_step: int = 0  # first-run wizard page index (in-memory)
        self.tutorial: tuple[str, int] | None = None  # active (tour id, step), in-memory
        self.wizard_dismissed: bool = False  # "skip for now" for this session
        self.wizard_shown: bool = False  # set once the Shell shows the wizard (gates automation)
        self.wizard_browser_status: str = ""  # "", "working", "done", "ready", "error:…"
        self.wizard_browser_progress: float | None = None  # overall 0..1
        self.wizard_browser_label: str = ""  # current component, e.g. Chrome
        self.wizard_browser_pos: tuple = (0, 0)  # (current file, total files)
        self.wizard_browser_phase: str = ""  # "download" / "extract" (current file)
        # Login test queued on Continue while Chrome was still downloading:
        # (service, step), run when the download finishes.
        self.wizard_pending_test: tuple | None = None
        # Fingerprints of wizard step values that already passed a live
        # test (service -> fingerprint). The wizard's Continue re-tests
        # whenever the fields changed since the last pass.
        self.wizard_verified: dict[str, str] = {}
        self._last_log_emit: float = 0.0  # throttles worker-log re-renders
        self._scroll_cols: dict = {}  # scrollable containers reused per key
        self._scroll_offsets: dict[str, float] = {}  # last user offset per key
        # -- update check (GitHub releases, in-memory + disk cache) ---------
        self.update_info: dict | None = None  # {version, url, ...} or None
        self.update_check_running: bool = False
        self.update_dismissed: str = ""  # version hidden for this session
        try:
            from strakalari.core import update as _update_mod

            cached = _update_mod.load_cached(self.update_channel)
            if isinstance(cached, dict) and cached.get("version"):
                if _update_mod.update_available(cached):
                    self.update_info = cached
        except Exception:
            pass

    # -- reactive ------------------------------------------------------
    def _claim_flight(self, name: str) -> bool:
        """Atomically test-and-set a flight flag. True when claimed.

        ``getattr``-based: hand-rolled test doubles that bypass
        ``__init__`` still get a working lock instead of AttributeError.
        """
        lock = getattr(self, "_flight_lock", None)
        if lock is None:
            lock = self._flight_lock = threading.Lock()
        with lock:
            if getattr(self, name, False):
                return False
            setattr(self, name, True)
            return True

    def _release_flight(self, name: str) -> None:
        """Idempotent release of a flag claimed via :meth:`_claim_flight`.

        Setting an already-released flag is a no-op, so double release
        (early-return path + worker teardown) is always safe.
        """
        try:
            setattr(self, name, False)
        except Exception:
            pass

    def listen(self, callback: Callable[[], None]) -> None:
        if callback not in self._listeners:
            self._listeners.append(callback)

    def listen_config(self, callback: Callable[[], None]) -> None:
        if callback not in self._config_listeners:
            self._config_listeners.append(callback)

    def _emit(self) -> None:
        if getattr(self._quiet, "active", False):
            return
        for callback in list(self._listeners):
            try:
                callback()
            except Exception as exc:  # noqa: BLE001 - one bad listener must not break UI
                try:
                    _msg = str(exc)
                except Exception:
                    _msg = ""
                if any(n in _msg for n in _DEAD_SESSION_NEEDLES):
                    continue
                print(f"Warning: state listener failed: {exc}")

    def listen_progress(self, callback: Callable[[], None]) -> None:
        if callback not in self._progress_listeners:
            self._progress_listeners.append(callback)

    def _emit_progress(self) -> None:
        for callback in list(self._progress_listeners):
            try:
                callback()
            except Exception as exc:  # noqa: BLE001 - one bad listener must not break UI
                try:
                    _msg = str(exc)
                except Exception:
                    _msg = ""
                if any(n in _msg for n in _DEAD_SESSION_NEEDLES):
                    continue
                print(f"Warning: state progress listener failed: {exc}")

    def bind_page(self, page: Any) -> None:
        """Binds the Flet page so workers run on its executor."""
        self._page = page

    def _spawn(self, target: Callable, args: tuple = (), name: str = "") -> None:
        """Runs ``target`` on the page executor when bound, else a thread.

        ``page.run_thread`` associates the worker with the page so that the
        ``page.update()`` inside ``Shell.render`` (via ``_emit``) actually
        paints. Falls back to ``threading.Thread`` when no page is bound
        (tests, headless use).
        """
        run_thread = getattr(self._page, "run_thread", None)
        if callable(run_thread):
            try:
                run_thread(target, *args)
                return
            except Exception:
                pass
        import threading

        threading.Thread(target=target, args=tuple(args), name=name or None, daemon=True).start()

    def _refresh_tokens(self) -> None:
        import dataclasses
        import os

        forced = os.environ.get("STRAKALARI_THEME", "")
        mode = forced if forced in ("dark", "light") else self.config.get("theme", "dark")
        self.tok: Tokens = tokens(mode)
        if bool(self.config.get("compact_density", False)):
            self.tok = dataclasses.replace(self.tok, pad=10, gap=8)
        try:
            set_language(self.config.get("language", "cs"))
        except Exception:
            pass

    # -- config ---------------------------------------------------------
    def get(self, key: str, default: Any = None) -> Any:
        try:
            return self.config.get(key, default)
        except Exception:
            return default

    def save(self, updates: dict) -> bool:
        """Persists config updates. Returns True only if the write succeeded.

        Callers that report success to the user (snackbars) must branch on
        the return value — a failed write must never toast "saved".
        """
        ok = True
        for key, value in updates.items():
            try:
                self.config.set(key, value)
            except Exception as exc:  # noqa: BLE001 - skip invalid, never store raw
                print(f"Warning: ignoring invalid config update {key!r}: {exc}")
                ok = False
        try:
            self.config.save()
        except Exception as exc:  # noqa: BLE001 - report but keep running
            print(f"Warning: could not save config: {exc}")
            return False
        self._refresh_tokens()
        for callback in list(self._config_listeners):
            try:
                callback()
            except Exception as exc:  # noqa: BLE001 - never break a save
                print(f"Warning: config listener failed: {exc}")
        self._emit()
        return ok

    def save_quiet(self, updates: dict) -> bool:
        """Persists like ``save`` but without re-rendering the screen.

        For edits whose control already shows the new value (settings
        fields, switches, dropdowns). A full re-render there replaces every
        control mid-click: the click that caused the blur-save lands on a
        control that no longer exists (it needs a second click), the
        focused field loses focus and the page jumps.
        """
        self._quiet.active = True
        try:
            return bool(self.save(updates))
        finally:
            self._quiet.active = False

    def automation_paused(self) -> bool:
        """True when every automatic send / order is paused (tray or here)."""
        import json

        from strakalari.core.refresh import automation_paused

        # The tray toggles it in its own process: read the file so this
        # window never shows a stale state (falls back to memory).
        try:
            with open(self.config.config_path, "r", encoding="utf-8") as f:
                on_disk = json.load(f)
            if isinstance(on_disk, dict) and "automation_paused" in on_disk:
                return automation_paused(on_disk)
        except (OSError, ValueError):
            pass
        return automation_paused(self.config.data)

    def set_automation_paused(self, paused: bool, page=None) -> bool:
        ok = bool(self.save({"automation_paused": bool(paused)}))
        if not ok:
            from .strings import S

            self.log(S("save_failed"))
        elif page is not None:
            try:
                from .overlays import snack
                from .strings import S

                snack(page, S("automation_paused_banner") if paused else S("automation_resumed"))
            except Exception as exc:  # noqa: BLE001 - toast only
                print(f"Warning: snackbar failed: {exc}")
        return ok

    def set_theme(self, mode: str) -> bool:
        return bool(self.save({"theme": normalize_mode(mode)}))

    def set_language(self, lang: str) -> bool:
        return bool(self.save({"language": lang if lang in ("cs", "en") else "cs"}))

    def density_compact(self) -> bool:
        return bool(self.get("compact_density", False))

    # -- data ------------------------------------------------------------
    @property
    def updated_label(self) -> str:
        if self.demo_mode:
            from .strings import S

            return S("no_data")
        try:
            return describe_cache(self.data, float(self.get("cache_ttl_hours", 24)))
        except Exception:
            return self.data.get("last_updated", "")

    def absence(self) -> dict[str, float]:
        data = self.data.get("absence") if not self.demo_mode else None
        if isinstance(data, dict) and data:
            out: dict[str, float] = {}
            for subject, pct in data.items():
                try:
                    out[str(subject)] = float(pct)
                except (TypeError, ValueError):
                    continue
            if out:
                return out
        return {}

    def absence_details(self) -> dict[str, dict]:
        data = self.data.get("absence_details") if not self.demo_mode else None
        if isinstance(data, dict) and data:
            return {str(k): v for k, v in data.items() if isinstance(v, dict)}
        return {}

    def subject_directory(self) -> dict[str, str]:
        data = self.data.get("subject_directory") if not self.demo_mode else None
        if isinstance(data, dict) and data:
            return {str(k): str(v) for k, v in data.items() if k and v}
        return {}

    def tracked_subjects(self) -> set[str] | None:
        """Canonical absence-tracked subjects (directory names), or None.

        None means unknown (directory never fetched) — callers must not
        filter then. An empty directory dict is also unknown, never an
        assertion that nothing is tracked.
        """
        directory = self.subject_directory()
        if not directory:
            return None
        from strakalari.core.forecast import canon_subject

        return {canon_subject(name) for name in directory}

    def grades(self) -> dict[str, list]:
        data = self.data.get("grades") if not self.demo_mode else None
        if isinstance(data, dict) and data:
            return data
        return {}

    def timetable(self) -> dict:
        data = self.data.get("timetable") if not self.demo_mode else None
        if isinstance(data, dict) and data:
            # Real cache keys look like "7.9.2026 (pondělí)"; normalize to
            # "DD.MM.YYYY" so today-lookups and week grouping just work.
            normalized: dict[str, list] = {}
            for day_key, lessons in data.items():
                canon = canonical_day_key(day_key)
                if isinstance(lessons, list):
                    normalized.setdefault(canon, []).extend(lessons)
            # Drop rows that failed to parse into a real day.
            return {k: v for k, v in normalized.items() if v is not None}
        return {}

    def food(self) -> dict[str, dict[str, str]]:
        from strakalari.core.models import canonical_day_key

        data = None
        if not self.demo_mode:
            data = self.data.get("food") or self.data.get("strava_meals")
        if isinstance(data, dict) and data:
            # Same normalization as timetable(): "7.9.2026", "07.09.2026"
            # and "7. 9. 2026" must all hit today's lookup.
            normalized: dict[str, dict[str, str]] = {}
            for day_key, meals in data.items():
                if not isinstance(meals, dict):
                    continue
                normalized.setdefault(canonical_day_key(day_key), {}).update(meals)
            if normalized:
                return normalized
        return {}

    # -- school calendar (preset + user overrides) -------------------------
    # -- lunch ordering cutoff (previous business day at set time) ---------
    # -- forecast ----------------------------------------------------------
    # -- planner accept flow -------------------------------------------------
    # -- in-memory UI helpers (no config writes) ------------------------------
    def draft(self, key: str, fallback: str = "") -> str:
        """Unsaved field text that survives background re-renders."""
        if key in self.drafts:
            return self.drafts[key]
        return fallback

    def set_draft(self, key: str, value: str) -> None:
        self.drafts[key] = str(value or "")

    def clear_drafts(self, prefix: str = "") -> None:
        if prefix:
            for key in [k for k in self.drafts if k.startswith(prefix)]:
                del self.drafts[key]
        else:
            self.drafts.clear()

    def set_settings_section(self, section: str) -> None:
        self.settings_section = section
        # Password / key fields clear on leave: returning later shows the
        # "saved — enter a new one" hint instead of the typed value.
        for key in ("acc:bakalari_password", "acc:strava_password", "ai:key"):
            self.drafts.pop(key, None)
        self._emit()

    def set_lunches_sidebar(self, open: bool) -> None:
        """Shows/hides the AI + blacklist side panel (in-memory)."""
        self.lunches_sidebar_open = bool(open)
        self._emit()

    def set_show_past_calendar(self, show: bool) -> None:
        """Shows/hides already-happened days in the school calendar (in-memory)."""
        self.show_past_calendar = bool(show)
        self._emit()

    def set_show_past_lunches(self, show: bool) -> None:
        """Shows/hides already-past days on the lunch menu (in-memory)."""
        self.show_past_lunches = bool(show)
        self._emit()

    def strava_enabled(self) -> bool:
        """True unless the user turned the Strava integration off."""
        try:
            return bool(self.get("use_strava", True))
        except Exception:
            return True

    # -- refresh --------------------------------------------------------------
    def reload_cache(self) -> None:
        self.data = load_data_cache()
        self.data_rev += 1
        self.demo_mode = not bool(self.data.get("absence") or self.data.get("timetable"))
        cached_orders = self.data.get("strava_ordered")
        if isinstance(cached_orders, dict):
            # Strava may spell days "4.9.2026"; every lookup here (menu,
            # planned skips, pending picks) uses canonical "04.09.2026".
            cached_orders = {canonical_day_key(k): v for k, v in cached_orders.items()}
            for day, meal in cached_orders.items():
                day_label, meal_id = str(day), str(meal or "")
                if day_label in self.cancelled_lunches:
                    # A planned skip owns this day: never resurrect a pick
                    # that would suppress its deorder on submit. A staged
                    # deorder id survives (it IS the queued cancel).
                    staged = self.orders.get(day_label)
                    if staged is not None and "&-1&" in str(staged):
                        continue
                    self.orders.pop(day_label, None)
                    continue
                if day_label in self.pending_orders:
                    # Unsubmitted local pick survives the refresh.
                    self.orders.setdefault(day_label, meal_id)
                elif meal_id:
                    # Web truth wins over any stale local pick.
                    self.orders[day_label] = meal_id
                else:
                    self.orders.pop(day_label, None)
            # The web truth is whatever the cache reports.
            self.web_orders = {str(k): str(v) for k, v in cached_orders.items() if v}
        self._emit()

    # -- activity log ------------------------------------------------------
    # -- browser visibility (user-facing toggle over ``hide_window``) ------
    @property
    def show_browser(self) -> bool:
        # Default matches the shipped configs (hide_window: true).
        return not bool(self.get("hide_window", True))

    # -- timetable view preference ------------------------------------------
    def set_timetable_view(self, view: str) -> None:
        if view not in ("table", "list"):
            return
        self.timetable_view = view
        self.save({"timetable_view": view})

    # -- update check (GitHub releases, background, never blocks UI) --------
    # -- background refresh (real fetch, read-only) --------------------------
    def _has_credentials(self) -> bool:
        try:
            from strakalari.core.config import has_valid_credentials

            has_bak, _has_strava = has_valid_credentials(self.config.data)
            return bool(has_bak)
        except Exception:
            return False

    def _has_strava_credentials(self) -> bool:
        """True when a Strava (canteen) login is configured."""
        try:
            from strakalari.core.config import has_valid_credentials

            _has_bak, has_strava = has_valid_credentials(self.config.data)
            return bool(has_strava)
        except Exception:
            return False

    def _has_any_credentials(self) -> bool:
        """True when at least one service (Bakaláři or Strava) is configured."""
        return bool(self._has_credentials() or self._has_strava_credentials())

    # -- automatic runs inside refresh (auto modes only) --------------------
    # -- first-run wizard (in-memory step, gating on real credentials) --------
    def needs_setup(self) -> bool:
        """True on fresh installs: no valid login (Bakaláři or Strava) and not skipped."""
        if self.wizard_dismissed:
            return False
        return not self._has_any_credentials()

    @property
    def setup_pending(self) -> bool:
        """True while the first-run wizard owns the screen.

        Covers fresh installs (no valid credentials) AND mid-wizard
        runs where step 2 already saved the login but the remaining
        steps are not done. Automation must wait until the wizard is
        finished or dismissed.
        """
        if self.wizard_dismissed:
            return False
        return bool(self.wizard_shown or self.needs_setup())

    def dismiss_wizard(self) -> None:
        self.wizard_dismissed = True
        self._emit()

    def wizard_goto(self, step: int) -> None:
        self.wizard_step = max(0, min(7, int(step)))
        self._emit()

    def wizard_finished(self) -> None:
        self.wizard_dismissed = True
        self.wizard_step = 0
        for key in [k for k in self.drafts if k.startswith("wiz:")]:
            self.drafts.pop(key, None)
        self.wizard_verified = {}
        self._emit()

    # -- connection test ------------------------------------------------------
    # -- lunch ordering -------------------------------------------------------
    # -- AI lunch recommendation (background, same pattern as orders) ---------
    # -- lunch filter (persists across full re-renders) -------------------------
    # -- timetable week nav (persists across full re-renders) ------------------
    _TIMETABLE_SCROLL_KEYS = ("timetable:table", "timetable:list")

    def _reset_timetable_scroll(self) -> None:
        """Drops saved offsets + parks live scrollers at 0 for week switches.

        The grid/body scrollers are reused across weeks (same container
        object per key), so without this the new week opens mid-scrolled
        at the old week's pixel offset.
        """
        try:
            offsets = self.__dict__.get("_scroll_offsets")
            if isinstance(offsets, dict):
                for _key in self._TIMETABLE_SCROLL_KEYS:
                    offsets.pop(_key, None)
        except Exception:
            pass
        try:
            cols = self.__dict__.get("_scroll_cols") or {}
            run_task = getattr(getattr(self, "_page", None), "run_task", None)
            if not callable(run_task):
                return
            for _key in self._TIMETABLE_SCROLL_KEYS:
                col = cols.get(_key)
                if not callable(getattr(col, "scroll_to", None)):
                    continue

                async def _one(_c=col) -> None:
                    try:
                        await _c.scroll_to(offset=0)
                    except Exception:
                        pass

                try:
                    run_task(_one)
                except Exception:
                    pass
        except Exception:
            pass

    def set_timetable_monday(self, monday_iso: str | None) -> None:
        if self.timetable_monday_iso == monday_iso:
            return
        self.timetable_monday_iso = monday_iso
        self._reset_timetable_scroll()
        self._emit()

    def set_show_stable(self, show: bool) -> None:
        """Toggles the 'Stálý' template view (in-memory, like week nav)."""
        show = bool(show)
        if bool(self.show_stable_timetable) == show:
            return
        self.show_stable_timetable = show
        self._reset_timetable_scroll()
        self._emit()

    def go_timetable_week(self, monday_iso: str | None) -> None:
        """Atomic week switch: stable view off + new week, one emit.

        Separate ``set_show_stable(False)`` + ``set_timetable_monday(...)``
        calls rebuild the whole page twice per click (visible flicker);
        this sets both fields before the single ``_emit``. A no-op target
        (same week, already out of stable view) emits nothing.
        """
        changed = False
        if bool(self.show_stable_timetable):
            self.show_stable_timetable = False
            changed = True
        if self.timetable_monday_iso != monday_iso:
            self.timetable_monday_iso = monday_iso
            changed = True
        if not changed:
            return
        self._reset_timetable_scroll()
        self._emit()

    # -- food blacklist (JSON word list on disk) -------------------------------
    # -- navigation ----------------------------------------------------------
    def go(self, route: str) -> None:
        """Asks the shell to switch routes (views have no shell access)."""
        self.pending_route = route
        self._emit()
