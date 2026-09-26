"""Strava ordering: meal clicks, verification, rollback and the save confirm.

Everything here spends or refunds the student's money, so every click is
verified against the page and failures roll back to the original state.
"""

import re


#: A coded Strava rejection: "Warning [5005] You do not have sufficient …".
_CODED_NOTICE_RE = re.compile(
    r"(?:Warning|Varování|Upozornění|Chyba|Error)\s*\[\d+\][^\n]*(?:\n[^\n]{0,200})?",
    re.IGNORECASE,
)

#: Strava's "not enough money on the account" rejection (code 5005).
LOW_BALANCE_CODE = "5005"
_LOW_BALANCE_HINTS = (
    "sufficient account balance", "insufficient balance", "not enough money",
    "nedostatečný zůstatek", "nedostatecny zustatek", "dostatečný zůstatek",
    "dostatecny zustatek", "nedostatek prostředků", "nedostatek prostredku",
    "nedostatek peněz", "nedostatek penez",
)


def is_low_balance_notice(text: str | None) -> bool:
    """True when a Strava notice says the account has too little money."""
    low = str(text or "").lower()
    if not low:
        return False
    if f"[{LOW_BALANCE_CODE}]" in low:
        return True
    return any(hint in low for hint in _LOW_BALANCE_HINTS)


def _is_page_chrome_notice(text: str) -> bool:
    """Alert-styled page furniture that never explains a rejected click."""
    low = str(text or "").lower()
    return any(bit in low for bit in (
        "nepřečten", "neprecten", "otevřít zprávy", "otevrit zpravy",
        "unread message", "open messages", "cookie",
    ))


