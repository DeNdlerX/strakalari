import os
import json
import threading
from datetime import datetime, timedelta
from itertools import groupby
import random

from .config import _is_demo_history_item
from .excuse_history import (
    STORED_KEYS,
    base_excuse,
    excuse_covered,
    excuse_window_start,
    history_entries,
    history_lock,
    load_unconfirmed,
    merge_sent_excuses,
    normalize_history_item,
    resolve_unconfirmed,
    save_unconfirmed,
    unconfirmed_blocks,
    unconfirmed_entry,
)
from .helpers import _resolve_path, atomic_write_json, parse_date, extract_lesson_num, format_excuse_template, example_path_for, template_texts
from .i18n import t
from .models import absence_kind, is_cancel_notice

# Process-wide guard for log rotation + append: refresh threads, the tray
# scheduler and one-off runs can otherwise interleave or race a rotation.
_WRITE_LOCK = threading.Lock()


def _menu_selection(food_dict: dict, day: object) -> dict:
    """Menu selection for ``day``, tolerant to day-key spellings.

    The extractor emits raw keys (``4.9.2026``) while callers may pass
    the zero-padded form (``04.09.2026``) and vice versa — an exact
    ``.get`` reads either spelling as "not on the menu". Falls back to
    a canonical-day comparison before giving up with ``{}``.
    """
    try:
        if isinstance(food_dict, dict) and day in food_dict:
            sel = food_dict.get(day)
            if isinstance(sel, dict):
                return sel
    except Exception:
        pass
    try:
        from .models import canonical_day_key as _canon

        want = _canon(day)
        for key, sel in (food_dict or {}).items():
            try:
                if isinstance(sel, dict) and _canon(key) == want:
                    return sel
            except Exception:
                continue
    except Exception:
        pass
    return {}


def _ignored_points(ignored) -> set:
    """``{(date, period)}`` from UI ignore keys (``YYYY-MM-DD|period|subject``).

    Tuples ``(date, period)`` pass through. Unparseable keys are dropped.
    """
    points: set = set()
    for item in ignored or ():
        try:
            if isinstance(item, tuple) and len(item) == 2:
                day, period = item
            else:
                iso, period_s = str(item).split("|")[:2]
                day = datetime.strptime(iso.strip(), "%Y-%m-%d").date()
                period = period_s
            points.add((day.date() if isinstance(day, datetime) else day, int(period)))
        except (TypeError, ValueError):
            continue
    return points


def _store_ordered(ordered: dict, day, meal) -> None:
    """Sets ``ordered[day]``, dropping other spellings of the same day.

    Callers use canonical ``04.09.2026`` keys while the extractor may emit
    ``4.9.2026``; keeping both would leave a stale entry for that day.
    """
    try:
        from .models import canonical_day_key as _canon

        want = _canon(day)
        for key in [k for k in ordered if k != day and _canon(k) == want]:
            ordered.pop(key, None)
    except Exception:
        pass
    ordered[day] = meal


def _selection_holds(client, pick: dict) -> bool:
    """Live re-check that one applied pick still holds. Never raises.

    A day-level deorder (``&-1&``) is verified through the day's meals
    (none may read ordered) — the control's own label always reads
    ordered, so it cannot verify itself.
    """
    try:
        meal_id = str(pick.get("meal_id", ""))
        if "&-1&" in meal_id:
            meals = [m for m in pick.get("all_ids") or [] if "&-1&" not in str(m)]
            return all(not client._verified(m) for m in meals)
        return bool(client._verified(meal_id))
    except Exception:
        return False


