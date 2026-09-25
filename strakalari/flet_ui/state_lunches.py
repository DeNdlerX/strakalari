"""Lunch ordering: cutoff, staged picks, sending, AI picks and the blacklist.

Mixin of :class:`strakalari.flet_ui.state.AppState` — it relies on the
state attributes and helpers defined there (``config``, ``data``,
``_emit``, ``_spawn``, ``log`` …).
"""

from __future__ import annotations


class LunchMixin:
    def lunch_cutoff_time(self) -> str:
        """Resolved ``HH:MM`` cutoff (user override, then preset, else 12:00)."""
        from strakalari.core import school_presets as sp

        try:
            return sp.resolve_lunch_cutoff(self.config.data)
        except Exception:
            return "12:00"

    def lunch_free_days(self) -> set:
        """School free-day set used for business-day math."""
        from strakalari.core import school_presets as sp

        try:
            # Unclipped: deadlines after the absence closure (May, June)
            # must still skip the user's days off there.
            dates, _, _ = sp.effective_calendar(self.config.data, clip=False)
            return set(dates or set())
        except Exception:
            return set()

    def lunch_order_deadline(self, day: str):
        """Deadline datetime for a lunch day, or None when unparseable."""
        from strakalari.core.lunch_cutoff import lunch_order_deadline
        from strakalari.core.models import parse_cz_date

        try:
            parsed = parse_cz_date(day)
        except Exception:
            return None
        if parsed is None:
            return None
        try:
            return lunch_order_deadline(parsed, self.lunch_cutoff_time(),
                                        self.lunch_free_days())
        except Exception:
            return None

    def is_lunch_order_open(self, day: str, now=None) -> bool:
        """True while the previous-business-day cutoff has not passed.

        Fail-closed: an unparseable day can never be staged as orderable.
        """
        from strakalari.core.lunch_cutoff import is_lunch_order_open
        from strakalari.core.models import parse_cz_date

        try:
            parsed = parse_cz_date(day)
        except Exception:
            return False
        if parsed is None:
            return False
        try:
            return bool(is_lunch_order_open(parsed, now,
                                            self.lunch_cutoff_time(),
                                            self.lunch_free_days()))
        except Exception:
            return False

    def _auto_lunch_is_open(self):
        """``date -> bool`` cutoff predicate for staged picks (None = unknown)."""
        from strakalari.core.lunch_auto import order_window_predicate

        return order_window_predicate(self.config.data)

    @property
    def pending_lunch_count(self) -> int:
        """Unsubmitted lunch changes (the badge number on Obědy)."""
        try:
            return len(set(getattr(self, "pending_orders", None) or set()))
        except Exception:
            return 0

    def order_lunch(self, day: str, meal_id: str) -> bool:
        """Records a lunch choice locally (clears any planned skip).

        Returns False (and stages nothing) when the previous-business-day
        cutoff for ``day`` has already passed — Strava would reject it.
        """
        if not self.strava_enabled():
            return False
        try:
            if not self.is_lunch_order_open(str(day)):
                try:
                    from .strings import S

                    self.log(S("lunch_order_closed"))
                except Exception:
                    pass
                return False
        except Exception:
            # Fail-closed: an uncheckable cutoff must not stage a pick
            # Strava would reject.
            return False
        self.orders[str(day)] = str(meal_id)
        self.pending_orders.add(str(day))
        self.cancelled_lunches.discard(str(day))
        self.tutorial_event("lunch_picked")
        self._emit()
        return True

    def cancel_lunch_order(self, day: str) -> None:
        """Drops the local lunch choice for a day."""
        self.orders.pop(str(day), None)
        self.pending_orders.discard(str(day))
        self._emit()

    def submit_orders(self, page=None) -> bool:
        """Sends the local lunch choices (and planned-skip deorders) to Strava.

        Runs in a background thread; returns False when nothing is pending
        or a submit is already running.
        """
        from .strings import S

        if not self.strava_enabled():
            return False
        if self.refresh_running or not self._claim_flight("order_running"):
            return False
        # Any exit below that does NOT hand the payload to the worker must
        # release the latch — otherwise Odeslat stays dead until restart.
        spawned = False
        try:
            # Only what the user changed here: re-sending every known order
            # would revert changes made on the Strava website since the
            # last refresh.
            pending = set(getattr(self, "pending_orders", None) or set())
            payload = {str(day): str(mid) for day, mid in self.orders.items()
                       if mid and str(day) in pending}
            food = self.food()
            for day in self.cancelled_lunches:
                if day in payload:
                    continue
                web = str(self.web_orders.get(day, "") or "")
                if not web or "&-1&" in web:
                    continue  # nothing ordered on the web: nothing to cancel
                meals = food.get(day, {}) or {}
                deorder = next((mid for mid in meals if "&-1&" in str(mid)), None)
                if deorder:
                    payload[day] = str(deorder)
            # Drop days past the previous-business-day cutoff: Strava would
            # reject them and a partial send must not mark them as ordered.
            # Picks stay staged (a later cutoff re-opens them) — only the
            # transmitted payload is filtered.
            closed = [day for day in payload if not self.is_lunch_order_open(day)]
            for day in closed:
                payload.pop(day, None)
            if closed:
                self.log(f"{S('lunch_order_closed')} ({len(closed)})")
                try:
                    from .overlays import snack as _snack

                    if page is not None:
                        _snack(page, S("lunch_order_closed"))
                except Exception:
                    pass
            if not payload:
                return False
            if self.demo_mode and not self._has_any_credentials():
                self.log(S("need_credentials"))
                try:
                    from .overlays import snack as _snack

                    if page is not None:
                        _snack(page, S("need_credentials"))
                except Exception:
                    pass
                return False
            self.order_running = True
            self.current_step = S("orders_sending")
            self.log(f"{S('orders_sending')} ({len(payload)})")
            self.tutorial_event("orders_sent")
            self._emit()

            if page is not None:
                self.bind_page(page)

            def _work() -> None:
                ok = False
                dry = False
                placed: dict[str, str] = {}
                busy = False
                unfunded: list[str] = []
                try:
                    from strakalari.core.automation import Strakalari
                    from strakalari.core.refresh import session_lock

                    # The tray (another process) may be mid-refresh with
                    # its own browser: never order in parallel with it.
                    with session_lock() as held:
                        if not held:
                            busy = True
                            self._worker_log(S("session_busy"))
                        else:
                            app = Strakalari(on_log=self._worker_log, start_browser=True)
                            try:
                                app.cancel_requested = False
                                dry = (getattr(app, "strava_order_mode", "") == "dry_run")
                                ok = bool(app.stravaOrderSelected(dict(payload)))
                                if not dry:
                                    # Days that really went through, even when
                                    # another day failed (clicks persist on the web).
                                    done = set(getattr(app, "last_ordered_days", None) or ())
                                    placed = {d: m for d, m in payload.items() if d in done}
                                    if getattr(app, "last_order_low_balance", False):
                                        unfunded = list(getattr(app, "last_unfunded_days", None) or [])
                            finally:
                                try:
                                    app.close()
                                except Exception as exc:  # noqa: BLE001 - teardown only
                                    print(f"Warning: browser close failed: {exc}")
                    if placed:
                        self._record_web_orders(placed)
                except Exception as exc:  # noqa: BLE001 - report, don't crash
                    self._worker_log(f"{S('orders_failed')}: {type(exc).__name__}: {exc}".splitlines()[0][:200])
                    self.report_error("orders", exc,
                                      extra={"days": len(payload)})
                except BaseException:
                    # Latch release on hard exits (KeyboardInterrupt/...),
                    # then re-raise — never reported as a regular failure.
                    self.order_running = False
                    self._emit()
                    raise
                self.order_running = False
                low_balance_msg = ""
                if unfunded:
                    from strakalari.core.i18n import t as _t
                    from strakalari.core.refresh import record_low_balance

                    low_balance_msg = _t("strava_low_balance_manual", n=len(unfunded))
                    record_low_balance(unfunded)
                    self._set_low_balance_memory(unfunded)
                elif ok and not dry:
                    from strakalari.core.refresh import record_low_balance

                    record_low_balance(None)
                    self._set_low_balance_memory(None)
                if ok and dry:
                    # Dry run simulates success without ordering — web truth untouched.
                    self._worker_log(S("orders_dry_run"))
                elif ok:
                    self._worker_log(S("orders_sent"))
                elif low_balance_msg:
                    # The user's to fix (top up), not a bug: the snackbar says
                    # what to do, no failure toast on top of it.
                    self._worker_log(low_balance_msg)
                elif not busy:
                    # Fail loudly: the reason is in the log lines above.
                    self._worker_log(S("orders_failed"))
                    self._notify("automation_failed", S("orders_failed"))
                try:
                    from .overlays import snack as _snack

                    if page is not None:
                        if busy:
                            _msg = S("session_busy")
                        elif ok:
                            _msg = S("orders_dry_run") if dry else S("orders_sent")
                        elif low_balance_msg:
                            _msg = low_balance_msg
                        else:
                            _msg = S("orders_failed")
                        _snack(page, _msg)
                        try:
                            page.update()
                        except Exception:
                            pass
                except Exception:
                    pass
                self._emit()

            self._spawn(_work, name="strakalari-orders")
            spawned = True
            return True
        finally:
            if not spawned:
                self._release_flight("order_running")

    def _set_low_balance_memory(self, days: list[str] | None) -> None:
        """Mirrors the cached low-balance warning into ``data`` (banner)."""
        from datetime import datetime as _dt

        try:
            data = dict(self.data or {})
            data["strava_low_balance"] = (
                None if days is None else
                {"at": _dt.now().isoformat(timespec="seconds"),
                 "days": sorted({str(d) for d in days})})
            self.data = data
        except Exception:
            pass

    def _record_web_orders(self, placed: dict[str, str]) -> None:
        """Marks successfully placed picks as web truth (memory + cache).

        Merges into the cached ``strava_ordered`` map — replacing it with
        just this batch would drop every other ordered day.
        """
        from strakalari.core.cache import load_data_cache, save_data_cache
        from strakalari.core.models import canonical_day_key

        placed = {canonical_day_key(d): str(m) for d, m in placed.items()}
        for day, meal in placed.items():
            self.web_orders[day] = meal
        self.pending_orders.difference_update(placed)
        try:
            cached = load_data_cache().get("strava_ordered")
            # Drop other spellings of the placed days ("4.9.2026") so the
            # cache never holds two entries for one day.
            merged = {k: v for k, v in (cached.items() if isinstance(cached, dict) else ())
                      if canonical_day_key(k) not in placed}
            merged.update(placed)
            save_data_cache({"strava_ordered": merged})
        except Exception as exc:  # noqa: BLE001 - memory already updated
            print(f"Warning: could not cache placed orders: {exc}")

    def start_ai_recommend(self, page=None) -> bool:
        """Runs the AI lunch recommendation in a background thread.

        Returns False when a run is already in flight (the caller toasts
        ``ai_already_running``). The flag lives here — not on the view —
        because the Shell rebuilds views from scratch on every ``_emit``,
        so a view-local ``busy`` never survived to paint (no disabled
        button, no progress bar, no log line).
        """
        from .strings import S

        if not self._claim_flight("ai_running"):
            return False
        if page is not None:
            self.bind_page(page)
        self.log(S("ai_started"))
        self._emit()

        def _work() -> None:
            msg = S("no_changes")
            try:
                from strakalari.core.gemini import recommend_lunches
                from strakalari.core.helpers import decrypt_strict
                from strakalari.core.i18n import get_language

                raw_key = self.get("gemini_api_key", "") or ""
                if self.get("gemini_api_key_encrypted"):
                    # Stored Fernet ciphertext is NOT an API key — decrypt
                    # first (Qt tab already does; the Flet path never did).
                    raw_key = decrypt_strict(raw_key) or ""
                _html, orders = recommend_lunches(
                    self.food(),
                    self.lunch_prefs,
                    raw_key,
                    model=self.get("gemini_model", "gemini-3.8-flash"),
                    language=get_language(),
                )
                food = self.food()
                staged = 0
                skipped = 0
                closed = 0
                for day, mid in (orders or {}).items():
                    # Only a meal from that same day's menu is orderable.
                    if mid not in (food.get(str(day)) or {}):
                        continue
                    if str(day) in self.cancelled_lunches:
                        # A planned skip owns this day: recommending onto it
                        # would stage (and Send) a lunch on a vacation day.
                        skipped += 1
                        continue
                    try:
                        if not self.is_lunch_order_open(str(day)):
                            closed += 1
                            continue
                    except Exception:
                        # Fail-closed: an uncheckable cutoff must not
                        # stage a recommendation Strava would reject.
                        closed += 1
                        continue
                    # Batch the writes (no per-day _emit storm resetting
                    # scroll and half-typed inputs); one emit does it all.
                    self.orders[str(day)] = str(mid)
                    self.pending_orders.add(str(day))
                    self.cancelled_lunches.discard(str(day))
                    staged += 1
                if staged:
                    msg = S("to_send") + f" ({staged})"
                    if skipped:
                        msg += f" · {S('skipped_reason')}: {skipped}"
                    if closed:
                        msg += f" · {S('lunch_closed_count')}: {closed}"
                elif closed:
                    msg = S("lunch_order_closed")
                elif skipped:
                    msg = S("no_lunch")
                else:
                    msg = S("no_changes")
                self.log(msg)
            except Exception as exc:  # noqa: BLE001 - show, don't crash
                msg = str(exc)
                self.log(f"{S('ai_failed')}: {msg}".splitlines()[0][:200])
            except BaseException:
                self.ai_running = False
                self._emit()
                raise
            self.ai_running = False
            try:
                from .overlays import snack as _snack

                if page is not None:
                    _snack(page, msg)
                    try:
                        page.update()
                    except Exception:
                        pass
            except Exception:
                pass
            self._emit()

        self._spawn(_work, name="strakalari-recommend")
        return True

    def apply_food_filter(self, prefs: str) -> None:
        """Hides banned meals and stages first-allowed picks.

        Ban keywords come from the blacklist file plus the free-text
        prefs (same wording as the AI prompt) — only negation clauses
        contribute (``nemám rád vepřové``, ``bez hub``); likes never
        hide. Days without a local pick — or whose pick just got
        hidden — get the first allowed meal staged (deorder fallback
        when everything is banned, like auto mode); existing good
        picks are never clobbered. Past, cancelled and cutoff-closed
        days are skipped. Single emit.
        """
        from strakalari.core.matching import is_food_banned, prefs_ban_keywords

        blacklist = self.blacklist_words()
        try:
            pref_words = prefs_ban_keywords(prefs)
        except Exception:
            pref_words = []
        seen = {str(w).casefold() for w in blacklist}
        combined = list(blacklist)
        for word in pref_words:
            if str(word).casefold() not in seen:
                seen.add(str(word).casefold())
                combined.append(word)
        from .strings import S

        food = self.food()
        hidden: set[str] = set()
        reasons: dict[str, str] = {}
        for meals in food.values():
            for mid, name in (meals or {}).items():
                if "&-1&" in str(mid):
                    continue
                banned, keyword = is_food_banned(str(name), combined)
                if banned:
                    hidden.add(str(mid))
                    reasons[str(mid)] = f"{S('skipped_reason')}: {keyword}"
                    continue
        self.lunch_hidden = hidden
        self.lunch_reasons = reasons
        self.lunch_prefs = prefs
        try:
            from strakalari.core.lunch_auto import filter_picks

            picks = filter_picks(
                food, blacklist=combined,
                cancelled_days=set(self.cancelled_lunches or set()),
                is_open=self._auto_lunch_is_open(),
            )
        except Exception:
            picks = {}
        for day, mid in (picks or {}).items():
            current = self.orders.get(str(day))
            if current is None or str(current) in hidden:
                self.orders[str(day)] = str(mid)
                self.pending_orders.add(str(day))
        self._emit()

    def _blacklist_path(self) -> str:
        path = self.get("strava_blacklist", "./strava_blacklist.json")
        try:
            from strakalari.core.helpers import _resolve_path

            path = _resolve_path(path)
        except Exception:
            pass
        return path

    def blacklist_words(self) -> list[str]:
        import json
        import os

        from strakalari.core.matching import normalize_word as _normalize_word

        path = self._blacklist_path()
        try:
            if path and os.path.exists(path):
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
                words = [str(w).strip() for w in (data or [])
                         if str(w).strip() and not _normalize_word(w).startswith("your_blacklist")]
                return sorted(set(words), key=str.casefold)
        except Exception as e:
            # Fail-open read (manual/confirm flow only): log loudly instead
            # of silently installing an empty filter.
            try:
                from .strings import S

                self._worker_log(f"{S('blacklist_read_failed').format(path=path)} ({type(e).__name__})")
            except Exception:
                pass
        return []

    def _blacklist_words_for_edit(self) -> list[str] | None:
        """Current words for an add/remove, or None when editing is unsafe.

        Unlike :meth:`blacklist_words` (display, fail-open to ``[]``), an
        edit writes the whole file: saving on top of an unreadable or
        corrupt file would silently replace every existing keyword. The
        file is left untouched and the reason logged instead.
        """
        import json
        import os

        from strakalari.core.matching import normalize_word as _normalize_word

        from .strings import S

        path = self._blacklist_path()
        if not path or not os.path.exists(path):
            return []
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            if not isinstance(data, list):
                raise ValueError("not a JSON list")
        except (OSError, ValueError) as e:
            self._blacklist_edit_error = S("blacklist_unreadable").format(path=path)
            self.log(f"{self._blacklist_edit_error} ({type(e).__name__})")
            return None
        return sorted({str(w).strip() for w in data
                       if str(w).strip() and not _normalize_word(w).startswith("your_blacklist")},
                      key=str.casefold)

    def _write_blacklist(self, words: list[str]) -> None:
        import os

        from strakalari.core.helpers import atomic_write_json

        path = self._blacklist_path()
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)
        atomic_write_json(path, sorted(set(words)))

    def add_blacklist_word(self, word: str) -> bool:
        self._blacklist_edit_error = ""
        word = str(word or "").strip()
        if len(word) < 3:
            return False
        words = self._blacklist_words_for_edit()
        if words is None:
            return False
        if word.casefold() in {w.casefold() for w in words}:
            return False
        words.append(word)
        try:
            self._write_blacklist(words)
        except Exception as exc:  # noqa: BLE001 - report, don't crash
            print(f"Warning: could not save blacklist: {exc}")
            return False
        self.apply_food_filter(self.lunch_prefs)
        return True

    def remove_blacklist_word(self, word: str) -> bool:
        self._blacklist_edit_error = ""
        current = self._blacklist_words_for_edit()
        if current is None:
            return False
        words = [w for w in current
                 if w.casefold() != str(word or "").casefold()]
        try:
            self._write_blacklist(words)
        except Exception as exc:  # noqa: BLE001
            print(f"Warning: could not save blacklist: {exc}")
            return False
        self.apply_food_filter(self.lunch_prefs)
        return True