class OrderingMixin:
    """Mixin of :class:`~.strava_client.StravaClient`; uses its session state."""

    def _reconcile_ordered_live(self) -> None:
        """Unions static-parse ordered state with live DOM checks.

        The menu page is JS-driven: a selected meal often carries the
        state only as a live input property, invisible to the static HTML
        regexes. Re-checks every known meal id on the live page and
        corrects/adds that day's entry on a hit. Static hits the live
        check confirms are kept as-is. Never raises.
        """
        try:
            days = list((self.foodDict or {}).items())
            if not days:
                return
            for day, selection in days:
                try:
                    current = (self.orderedDict or {}).get(day)
                    if current and self._verified(current):
                        continue
                    for mid in (selection or {}):
                        if "&-1&" in str(mid):
                            # Day-header control: always reads ordered,
                            # never a meal signal.
                            continue
                        if self._verified(mid):
                            if (self.orderedDict or {}).get(day) != mid:
                                self.log(f"Strava: live check shows {day} ordered as {mid}.")
                                self.orderedDict[day] = mid
                            break
                except Exception:
                    continue
            if self.foodDict and not self.orderedDict:
                self.log("Warning: Strava menu loaded but no ordered meal was detected "
                         "on any day — if orders exist on the web, their markers "
                         "use unknown markup.")
        except Exception as e:
            self.log(f"Warning: live ordered-state re-check failed: {e}")

    def is_food_ordered(self, day_food_identifier):
        if not day_food_identifier:
            return False
        try:
            loc = self.page.locator(f'[id="{day_food_identifier}"]').first
            if loc.count() == 0:
                loc = self.page.locator(f'xpath=//*[@id="{day_food_identifier}"]').first
                if loc.count() == 0:
                    return False

            js_checked = loc.evaluate("""
                el => {
                    if (!el) return false;
                    if (el.checked === true) return true;
                    if (el.getAttribute('checked') !== null && el.getAttribute('checked') !== 'false') return true;
                    if (el.getAttribute('aria-checked') === 'true') return true;
                    try {
                        const lab = el.getAttribute && el.getAttribute('aria-label');
                        if (lab) {
                            const t = String(lab).toLowerCase();
                            if (t.indexOf('objedn') !== -1 && t.indexOf('neobjedn') === -1) return true;
                        }
                    } catch (e) {}
                    if (el.classList && (el.classList.contains('checked') || el.classList.contains('selected') || el.classList.contains('active'))) return true;

                    const id = el.id;
                    if (id) {
                        let label = null;
                        try {
                            const escaped = (window.CSS && CSS.escape) ? CSS.escape(id) : id.replace(/([ #;&,.+*~':"!^$[\\]()=>|\\/@])/g, '\\\\$1');
                            label = document.querySelector('label[for="' + escaped + '"]');
                        } catch(e) {}
                        if (label) {
                            if (label.getAttribute('aria-checked') === 'true') return true;
                            const lcl = label.className || '';
                            if (/\\b(checked|selected|active)\\b/i.test(lcl)) return true;
                        }
                    }
                    return false;
                }
            """)
            if js_checked:
                return True
        except Exception:
            pass
        return False

    def _click_meal(self, meal_id) -> bool:
        """Scrolls to one meal element and clicks it. Counts the click."""
        try:
            try:
                self._dismiss_cookies()
            except Exception:
                pass
            self.bm.scroll_up()
            element = self.bm.scroll_until_visible("id", meal_id)
            if element is None:
                self.log(f"Notice: Food element with ID {meal_id} was not found on screen.")
                return False
            if not self.bm.click_element(element, meal_id):
                return False
            self.clicks_made += 1
            return True
        except Exception as e:
            self.log(f"Exception during stravaOrder for {meal_id}: {e}")
            return False

    def _sibling_meal_ids(self, day_food_identifier, all_day_identifiers=None) -> list:
        """Every other orderable meal of the day (any canteen size)."""
        others: list[str] = []
        if all_day_identifiers:
            others = [str(mid) for mid in all_day_identifiers
                      if str(mid) != str(day_food_identifier) and "&-1&" not in str(mid)]
        if not others:
            # No menu context: derive the two sibling meals from the target
            # id (3-meal canteens).
            try:
                middle = day_food_identifier.rsplit('&')[1][0]
                placeholder_id = int(middle) if middle in ['1', '2', '3'] else -1
            except (IndexError, ValueError):
                placeholder_id = -1
            if placeholder_id != -1:
                other_food_id = ((placeholder_id + 1) % 3) + 1
                others.append(day_food_identifier.rsplit('&')[0] + '&' + str(other_food_id) + '&0')
                third_food_id = ((other_food_id + 1) % 3) + 1
                others.append(day_food_identifier.rsplit('&')[0] + '&' + str(third_food_id) + '&0')
        return others

    def _verified(self, day_food_identifier) -> bool:
        """Live re-check of the page state; never raises."""
        try:
            return bool(self.is_food_ordered(day_food_identifier))
        except Exception:
            return False

    def _order_day_cancel(self, target, all_day_identifiers) -> bool:
        """Cancels a whole day via its ``&-1&`` control.

        That control's own label always reads ordered, so it can't verify
        itself: success = no meal button of the day reads ordered anymore.
        Sibling meals are never clicked (clicking them would order food).
        """
        meals = [str(m) for m in (all_day_identifiers or [])
                 if "&-1&" not in str(m)]
        if not meals:
            # No menu context: legacy click-and-assume.
            return self._click_meal(target)
        if all(not self._verified(m) for m in meals):
            return True
        if not self._click_meal(target):
            return False
        if all(not self._verified(m) for m in meals):
            return True
        self.log(f"Warning: day cancel for {target} could not be verified.")
        return False

    def order(self, day_food_identifier, all_day_identifiers=None) -> bool:
        """Selects one meal, trusting the page state but verifying it.

        Returns True when the wanted meal is selected: immediately (with
        zero clicks) when a live check shows it already ordered, otherwise
        after clicking + re-checking. The legacy sibling-click forcing
        sequence only runs when the direct click didn't take. Returns
        False when the selection could not be verified — callers must not
        record or submit that as ordered.
        """
        if not day_food_identifier:
            return False
        self.last_notice = ""
        if "&-1&" in str(day_food_identifier):
            # Day-level cancel: verified via the day's meals, never via
            # the control itself (its label always reads ordered).
            return self._order_day_cancel(day_food_identifier, all_day_identifiers)
        # Already in the desired state: nothing to cycle through.
        if self._verified(day_food_identifier):
            return True
        # Direct attempt first: one scroll + one click + verify.
        if self._click_meal(day_food_identifier):
            if self._verified(day_food_identifier):
                return True
            # The rejection toast (e.g. no money) can lag behind the click.
            notice = self._wait_for_notice()
            if notice:
                self.last_notice = notice
            if is_low_balance_notice(notice):
                # Each sibling click would be rejected the same way (and on
                # the current frontend could order a meal if it were not):
                # no forcing sequence, the caller stops ordering.
                self.insufficient_balance = True
                self.log(f"Warning: Strava rejected {day_food_identifier}: not enough money "
                         f"on the account. — Strava says: {notice}")
                return False
            self.log(f"Notice: {day_food_identifier} clicked but selection not confirmed, trying the forcing sequence.")
        else:
            self.log(f"Notice: could not click {day_food_identifier} directly, trying the forcing sequence.")
        try:
            legacy_frontend = self._find_save_button(timeout_ms=500) is not None
        except InterruptedError:
            raise
        except Exception:
            legacy_frontend = False
        if not legacy_frontend:
            # Current frontend: every click is saved at once, so cycling
            # sibling meals would really order each of them in turn.
            self.log(f"Warning: Failed to verify order for {day_food_identifier}, leaving previous state.{self._notice_suffix()}")
            return False
        # Save-button frontend only: force a known page state via every
        # sibling first, then the wanted meal last. Missing siblings are
        # skipped (logged) instead of failing the whole order.
        for other_id in self._sibling_meal_ids(day_food_identifier, all_day_identifiers):
            if not self._click_meal(other_id):
                self.log(f"Notice: sibling click {other_id} failed during forcing sequence.")
        if self._click_meal(day_food_identifier) and self._verified(day_food_identifier):
            return True
        self.log(f"Warning: Failed to verify order for {day_food_identifier}, leaving previous state.{self._notice_suffix()}")
        return False

    def _restore_original(self, failed: list, original_ordered: dict) -> None:
        """Best-effort restore of pre-order selections after a failure.

        On the current frontend every click persists immediately, so a
        failed forcing sequence can leave a wrong sibling meal ordered.
        Try to click the original meal back; never raises. Callers still
        return False — a restore attempt is not a success.
        """
        for p in failed or []:
            day = p.get("day")
            original = (original_ordered or {}).get(day)
            if original and "&-1&" in str(original):
                # The pre-order state was "no order" (day-level deorder):
                # nothing to click back, but say so instead of skipping
                # silently.
                self.log(f"{day}: there was no order before — nothing to restore.")
                continue
            if not original:
                continue
            try:
                if self._verified(original):
                    continue
                if self._click_meal(original) and self._verified(original):
                    self.log(f"{day}: original selection restored after the failed order.")
                else:
                    self.log(f"Warning: {day}: could not restore the original selection — check it on the web.")
            except Exception as e:  # noqa: BLE001 - best effort, but never silent
                self.log(f"Warning: {day}: restoring the original selection failed "
                         f"({type(e).__name__}: {e}) — check it on the web.")
                continue

    def _probe_visible(self, locator, timeout_ms: int) -> bool:
        """True when the locator becomes visible within a short probe budget."""
        try:
            locator.wait_for(state="visible", timeout=max(0, int(timeout_ms)))
            return True
        except InterruptedError:
            raise
        except Exception:
            return False

    def _find_save_button(self, timeout_ms: int = 2000):
        """First visible save/order button, or None on the immediate-save frontend.

        Probes are deliberately short (not the full element wait): on the
        current Strava frontend no save button exists at all, so a full
        wait would burn tens of seconds before every fallback selector.
        """
        selectors = [
            # Base-project selector first: the exact save-button classes
            # from the original implementation.
            ".inline-flex.gap-2.items-center.justify-center.no-underline.overflow-hidden.cursor-pointer.transition.duration-300.font-medium.text-primary-content.bg-primary.hover\\:bg-primary-hover.text-base.leading-6.py-3.px-5.rounded-2xl",
            "xpath=//button[contains(., 'Uložit') or contains(., 'Objednat') or contains(., 'Potvrdit')]",
            # Text-based fallback restricted to order/save buttons only —
            # never a generic submit (that could hit a login form).
            "button:has-text('Uložit'), button:has-text('Objednat'), button:has-text('Potvrdit')",
        ]
        for sel in selectors:
            try:
                loc = self.page.locator(sel).first
            except Exception:
                continue
            try:
                if self._probe_visible(loc, timeout_ms):
                    return loc
            except InterruptedError:
                raise
            except Exception:
                continue
        return None

    def _page_notice_text(self) -> str:
        """Visible server notice (toast/alert/warning) explaining rejected clicks.

        The current frontend saves each meal click immediately and rejects
        bad ones with an on-page warning (e.g. insufficient account
        balance) instead of failing the click itself. Returns the notice
        text ("" when none). A coded warning (``Warning [5005] …``) wins
        over generic alert elements, and page chrome that uses alert roles
        (the "Máte 1 nepřečtených zpráv" inbox badge) never counts. Never
        raises.
        """
        try:
            body = self.page.locator("body").first.inner_text() or ""
            m = _CODED_NOTICE_RE.search(str(body))
            if m:
                return re.sub(r"\s+", " ", m.group(0)).strip()[:300]
        except Exception:
            pass
        try:
            for sel in ("[role='alert']", ".toast", "[class*='toast']",
                        "[class*='Toast']", ".alert-danger",
                        ".validation-summary-errors", ".error"):
                try:
                    locs = list(self.page.locator(sel).all())
                except Exception:
                    continue
                for el in locs:
                    try:
                        if not el.is_visible():
                            continue
                        text = (el.inner_text() or "").strip()
                    except Exception:
                        continue
                    # Decorative matches (separators, icon glyphs like
                    # "/") carry no words — only real messages count.
                    if len(text) < 3 or not any(ch.isalnum() for ch in text):
                        continue
                    if _is_page_chrome_notice(text):
                        continue
                    return re.sub(r"\s+", " ", text).strip()[:300]
        except Exception:
            pass
        return ""

    def _wait_for_notice(self, timeout_ms: int = 2000) -> str:
        """Polls briefly for a rejection notice after an unconfirmed click.

        Strava shows its warning toast a moment after the click, so an
        immediate read often finds nothing (or only page chrome). Returns
        as soon as a coded warning appears, else whatever notice is up at
        the end of the budget ("" for none). Never raises except on cancel.
        """
        import time as _time

        deadline = _time.monotonic() + max(0, int(timeout_ms)) / 1000.0
        notice = ""
        while True:
            try:
                notice = self._page_notice_text()
            except Exception:
                notice = ""
            if notice and _CODED_NOTICE_RE.search(notice):
                return notice
            if _time.monotonic() >= deadline:
                return notice
            self._sleep_s(0.25)

    def _notice_suffix(self) -> str:
        """' — <server notice>' for failure logs ("" when the page is silent)."""
        try:
            notice = self._page_notice_text()
        except Exception:
            return ""
        return f" — Strava says: {notice}" if notice else ""

    def save_confirm(self, verify_ids: list = None) -> bool:
        """
        Submits meal orders on the legacy frontend; no-op on the current one.

        The current Strava frontend has no save button — every meal click
        is persisted immediately — so there is nothing to submit and this
        returns True (callers only reach it after verifying the clicks).
        Returns False only when a legacy save button exists but clicking
        it fails. Fail-closed: with no ``verify_ids`` there is nothing to
        verify, so this returns False instead of claiming success.
        Never burns the full element wait probing for a button
        that does not exist. When ``verify_ids`` are given, re-checks that
        each one still reads ordered after the submit (fail-closed).
        """
        if not verify_ids:
            self.log("Warning: Strava save_confirm called with nothing to verify — nothing submitted.")
            return False
        try:
            try:
                confirm_btn = self._find_save_button()
            except InterruptedError:
                raise
            except Exception:
                confirm_btn = None

            if not confirm_btn:
                # Current frontend: clicks persist immediately, there is
                # nothing to submit. Callers verified the clicks already.
                self.log("Strava: no Save button (clicks are saved immediately) — done.")
                return True
            if confirm_btn:
                try:
                    self._dismiss_cookies()
                except Exception:
                    pass
                confirm_btn.evaluate("el => el.scrollIntoView({block: 'center'});")
                # Clicked at most once — a repeated save could submit the
                # orders twice; the checks below catch a click that never
                # dispatched.
                try:
                    confirm_btn.click(timeout=self._nav_ms, once=True)
                except InterruptedError:
                    raise
                except Exception as e:
                    self.log(f"Warning: Strava save click failed ({e}) — orders NOT submitted.")
                    return False
                # The click alone is not success: fail fast on an explicit
                # page error (mirrors Bakalari _verify_submission) instead
                # of reporting ordered lunches for a no-op click.
                try:
                    try:
                        self.page.wait_for_timeout(1500)
                    except Exception:
                        import time as _time

                        _time.sleep(1.5)
                except Exception:
                    pass
                try:
                    _url = self.page.url if isinstance(
                        getattr(self.page, "url", ""), str) else ""
                    _low = _url.lower()
                    if _url and ("login" in _low or "prihlas" in _low or "log-in" in _low):
                        self.log("Warning: Strava save landed on a login page — orders NOT submitted.")
                        return False
                    if _url and ("error" in _low or "chyba" in _low or "exception" in _low):
                        self.log("Warning: Strava save landed on an error page — orders NOT submitted.")
                        return False
                except Exception as e:  # noqa: BLE001 - the checks below still run
                    self.log(f"Notice: could not read the page address after saving: {e}")
                try:
                    try:
                        _err_all = list(self.page.locator(
                            ".alert-danger, .validation-summary-errors, .error, [role='alert']"
                        ).all())
                    except Exception:
                        _err_all = []
                    for _el in _err_all:
                        try:
                            if not _el.is_visible():
                                continue
                            _text = _el.inner_text()
                        except Exception:
                            continue
                        _t = (_text or "").strip()
                        # Decorative matches (separators, icon glyphs like
                        # "/") carry no words — only real messages fail.
                        if len(_t) >= 3 and any(ch.isalnum() for ch in _t):
                            self.log(f"Warning: Strava save error: {_t[:200]}")
                            return False
                except Exception as e:  # noqa: BLE001 - the re-check below still runs
                    self.log(f"Notice: could not scan the page for save errors: {e}")
                if verify_ids:
                    try:
                        _lost = [mid for mid in verify_ids if not self._verified(mid)]
                    except Exception as e:  # noqa: BLE001 - fail closed
                        self.log(f"Warning: could not re-check the saved selection: {e}")
                        _lost = list(verify_ids)
                    if _lost:
                        self.log(f"Warning: Strava save did not stick for {len(_lost)} selection(s) — orders NOT submitted.")
                        return False
                self.log("Strava orders submitted (save button clicked).")
                return True
        except Exception as e:
            self.log(f"Warning: Could not click confirm button: {e}")
            return False