class Strakalari:
    def __init__(
        self,
        config_file: str = "./config.json",
        user_agent: str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0",
        enc: str = "utf-8",
        on_log=None,
        config_data: dict = None,
        start_browser: bool = True,
    ):
        self.encoding = enc
        self.on_log = on_log

        from .config import ConfigManager
        from .helpers import encrypt
        self.config_manager = ConfigManager(config_path=config_file, encoding=enc)
        if config_data:
            # Overrides are stored verbatim under canonical names (no
            # aliases, no migration — pre-release, single user). Secrets
            # still get the same encryption ConfigManager.set applies.
            for k, v in config_data.items():
                if k in ("bakalari_password", "strava_password", "gemini_api_key") and v:
                    # Overrides carry plaintext secrets (e.g. the settings
                    # connection test); encrypt them like ConfigManager.set
                    # does so the *_encrypted flag stays truthful. Never
                    # re-encrypt a value that already is the stored
                    # ciphertext (mirrors the guard in ConfigManager.set).
                    if (self.config_manager.data.get(f"{k}_encrypted", False)
                            and self.config_manager.data.get(k) == v):
                        continue
                    self.config_manager.data[k] = encrypt(str(v))
                    self.config_manager.data[f"{k}_encrypted"] = True
                else:
                    self.config_manager.data[k] = v
        self.config_file = self.config_manager.config_path
        self.config_data = self.config_manager.data

        self.bakalari_url = self.config_data.get("bakalari_url", "")
        self.bakalari_username = self.config_data.get("bakalari_username", "")
        self.bakalari_password = self.config_data.get("bakalari_password", "")
        self.bakalari_password_encrypted = self.config_data.get("bakalari_password_encrypted", False)
        try:
            self.go_back_weeks = min(max(int(self.config_data.get("go_back_weeks", 4)), 0), 52)
        except (TypeError, ValueError):
            self.go_back_weeks = 4
        try:
            self.go_forward_weeks = min(max(int(self.config_data.get("go_forward_weeks", 1)), 0), 8)
        except (TypeError, ValueError):
            self.go_forward_weeks = 1
        try:
            self.excuse_delay_days = int(self.config_data.get("excuse_delay_days", 2))
        except (TypeError, ValueError):
            self.excuse_delay_days = 2

        self.strava_url = self.config_data.get("strava_url", "")
        # Same legacy read-aliases as StravaClient (read-only compat:
        # nothing writes strava_id / strava_user / strava_enable anymore).
        # Without them a legacy config passes the client login but fails
        # this gating and check_strava_login.
        self.strava_id = str(self.config_data.get("strava_canteen_id", "")
                             or self.config_data.get("strava_id", "") or "").strip()
        self.strava_username = self.config_data.get("strava_username", "") or self.config_data.get("strava_user", "")
        self.strava_password = self.config_data.get("strava_password", "")
        self.strava_password_encrypted = self.config_data.get("strava_password_encrypted", False)
        self.strava_enable = self.config_data.get("use_strava", self.config_data.get("strava_enable", True))
        self.strava_blacklist = _resolve_path(self.config_data.get("strava_blacklist", "./strava_blacklist.json"))

        self.excuse_mode = str(self.config_data.get("excuse_mode", "confirm")).lower()
        self.default_excuse_selection = str(self.config_data.get("default_excuse_selection", "first")).lower()
        self.strava_order_mode = str(self.config_data.get("strava_order_mode", "confirm")).lower()

        if self.excuse_mode not in ("auto", "confirm", "dry_run"):
            self.excuse_mode = "confirm"
        if self.strava_order_mode not in ("auto", "confirm", "dry_run"):
            self.strava_order_mode = "confirm"

        self.late_income_excuses = template_texts(self.config_data.get("late_income_excuses", []))
        self.left_soon_excuses = template_texts(self.config_data.get("left_soon_excuses", []))
        self.long_absence_excuses = template_texts(self.config_data.get("long_absence_excuses", []))
        self.short_absence_excuses = template_texts(self.config_data.get("short_absence_excuses", []))
        self.signature = self.config_data.get("your_signature", "")

        self.already_excused_file = _resolve_path(self.config_data.get("already_excused_file", "./already_excused_lessons.json"))
        self.logFile = _resolve_path(self.config_data.get("log_file", "./log.txt"))

        self.bm = None
        self.bakalari_client = None
        self.strava_client = None
        self.page = None

        if start_browser:
            from .browser_manager import BrowserManager
            is_maximized = self.config_data.get("maximize_window") in [True, "True", "true"]
            is_headless = self.config_data.get("hide_window", True) in [True, "True", "true"]
            self.bm = BrowserManager(user_agent, is_maximized, is_headless)
            self.page = self.bm.page

        from .bakalari_client import BakalariClient
        from .strava_client import StravaClient
        self.bakalari_client = BakalariClient(self.bm if self.bm else type('DummyBM', (), {'page': None})(), self.config_data, logger=self.write_log)
        self.strava_client = StravaClient(self.bm if self.bm else type('DummyBM', (), {'page': None})(), self.config_data, logger=self.write_log)

        self.logged_in = False
        # Cooperative cancellation flag (set by the GUI worker's cancel()).
        self.cancel_requested = False
        # Optional live predicate polled by the Bakalari week loop so a
        # cancel issued mid-fetch is honored (forwarded to the client).
        self.cancel_callback = None
        # True only after the Komens outbox was actually read this run.
        # The refresh pipeline never auto-excuses without it: the outbox
        # is the only record of excuses whose submit went unconfirmed.
        self.last_outbox_sync_ok = False
        self.last_excuse_failures = 0

    def _is_cancelled(self) -> bool:
        """True when the flag or the live cancel predicate fires."""
        if getattr(self, "cancel_requested", False):
            return True
        callback = getattr(self, "cancel_callback", None)
        if callable(callback):
            try:
                return bool(callback())
            except Exception:
                return False
        return False

    @property
    def timetableData(self):
        return self.bakalari_client.timetableData if self.bakalari_client else {}

    @property
    def stableBaseline(self):
        return getattr(self.bakalari_client, "stableBaseline", {}) if self.bakalari_client else {}

    @property
    def stable_complete(self):
        return bool(getattr(self.bakalari_client, "stable_complete", False)) if self.bakalari_client else False

    @property
    def stableTimetableData(self):
        return getattr(self.bakalari_client, "stableTimetableData", {}) if self.bakalari_client else {}

    @property
    def weekChanges(self):
        return getattr(self.bakalari_client, "weekChanges", []) if self.bakalari_client else []

    @property
    def substitutions(self):
        return getattr(self.bakalari_client, "substitutions", []) if self.bakalari_client else []

    @property
    def absenceDetails(self):
        return getattr(self.bakalari_client, "absenceDetails", {}) if self.bakalari_client else {}

    @property
    def subjectDirectory(self):
        return getattr(self.bakalari_client, "subjectDirectory", {}) if self.bakalari_client else {}

    @property
    def absencePercentages(self):
        return self.bakalari_client.absencePercentages if self.bakalari_client else {}

    @property
    def grades(self):
        return self.bakalari_client.grades if self.bakalari_client else {}

    @property
    def foodDict(self):
        return self.strava_client.foodDict if self.strava_client else {}

    @property
    def orderedDict(self):
        return self.strava_client.orderedDict if self.strava_client else {}

    def close(self):
        bm = getattr(self, "bm", None)
        if bm is not None:
            try:
                bm.close()
            except Exception as e:  # noqa: BLE001 - teardown; orphans are reaped on next start
                print(f"Warning: browser close failed: {type(e).__name__}: {e}")

    def _redact_log(self, message: str) -> str:
        """``message`` with stored passwords / API keys scrubbed out.

        Exception texts and Playwright call logs can echo a typed secret;
        log.txt is plain text on disk. The decrypted values are cached per
        stored ciphertexts, so a routine line costs a few ``in`` checks.
        """
        try:
            from .error_report import redact_values, secret_values

            cfg = getattr(self, "config_data", None) or {}
            key = tuple(str(cfg.get(k) or "") for k in
                        ("bakalari_password", "strava_password", "gemini_api_key"))
            cached = getattr(self, "_log_secrets", None)
            if cached is None or cached[0] != key:
                cached = (key, frozenset(secret_values(cfg)))
                self._log_secrets = cached
            return redact_values(message, cached[1]) if cached[1] else str(message)
        except Exception:  # noqa: BLE001 - fail closed: never write it raw
            return "(log line withheld: redaction failed)"

    def write_log(self, message: str):
        message = self._redact_log(message)
        try:
            with _WRITE_LOCK:
                # Rotation is guarded by an inter-process lock: the tray and
                # the UI are separate processes sharing this file. When the
                # lock is held elsewhere, skip rotation and just append.
                if os.path.exists(self.logFile) and os.path.getsize(self.logFile) > 2 * 1024 * 1024:
                    from .helpers import try_file_lock, release_file_lock
                    token = try_file_lock(self.logFile + ".lock")
                    if token is not None:
                        try:
                            old_log = self.logFile + ".old"
                            if os.path.exists(old_log):
                                os.remove(old_log)
                            os.rename(self.logFile, old_log)
                        except OSError:
                            pass
                        finally:
                            release_file_lock(token)
                # Timestamped so a log.txt sent with a bug report can be
                # lined up with the error report and told apart per run.
                stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                with open(self.logFile, "a", encoding=self.encoding) as f:
                    f.write(f"[{stamp}] {message}\n\n")
        except Exception as e:
            print(f"Warning: Could not write to log file: {e}")

        if callable(self.on_log):
            try:
                self.on_log(message)
            except Exception:
                pass

    def fetch_bakalari_data(self):
        if self.bakalari_client:
            self.bakalari_client.cancel_requested = self.cancel_requested
            self.bakalari_client.cancel_callback = self.cancel_callback
            self.bakalari_client.fetch_data()

    def fetch_strava_data(self):
        if self.strava_enable and self.strava_client:
            # Forward cancellation so Zrušit preempts the menu fetch mid-wait.
            self.strava_client.cancel_requested = self.cancel_requested
            self.strava_client.cancel_callback = self.cancel_callback
            self.strava_client.fetch_data()

    def strava_order_selected(self, orders_dict: dict, source: str = "manual") -> bool:
        """Applies ``{day: meal_id}`` on Strava and records every day's outcome.

        True only when every day went through (or, in ``dry_run``, every
        pick is on the menu). ``last_ordered_days`` lists the days that
        really changed on the web, even when another day failed.
        """
        self.last_ordered_days = set()
        #: True when Strava refused an order for lack of money (the rest of
        #: the meal orders were then not attempted).
        self.last_order_low_balance = False
        #: Days not attempted because the account ran out of money.
        self.last_unfunded_days = []
        self._order_report = {"skipped": [], "succeeded": [], "failed": [], "unfunded": []}
        ok = False
        try:
            ok = self._order_selected(orders_dict)
        finally:
            self._audit_orders(orders_dict, ok, source)
        return ok

    def _audit_orders(self, orders_dict: dict, ok: bool, source: str) -> None:
        if not orders_dict:
            return
        try:
            from . import audit

            dry = getattr(self, "strava_order_mode", "confirm") == "dry_run"
            placed = set(getattr(self, "last_ordered_days", None) or ())
            skipped = set(map(str, self._order_report.get("skipped", [])))
            unfunded = set(map(str, self._order_report.get("unfunded", [])))
            for day, meal in orders_dict.items():
                detail = {"day": str(day), "meal": str(meal),
                          "mode": self.strava_order_mode}
                if dry:
                    outcome = "dry_run" if ok else "failed"
                elif day in placed:
                    outcome = "sent"
                elif str(day) in unfunded:
                    outcome = "skipped"
                    detail["reason"] = "low_balance"
                elif str(day) in skipped:
                    outcome = "skipped"
                else:
                    outcome = "failed"
                deorder = "&-1&" in str(meal)
                audit.record("lunch", outcome, source,
                             f"{day}: {'cancel lunch' if deorder else 'order'}",
                             detail=detail)
        except Exception as e:  # noqa: BLE001 - the order result stands
            self.write_log(f"Warning: could not record the orders in the history: {e}")

    def _order_selected(self, orders_dict: dict) -> bool:
        if not self.strava_enable or not orders_dict or not self.strava_client:
            return False
        if self._is_cancelled():
            self.write_log("Strava ordering cancelled by user.")
            return False
        _is_dry = (getattr(self, "strava_order_mode", "confirm") == "dry_run")
        self.strava_client.login()
        self.strava_client.fetch_data()
        if _is_dry:
            self.write_log(f"[Dry-Run] Proposed orders (nothing clicked, page unchanged): {orders_dict}")
            _ok = True
            for _day, _meal in orders_dict.items():
                if self._is_cancelled():
                    self.write_log("Strava ordering cancelled by user.")
                    _ok = False
                    break
                try:
                    _sel = _menu_selection(self.strava_client.foodDict, _day)
                    if _meal not in _sel:
                        _real = next((mid for mid in _sel if '&-1&' in mid), None)
                        if _real and '&-1&' in str(_meal):
                            self.write_log(f"[Dry-Run] {_day}: would use '{_real}'.")
                        else:
                            self.write_log(f"[Dry-Run] {_day}: '{_meal}' is not on the menu, skipping.")
                            _ok = False
                            continue
                    else:
                        self.write_log(f"[Dry-Run] {_day}: '{_meal}' is on the menu.")
                except Exception as _e:
                    self.write_log(f"[Dry-Run] {_day}: selection check failed: {type(_e).__name__}: {_e}")
                    _ok = False
            if _ok:
                self.write_log("[Dry-Run] Proposal ready, nothing was clicked, saved or sent.")
            return _ok
        client = self.strava_client
        client.clicks_made = 0
        client.insufficient_balance = False
        original_ordered = dict(getattr(client, "orderedDict", None) or {})
        try:
            from .lunch_cutoff import is_lunch_order_open as _is_open
            from .school_presets import effective_calendar, resolve_lunch_cutoff
            _cfg = getattr(self, "config_data", None) or {}
            _cutoff = resolve_lunch_cutoff(_cfg)
            _free, _, _ = effective_calendar(_cfg, clip=False)
        except Exception as _e:
            # Fail-closed: without a cutoff check no day is verifiably
            # orderable — ordering blind would only produce rejections.
            self.write_log(f"Warning: cutoff check unavailable ({type(_e).__name__}), skipping Strava ordering.")
            return False
        skipped: list = self._order_report["skipped"]
        succeeded: list = self._order_report["succeeded"]
        failed: list = self._order_report["failed"]
        unfunded: list = self._order_report["unfunded"]
        # Cancellations first: they refund money that the meal orders
        # after them may need (and never cost any themselves).
        items = sorted(orders_dict.items(), key=lambda kv: "&-1&" not in str(kv[1]))
        for day, meal_identifier in items:
            if self._is_cancelled():
                self.write_log("Strava ordering cancelled by user.")
                skipped.append(day)
                break
            try:
                _parsed = parse_date(day)
                _day_date = _parsed.date() if isinstance(_parsed, datetime) else _parsed
            except Exception:
                self.write_log(f"Skipping order for {day}: unparseable date.")
                skipped.append(day)
                continue
            if _day_date < datetime.now().date():
                self.write_log(f"Skipping {day}: day already passed.")
                skipped.append(day)
                continue
            try:
                if not _is_open(_day_date, datetime.now(), _cutoff, _free):
                    self.write_log(f"Skipping {day}: ordering closed (deadline passed).")
                    skipped.append(day)
                    continue
            except Exception:
                # Fail-closed: an uncheckable cutoff must skip the day,
                # never click a meal Strava would reject.
                self.write_log(f"Skipping {day}: cutoff check failed.")
                skipped.append(day)
                continue
            selection = _menu_selection(client.foodDict, day)
            # The GUI synthesizes a deorder id when the menu has no explicit
            # "cancel" element — resolve it to the real one or skip.
            if meal_identifier not in selection:
                real_deorder = next((mid for mid in selection if '&-1&' in mid), None)
                if real_deorder and '&-1&' in str(meal_identifier):
                    meal_identifier = real_deorder
                else:
                    if '&-1&' in str(meal_identifier):
                        self.write_log(f"Skipping deorder for {day}: no cancel element on the menu, leaving unchanged.")
                    else:
                        self.write_log(f"Skipping order for {day}: '{meal_identifier}' not on the menu.")
                    skipped.append(day)
                    continue
            if getattr(client, "insufficient_balance", False) and "&-1&" not in str(meal_identifier):
                # Strava already refused an order for lack of money: every
                # further meal would be refused the same way.
                unfunded.append(day)
                continue
            pick = {"day": day, "meal_id": meal_identifier,
                    "all_ids": list(selection.keys())}
            self.write_log(f"Ordering lunch for {day}: {meal_identifier}")
            if client.order(meal_identifier, pick["all_ids"]):
                succeeded.append(pick)
            elif getattr(client, "insufficient_balance", False):
                # Rejected, nothing changed on the web: not a failure to
                # restore, just a day the account could not pay for.
                unfunded.append(day)
            else:
                try:
                    _suffix = client._notice_suffix()
                except Exception:
                    _suffix = ""
                self.write_log(f"Warning: Failed to click meal {meal_identifier} for {day}, not marking as ordered.{_suffix}")
                failed.append(pick)
        if unfunded:
            self.last_order_low_balance = True
            self.last_unfunded_days = [str(d) for d in unfunded]
            self.write_log(f"Warning: not enough money on the Strava account — not ordered: "
                          f"{', '.join(map(str, unfunded))}. Top up the account and try again.")
        if client.clicks_made:
            # A mid-run page change can silently alter a clicked selection:
            # re-verify every succeeded day. A lost one counts as failed.
            for pick in list(succeeded):
                if not _selection_holds(client, pick):
                    self.write_log(f"Warning: {pick['day']}: the selection changed during ordering.")
                    succeeded.remove(pick)
                    failed.append(pick)
        if failed:
            # Fail-closed, never partial success. Clicks persist
            # immediately on the current frontend, so a failed day may
            # hold a wrong sibling meal: restore originals best-effort.
            if client.clicks_made:
                try:
                    client._restore_original(failed, original_ordered)
                except Exception as e:  # noqa: BLE001 - best effort, reported
                    self.write_log(f"Warning: could not restore the original lunch "
                                  f"selection ({type(e).__name__}: {e}) — check Strava.")
            self._record_persisted(client, succeeded, original_ordered)
            failed_days = ", ".join(str(p.get("day", "?")) for p in failed)
            self.write_log(f"Warning: Strava order failed for: {failed_days} — order failed, verify state on the web.")
            return False
        if succeeded and client.clicks_made:
            if not client.save_confirm([p["meal_id"] for p in succeeded]):
                self.write_log("Warning: Strava save button failed — selections clicked but NOT submitted.")
                return False
        elif succeeded:
            self.write_log("Strava: selection already matches the web, nothing submitted.")
        for pick in succeeded:
            _store_ordered(client.orderedDict, pick["day"], pick["meal_id"])
            self.last_ordered_days.add(pick["day"])
        if unfunded:
            return False
        if skipped:
            self.write_log(f"Warning: Strava days not ordered: {', '.join(map(str, skipped))}.")
            return False
        if not succeeded:
            self.write_log("Strava: no meal was actually selected, skipping submit (nothing to save).")
            return False
        return True

    def _record_persisted(self, client, succeeded: list, original_ordered: dict) -> None:
        """Records the succeeded days of a failed run that are web truth.

        The run as a whole failed, but on the current frontend every click
        saved at once, so those days really changed and must be reported
        (history, cache, UI) as ordered. On the legacy save-button frontend
        nothing clicked was saved — only days that already held the pick
        count. Never raises except ``InterruptedError``.
        """
        if not succeeded:
            return
        immediate = not client.clicks_made
        if not immediate:
            try:
                immediate = client._find_save_button(timeout_ms=500) is None
            except InterruptedError:
                raise
            except Exception:
                immediate = False
        for pick in succeeded:
            day, meal = pick.get("day"), pick.get("meal_id")
            if immediate or (original_ordered or {}).get(day) == meal:
                _store_ordered(client.orderedDict, day, meal)
                self.last_ordered_days.add(day)
        if self.last_ordered_days:
            self.write_log(f"Strava: these days did go through: "
                          f"{', '.join(map(str, sorted(self.last_ordered_days, key=str)))}.")

    def _load_history(self) -> tuple[list, str]:
        """Loads the already-excused history, tolerating missing/corrupt files.

        Returns ``(normalized_history, history_path)``. A missing file
        falls back to the ``.example.json`` template minus its demo rows.
        Raises RuntimeError when the file exists but cannot be read right
        now (locked) — callers must then neither send nor write.
        """
        history_filepath = self.already_excused_file
        history = []
        read_path = history_filepath
        if not os.path.exists(read_path):
            example_path = example_path_for(history_filepath)
            if os.path.exists(example_path):
                read_path = example_path
        if os.path.exists(read_path):
            try:
                with open(read_path, "r", encoding=self.encoding) as f:
                    loaded_history = json.load(f)
                history = loaded_history if isinstance(loaded_history, list) else []
                if read_path != history_filepath:
                    history = [h for h in history if not _is_demo_history_item(h)]
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                from .helpers import quarantine_corrupt_file

                backup = quarantine_corrupt_file(read_path) if read_path == history_filepath else ""
                hint = f" (corrupt file preserved at {backup})" if backup else ""
                self.write_log(f"Warning: Could not read excuse history, starting fresh: {e}{hint}")
                history = []
            except OSError as e:
                # Busy (locked), not corrupt: never quarantine it.
                raise RuntimeError(f"Excuse history is not readable right now: {e}") from e
        history = [normalize_history_item(h) for h in history]
        return history, history_filepath

    def sync_web_excuses_to_history(self, limit: int = None) -> int:
        """Merges excuses already sent on the web into the local history.

        Returns the number of newly added entries. A failed sync (the
        client returns None = unknown) changes nothing and returns 0;
        ``InterruptedError`` propagates on cancel. ``last_outbox_sync_ok``
        tells a successful read (even an empty one) from a failed one.
        A successful read also settles unconfirmed submits.
        """
        self.last_outbox_sync_ok = False
        if self._is_cancelled():
            return 0
        client = getattr(self, "bakalari_client", None)
        if client is None or getattr(client, "page", None) is None:
            return 0
        if limit is None:
            try:
                limit = int((self.config_data or {}).get("sent_excuses_limit", 100))
            except (TypeError, ValueError):
                limit = 100
        client.cancel_requested = self.cancel_requested
        client.cancel_callback = getattr(self, "cancel_callback", None)
        try:
            discovered = client.fetch_sent_excuses(limit=limit)
        except InterruptedError:
            raise
        except Exception as e:
            self.write_log(f"Warning: sent-excuse sync failed: {type(e).__name__}: {e}")
            return 0
        if discovered is None:
            return 0  # unknown, not "nothing sent"
        with history_lock(self.already_excused_file) as locked:
            if not locked:
                self.write_log("Warning: excuse history is busy, web sync postponed.")
                return 0
            try:
                history, history_filepath = self._load_history()
            except Exception as e:
                self.write_log(f"Warning: {e} — web sync postponed.")
                return 0
            merged, added = merge_sent_excuses(history, discovered)
            if added:
                try:
                    atomic_write_json(history_filepath, merged, encoding=self.encoding)
                except Exception as e:
                    self.write_log(f"Failed to write history file: {type(e).__name__}: {e}")
                    return 0
            self.last_outbox_sync_ok = True
            self._settle_unconfirmed(merged, getattr(client, "sentExcuses_from", None))
        if not added:
            return 0
        # One hour-based web message expands to three history entries
        # (income + soon + days and hours); report distinct messages.
        messages = {
            tuple(str(item.get(k)) for k in STORED_KEYS[1:])
            for item in merged[-added:] if isinstance(item, dict)
        }
        self.write_log(f"Added {len(messages) or added} excuse(s) already sent on the web to the history.")
        return added

    def _settle_unconfirmed(self, history: list, outbox_from) -> None:
        """Drops unconfirmed submits the freshly read outbox settled.

        Runs under the history lock, right after a successful outbox read.
        Never raises: an unsettled row just keeps blocking its re-send.
        """
        from datetime import date as _date

        try:
            pending = load_unconfirmed(self.already_excused_file, self.encoding)
            if not pending:
                return
            still_open, confirmed, not_sent = resolve_unconfirmed(
                pending, history, outbox_from if isinstance(outbox_from, _date) else None)
            if not (confirmed or not_sent):
                return
            save_unconfirmed(self.already_excused_file, still_open, self.encoding)
        except Exception as e:  # noqa: BLE001 - keep blocking, retry next sync
            self.write_log(f"Warning: could not settle unconfirmed excuses: {type(e).__name__}: {e}")
            return
        for entry in confirmed:
            self.write_log(f"Unconfirmed excuse found in the Komens outbox — it was sent: {base_excuse(entry)}")
        for entry in not_sent:
            self.write_log(f"Unconfirmed excuse is not in the Komens outbox — it was NOT sent "
                          f"and may be sent again: {base_excuse(entry)}")

    def excuse_single(self, excuse: dict, custom_text: str = None) -> bool:
        """Excuses one absence (the Today one-click flow).

        True when the absence is excused afterwards — freshly sent, already
        covered by the history, or (``dry_run``) the form was filled
        without sending; callers must check ``excuse_mode == "dry_run"``
        and never treat that as sent.
        """
        return self.send_excuse_outcome(excuse, custom_text) in ("sent", "covered", "dry_run")

    def send_excuse_outcome(self, excuse: dict, custom_text: str = None) -> str:
        """Manual send of one excuse: ``sent`` / ``covered`` / ``dry_run`` /
        ``unconfirmed`` (submitted, the site never confirmed) / ``skipped``
        (an earlier unconfirmed submit blocks it) / ``failed``.

        Unlike :meth:`excuse_single` the caller can tell "already excused"
        (nothing was sent) apart from a real send.
        """
        return self._send_excuse(excuse, custom_text, source="manual")

    def _submit(self, excuse: dict, custom_text: str | None, fill_only: bool) -> bool:
        """Fills (and unless ``fill_only`` submits) the Bakaláři excuse form."""
        client = self.bakalari_client
        action = client.fill_excuse_form if fill_only else client.execute_excuse
        ex_type = excuse.get("type")
        if ex_type == "pure days":
            return action(excuse["starting_day"], excuse["ending_day"],
                          custom_text=custom_text, is_days=True, excuse_type=ex_type)
        if ex_type in ("income", "soon"):
            lesson = excuse["starting_lesson"]
            return action(excuse["starting_day"], excuse["starting_day"],
                          start_lesson=lesson, end_lesson=lesson,
                          custom_text=custom_text, is_days=False, excuse_type=ex_type)
        if ex_type == "days and hours":
            return action(excuse["starting_day"], excuse["ending_day"],
                          start_lesson=excuse["starting_lesson"],
                          end_lesson=excuse["ending_lesson"],
                          custom_text=custom_text, is_days=False, excuse_type=ex_type)
        self.write_log(f"Warning: unknown excuse type {ex_type!r}, skipping (no submit).")
        return False

    def _send_excuse(self, excuse: dict, custom_text: str | None,
                     source: str = "manual") -> str:
        """Sends one excuse unless the history already covers it.

        Returns ``"sent"``, ``"covered"``, ``"dry_run"``, ``"unconfirmed"``,
        ``"skipped"`` or ``"failed"``;
        every outcome is also appended to the automation history. The
        history check, the submit and the history write run under one
        lock, so concurrent senders (UI clicks, auto refresh, tray) can
        never excuse the same absence twice.
        """
        outcome = self._send_excuse_inner(excuse, custom_text)
        try:
            from . import audit

            audit.record("excuse", outcome, source, audit.describe_excuse(excuse),
                         detail={"type": excuse.get("type"), "mode": self.excuse_mode})
        except Exception as e:  # noqa: BLE001 - the send result stands
            self.write_log(f"Warning: could not record the excuse in the history: {e}")
        return outcome

    def _send_excuse_inner(self, excuse: dict, custom_text: str | None) -> str:
        if not self.bakalari_client:
            self.write_log("Warning: Bakaláři client not available, excuse not sent.")
            return "failed"
        if self.excuse_mode == "dry_run":
            self.write_log(f"[Dry-Run] Filling the excuse form (not sending): {excuse}")
            try:
                filled = self._submit(excuse, custom_text, fill_only=True)
            except InterruptedError:
                raise
            except Exception as e:
                self.write_log(f"[Dry-Run] Filling the form failed: {type(e).__name__}: {e}")
                return "failed"
            if filled:
                self.write_log("[Dry-Run] Form filled in the browser, nothing was sent.")
            return "dry_run" if filled else "failed"
        with history_lock(self.already_excused_file) as locked:
            if not locked:
                self.write_log("Warning: another excuse is being sent right now — try again later.")
                return "failed"
            try:
                history, history_filepath = self._load_history()
            except Exception as e:
                self.write_log(f"Warning: {e} — not sending (duplicate check impossible).")
                return "failed"
            if excuse_covered(excuse, history):
                self.write_log(f"Already excused, not sending again: {excuse}")
                return "covered"
            try:
                unconfirmed = load_unconfirmed(history_filepath, self.encoding)
            except OSError as e:
                self.write_log(f"Warning: unconfirmed excuses not readable ({e}) — "
                              "not sending (duplicate check impossible).")
                return "failed"
            if unconfirmed_blocks(excuse, unconfirmed):
                self.write_log("Not sending: an earlier submit of this absence was never confirmed "
                              "and may have gone out. The next refresh checks the Komens outbox "
                              f"and releases it if nothing arrived: {excuse}")
                return "skipped"
            self.write_log(f"Attempting to excuse: {excuse}")
            client = self.bakalari_client
            client.last_submit_uncertain = False
            try:
                client.login()
                success = self._submit(excuse, custom_text, fill_only=False)
            except InterruptedError:
                if getattr(client, "last_submit_uncertain", False):
                    self._record_unconfirmed(history_filepath, unconfirmed, excuse)
                raise
            except Exception as e:
                import traceback

                self.write_log(f"Exception while excusing {excuse}: "
                              f"{type(e).__name__}: {e}\n{traceback.format_exc()}")
                success = False
            if not success:
                if getattr(client, "last_submit_uncertain", False) is True:
                    return self._record_unconfirmed(history_filepath, unconfirmed, excuse)
                self.write_log(f"Warning: excuse NOT sent (the form did not confirm): {excuse}")
                return "failed"
            history.extend(e for e in history_entries(excuse)
                           if e not in history)
            try:
                atomic_write_json(history_filepath, history, encoding=self.encoding)
                self.write_log("Successfully excused and saved to disk.")
            except Exception as e:
                # Sent, but the duplicate guard does not know it yet: the
                # next web sync re-imports it from the Komens outbox.
                self.write_log(f"Warning: excuse was SENT but the history file could not be "
                              f"written ({type(e).__name__}: {e}); it will be re-synced "
                              "from the web on the next refresh.")
            return "sent"

    def _record_unconfirmed(self, history_filepath: str, unconfirmed: list, excuse: dict) -> str:
        """Remembers a submit that may have gone out. Returns ``"unconfirmed"``.

        Called under the history lock. If the sidecar cannot be written
        the excuse goes into the history instead: never re-sending a real
        absence is recoverable (the user excuses it by hand), a duplicate
        excuse is not.
        """
        self.write_log(f"Warning: the excuse submit was NOT confirmed — it may or may not have been "
                      f"sent. It will not be sent again until the Komens outbox shows: {excuse}")
        try:
            save_unconfirmed(history_filepath, list(unconfirmed) + [unconfirmed_entry(excuse)],
                             self.encoding)
        except Exception as e:  # noqa: BLE001 - fall back to the history
            self.write_log(f"Warning: could not record the unconfirmed excuse ({type(e).__name__}: "
                          f"{e}); marking it as sent to rule out a duplicate.")
            try:
                history, _ = self._load_history()
                history.extend(h for h in history_entries(excuse) if h not in history)
                atomic_write_json(history_filepath, history, encoding=self.encoding)
            except Exception as e2:  # noqa: BLE001 - logged, nothing else left to try
                self.write_log(f"Warning: history write failed too ({type(e2).__name__}: {e2}).")
        return "unconfirmed"

    def excuse_pending(self) -> int:
        """Sends every pending excuse (``auto`` mode). Returns the number sent.

        ``confirm`` mode never sends from here — excuses are confirmed one
        by one in the UI. ``dry_run`` fills each form without sending.
        """
        self.last_excuse_failures = 0
        if self.excuse_mode == "confirm":
            self.write_log("Excuse mode is 'confirm' — automatic sending skipped.")
            return 0
        sent = 0
        # Lessons the user ignored in the UI ("excused elsewhere") must
        # never be auto-sent: a second excuse cannot be taken back.
        ignored = (getattr(self, "config_data", None) or {}).get("ignored_excuses", [])
        client = getattr(self, "bakalari_client", None)
        pending = Strakalari.generate_excuses(
            self.timetableData, delay_days=self.excuse_delay_days,
            ignored=ignored if isinstance(ignored, list) else [],
            not_before=excuse_window_start(
                datetime.now().date(), getattr(client, "sentExcuses_from", None)))
        for excuse in pending:
            if self._is_cancelled():
                self.write_log("Excusing cancelled by the user.")
                break
            outcome = self._send_excuse(excuse, self.default_excuse_text(excuse), source="auto")
            if outcome == "sent":
                sent += 1
            elif outcome in ("failed", "unconfirmed"):
                self.last_excuse_failures += 1
        return sent

    def default_excuse_text(self, excuse: dict) -> str:
        """The configured default excuse text for one excuse."""
        ex_type = excuse.get("type")
        start, end = excuse.get("starting_day"), excuse.get("ending_day")
        if ex_type == "pure days":
            date_range = f"{start} – {end}" if start != end else str(start)
            return format_excuse_template(
                self._default_template(self.long_absence_excuses),
                date_str=date_range, signature_str=self.signature)
        if ex_type in ("income", "soon"):
            templates = self.left_soon_excuses if ex_type == "soon" else self.late_income_excuses
            return format_excuse_template(
                self._default_template(templates), date_str=str(start),
                lessons_str=str(excuse.get("starting_lesson")), signature_str=self.signature)
        first, last = excuse.get("starting_lesson"), excuse.get("ending_lesson")
        lessons = f"{first}. – {last}." if first != last else f"{first}."
        return format_excuse_template(
            self._default_template(self.short_absence_excuses), date_str=str(start),
            lessons_str=lessons, signature_str=self.signature)

    @staticmethod
    def _pick_template(templates: list, mode: str = "first") -> str:
        """Picks the default excuse template honoring the selection mode.

        `mode` is "first" (default) or "random" (see `default_excuse_selection`).
        Blank templates are skipped; returns "" when none is left.
        """
        usable = [t for t in templates or [] if str(t or "").strip()]
        if not usable:
            return ""
        if str(mode).lower() == "random" and len(usable) > 1:
            return random.choice(usable)
        return usable[0]

    def _default_template(self, templates: list) -> str:
        return Strakalari._pick_template(templates, self.default_excuse_selection)

    @staticmethod
    def generate_excuses(raw_data, delay_days=2, override_today=None, ignored=None,
                         not_before=None):
        """Pending excuses for unexcused absences older than ``delay_days``.

        ``not_before`` (a date) drops older days entirely: they lie outside
        the excuse window (see ``excuse_history.excuse_window_start``).

        ``ignored`` holds UI ignore keys (``YYYY-MM-DD|period|subject``)
        or ``(date, period)`` tuples: those lessons count as excused
        elsewhere — never excused again, and they break full-day ranges.
        """
        ignored_points = _ignored_points(ignored)
        today = override_today if override_today else datetime.now()
        # Compare plain dates: a datetime cutoff keeps the time-of-day, so
        # the same absence flips included/excluded depending on run hour.
        today_date = today.date() if isinstance(today, datetime) else today
        cutoff_date = today_date - timedelta(days=delay_days)
        cleaned_days = {}
        # Dates that need no excuse themselves but must break a consecutive
        # full-day chain (fully excused days) or downgrade it to partial
        # (days mixing excused and absent lessons).
        blocked_days = set()

        for date_str, lessons in raw_data.items():
            try:
                parsed_date = parse_date(date_str)
            except Exception:
                continue
            parsed_day = parsed_date.date() if isinstance(parsed_date, datetime) else parsed_date
            if parsed_day > cutoff_date:
                continue
            if not_before is not None and parsed_day < not_before:
                continue

            day_lessons = {}
            has_non_absent = False
            for lesson in lessons:
                # Malformed rows (no teacher/subject/period) are skipped: they
                # cannot be merged into a range safely, so under-excusing one
                # malformed row beats over-excusing the wrong lessons.
                if not lesson.get("teacher") or not lesson.get("subject"):
                    continue
                # Cancelled lessons ("Odpadá" / "Zrušeno") need no excuse and prove no
                # attendance — keep them neutral so they neither trigger new
                # excuses nor break/merge full-day ranges. Negated notices
                # ("Neodpadá", "Nezrušeno") mean the lesson takes place and
                # must NOT match — see _is_cancelled_notice().
                if lesson.get("status") == "cancelled" or is_cancel_notice(lesson.get("notice")):
                    continue
                lesson_num = extract_lesson_num(lesson.get("time", ""))
                if lesson_num is None:
                    continue
                if ignored_points:
                    # Same period derivation as the UI task keys
                    # (Lesson.from_legacy): explicit "period" first.
                    try:
                        key_period = int(lesson["period"]) if lesson.get("period") is not None else lesson_num
                    except (TypeError, ValueError):
                        key_period = lesson_num
                    if ((parsed_day, key_period) in ignored_points
                            or (parsed_day, lesson_num) in ignored_points):
                        has_non_absent = True
                        continue
                # Same classifier as the UI task list (models.absence_kind).
                # Already excused lessons need no action — excluded so they
                # neither trigger excuses nor merge into new ranges. Generic
                # early leaves use the same hour-based form as "soon".
                kind = absence_kind(lesson.get("absenceType"), lesson.get("absencetext"))
                if kind == "excused":
                    has_non_absent = True
                    continue
                status = {"absent": "absent", "late": "income",
                          "soon": "soon", "early": "soon"}.get(kind, "present")

                current_status = day_lessons.get(lesson_num)
                priority = {"absent": 3, "income": 2, "soon": 2, "present": 1}
                if current_status is None or priority.get(status, 0) > priority.get(current_status, 0):
                    day_lessons[lesson_num] = status

            if day_lessons:
                cleaned_days[parsed_date] = dict(sorted(day_lessons.items()))
                if has_non_absent:
                    blocked_days.add(parsed_date)
            elif has_non_absent:
                # Fully excused (or otherwise non-actionable) day: nothing to
                # excuse, but it still breaks a full-day chain.
                blocked_days.add(parsed_date)

        excuses = []
        consecutive_full_days = []
        prev_date = None

        def flush_full_days():
            if not consecutive_full_days:
                return
            start = consecutive_full_days[0].strftime("%d.%m.%Y")
            end = consecutive_full_days[-1].strftime("%d.%m.%Y")
            excuses.append({
                "type": "pure days",
                "starting_day": start,
                "ending_day": end,
            })
            consecutive_full_days.clear()

        for date in sorted(set(cleaned_days) | blocked_days):
            # A gap in the data means no school that day (weekend, holiday,
            # untaught day) — it must end a full-day chain instead of being
            # silently bridged into one over-long excuse range.
            if consecutive_full_days and prev_date is not None and (date - prev_date).days > 1:
                flush_full_days()
            prev_date = date
            lessons = cleaned_days.get(date, {})
            if not lessons:
                # Fully excused day: nothing to do, but the chain ends here.
                flush_full_days()
                continue
            statuses = list(lessons.values())

            if date not in blocked_days and all(s == "absent" for s in statuses):
                # Consecutive school days only: any gap in the data (weekend,
                # holiday — flushed above) or any present/excused school day
                # ends the range, so multi-day excuses never span days off.
                consecutive_full_days.append(date)
            else:
                flush_full_days()
                date_str = date.strftime("%d.%m.%Y")
                for status, group in groupby(lessons.items(), key=lambda x: x[1]):
                    group_list = list(group)
                    if status in ("income", "soon"):
                        for lesson_num, _ in group_list:
                            excuses.append({
                                "type": status,
                                "starting_day": date_str,
                                "ending_day": date_str,
                                "starting_lesson": lesson_num,
                                "ending_lesson": lesson_num,
                            })
                    elif status == "absent":
                        sub_group = []
                        for lesson_num, _ in group_list:
                            if not sub_group or lesson_num == sub_group[-1] + 1:
                                sub_group.append(lesson_num)
                            else:
                                excuses.append({
                                    "type": "days and hours",
                                    "starting_day": date_str,
                                    "ending_day": date_str,
                                    "starting_lesson": sub_group[0],
                                    "ending_lesson": sub_group[-1],
                                })
                                sub_group = [lesson_num]
                        if sub_group:
                            excuses.append({
                                "type": "days and hours",
                                "starting_day": date_str,
                                "ending_day": date_str,
                                "starting_lesson": sub_group[0],
                                "ending_lesson": sub_group[-1],
                            })

        flush_full_days()
        return excuses

    def check_bakalari_login(self) -> tuple[bool, str]:
        if not self.bakalari_url or not self.bakalari_username:
            return False, t("test_bak_missing")
        try:
            if self.bakalari_client:
                self.bakalari_client.login()
            return True, t("test_bak_ok")
        except Exception as e:
            return False, t("test_bak_failed", err=e)

    def check_strava_login(self) -> tuple[bool, str]:
        if not self.strava_id or not self.strava_username:
            return False, t("test_strava_missing")
        try:
            if self.strava_client:
                self.strava_client.login()
            return True, t("test_strava_ok")
        except Exception as e:
            return False, t("test_strava_failed", err=e)

# Export module-level shortcut


generate_excuses = Strakalari.generate_excuses
