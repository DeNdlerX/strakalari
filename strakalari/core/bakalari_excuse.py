"""Bakaláři excuse form (Omluvit absenci): filling, lesson pickers and the verified submit."""

import json
import re
import time

from .helpers import format_excuse_template
from .bakalari_common import _norm_date_str

# How long a single-day excuse waits for the form to copy Od into Do
# before reading/retyping Do itself (see fill_excuse_form).
_DO_COPY_GRACE_MS = 2000


class ExcuseFormMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def _send_to_editor(self, text_content: str):
        # Click the editor surface, then type: only typed text (not fill())
        # syncs the DevExpress HtmlEditor content back to the form.
        editor = self.page.locator(
            ".dxheDesignViewArea_NextBlueTheme.dxheViewArea_NextBlueTheme.dxhe-docTypeXHTML.dxheDesignViewArea"
        ).first
        try:
            editor.wait_for(state="visible", timeout=self._element_ms)
            editor.click()
        except Exception:
            # Same element with a looser selector if the theme classes moved.
            editor = self.page.locator(
                ".dxheDesignViewArea_NextBlueTheme, .dxheViewArea_NextBlueTheme, .dxheDesignViewArea"
            ).first
            editor.wait_for(state="visible", timeout=self._element_ms)
            editor.click()
        self.page.keyboard.type(text_content, delay=25)

    def _wait_for_date_value(self, selector: str, expected: str, timeout_ms: int = 3000) -> bool:
        # Waits until DevExpress shows ``expected`` in the date box.
        # Compares the full date normalized EXACTLY like _norm_date_str
        # (trimmed, spaces around dots collapsed, no zero padding) — the
        # server-copied value carries a trailing space. Backslash-free JS
        # on purpose. True on match, False on timeout; never raises.
        norm = _norm_date_str(expected)
        if not norm:
            return False
        js_probe = (
            "() => { try {"
            " var el = document.querySelector(ARG_SELECTOR);"
            " var raw = ((el && el.value) || '').trim();"
            " var parts = raw.split('.');"
            " for (var i = 0; i < parts.length; i++) {"
            " var q = parts[i].trim();"
            " while (q.length > 1 && q.charAt(0) === '0') q = q.substring(1);"
            " parts[i] = q; }"
            " var v = parts.join('.').trim();"
            " return v && v === ARG_NORM;"
            " } catch (e) { return false; } }"
        ).replace("ARG_SELECTOR", json.dumps(selector)).replace("ARG_NORM", json.dumps(norm))
        try:
            self.page.wait_for_function(js_probe, timeout=timeout_ms)
            return True
        except Exception:
            return False

    def _retype_date(self, locator, selector: str, value: str, timeout_ms: int) -> bool:
        # Single retype after a late postback: re-reads first (the value
        # may have arrived meanwhile), retypes once, waits. Never raises.
        try:
            try:
                _cur = locator.input_value(timeout=timeout_ms)
            except Exception:
                _cur = ""
            if _cur and _norm_date_str(_cur) == _norm_date_str(value):
                return True
            locator.click()
            locator.fill("")
            locator.press_sequentially(value, delay=10)
            locator.press("Enter")
        except Exception:
            return False
        return bool(self._wait_for_date_value(selector, value, timeout_ms=timeout_ms))

    def _wait_for_editor_sync(self, text_content: str, timeout_ms: int = 8000) -> bool:
        # The HtmlEditor syncs typed text back to the form asynchronously:
        # poll until the text shows up so an empty form is never sent.
        # The editor surface is an iframe, so iframes are searched too.
        # True when the text surfaced, False on timeout; never raises.
        snippet = "".join(str(text_content or "").split())[:20]
        if not snippet:
            return True
        js_probe = (
            "() => { try {"
            " const norm = (s) => Array.from(s || '').filter("
            "function(c) { return c.trim() !== ''; }).join('');"
            " const target = norm(ARG_SNIPPET);"
            " if (!target) return true;"
            " if (norm(document.body && document.body.innerText).indexOf(target) !== -1)"
            " return true;"
            " var frames = document.querySelectorAll('iframe');"
            " for (var i = 0; i < frames.length; i++) {"
            " try { var d = frames[i].contentDocument;"
            " if (d && norm(d.body && d.body.innerText).indexOf(target) !== -1)"
            " return true;"
            " } catch (e) {} }"
            " return false;"
            " } catch (e) { return false; } }"
        ).replace("ARG_SNIPPET", json.dumps(snippet))
        try:
            self.page.wait_for_function(js_probe, timeout=timeout_ms)
            return True
        except Exception:
            return False

    def _verify_submission(self) -> bool:
        # Success = the form detaches after the click; an explicit
        # server-side validation error fails fast.
        self.log("Excuse form: submitting...")
        try:
            send_btn = self.page.locator("#button_poslat").first
            self._wait_for_module("#button_poslat")
            # The submit is a server postback — the click itself can stall
            # behind the triggered navigation on a slow link.
            send_btn.click(timeout=self._nav_ms, once=True)
        except Exception as e:
            # The click itself failed — nothing was sent.
            self.log(f"Excuse submit click failed: {e}")
            return False
        # The submit is a postback: wait for the form to detach with the
        # navigation budget. Never retry the click — a second click could
        # send the excuse twice.
        try:
            send_btn.wait_for(
                state="detached",
                timeout=self._nav_ms)
            return True
        except Exception:
            pass
        try:
            error_loc = self.page.locator(".dxpc-content, .alert-danger, .validation-summary-errors, .dxheErrorText").first
            if error_loc.count() > 0 and error_loc.is_visible():
                err_text = (error_loc.inner_text() or "").strip()
                if err_text:
                    self.log(f"Bakalari submission error: {err_text}")
                    return False
        except Exception:
            pass
        self.log("Warning: excuse form still open after submit, NOT treating as sent (will retry).")
        return False

    def _visible_option_index(self, xpath_opt: str) -> int | None:
        """Index of the first *visible* dropdown row, None when all hidden.

        DevExpress renders hidden copies of the option rows (closed popup,
        template rows) — ``.first`` can resolve to one that stays invisible
        forever, and no scroll makes it visible (end-lesson 6 after the
        ArrowUp reset hit exactly this: row in DOM, click failing 30 s with
        ``element is not visible``), so all matches are probed.
        """
        try:
            rows = self.page.locator(xpath_opt).all()
        except InterruptedError:
            raise
        except Exception:
            return None
        for idx, row in enumerate(rows or []):
            try:
                if row.is_visible():
                    return idx
            except Exception:
                continue
        return None

    def _lesson_committed(self, combo_id: str, period) -> bool:
        """True when the combo box positively shows ``period`` — or when the
        display cannot be read on this frontend (then it must not block).

        Catches a click that landed on the wrong row (stale index after a
        DevExpress re-render): selecting 1 instead of 6 and submitting it
        is worse than aborting. Only a positively-read mismatch fails.
        """
        try:
            period_int = int(period)
        except (TypeError, ValueError):
            return True
        try:
            val = self.page.locator(f"#{combo_id}_I").first.input_value(timeout=1000)
        except InterruptedError:
            raise
        except Exception:
            return True
        try:
            text = str(val or "").strip()
        except Exception:
            return True
        if not text:
            return True
        # The hour is the LEADING number of the label ("6. hodina 8:00-8:45"
        # also contains 8). No leading number = unreadable, never blocks.
        try:
            lead = re.match(r"(\d+)", text)
        except Exception:
            return True
        if not lead:
            return True
        try:
            return int(lead.group(1)) == period_int
        except (TypeError, ValueError):
            return True

    def _select_lesson_safely(self, period, which=0) -> bool:
        # Click the combo box, reset the dropdown with arrow keys when
        # crossing halves, then click the option row — DevExpress combos
        # ignore fill().
        combo_id = "comboExcuseToPeriod" if which == 1 else "comboExcuseFromPeriod"
        try:
            period_int = int(period)
        except (TypeError, ValueError):
            period_int = period
        xpath_opt = f"xpath=//td[contains(@id, '{combo_id}') and b[normalize-space(.)='{period}']]"
        try:
            self.page.locator(f"#{combo_id}").first.click()
            # The rows populate via callback after the date commits: wait
            # until the wanted row is attached (it may be scrolled away).
            try:
                self.page.locator(xpath_opt).first.wait_for(
                    state="attached",
                    timeout=self._settle_ms())
            except Exception:
                pass
            # End lesson below 7: reset to top first; start lesson above 6:
            # reset to bottom first (13 presses cover the whole list).
            if which == 1 and isinstance(period_int, int) and period_int < 7:
                for _ in range(13):
                    self.page.keyboard.press("ArrowUp")
                    self._sleep_s(0.05)
            elif which == 0 and isinstance(period_int, int) and period_int > 6:
                for _ in range(13):
                    self.page.keyboard.press("ArrowDown")
                    self._sleep_s(0.05)

            # DevExpress keeps hidden copies of the rows: click the visible
            # one, reopening the popup once if none is. Two attempts cover
            # a stale index and a click the combo never committed.
            for attempt in range(2):
                if attempt > 0:
                    self.page.locator(f"#{combo_id}").first.click()
                idx = self._visible_option_index(xpath_opt)
                if idx is None:
                    self.page.locator(f"#{combo_id}").first.click()
                    try:
                        self.page.locator(xpath_opt).first.wait_for(
                            state="attached",
                            timeout=self._settle_ms())
                    except Exception:
                        pass
                    idx = self._visible_option_index(xpath_opt)
                if idx is None:
                    break
                opt = self.page.locator(xpath_opt).nth(idx)
                try:
                    opt.scroll_into_view_if_needed(timeout=self._settle_ms())
                except Exception:
                    pass
                try:
                    if not opt.is_visible():
                        continue
                except Exception:
                    pass
                try:
                    opt.click()
                except Exception:
                    continue
                # Let DevExpress commit the selection before the next combo.
                self._sleep_s(0.5)
                if self._lesson_committed(combo_id, period):
                    return True
            self.log(f"Warning: lesson option {period} not selected, aborting excuse (no submit).")
            return False
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: select_lesson_safely({period}, {which}) encountered: {e}")
            return False

    def fill_excuse_form(self, day_start, day_end, start_lesson=None, end_lesson=None, custom_text=None, is_days=False, excuse_type: str = None) -> bool:
        """Navigates to the excuse form and fills everything except submit.

        Same steps as :meth:`execute_excuse` up to the editor sync, but
        never clicks the send button. Used by ``dry_run`` mode so the user
        sees the filled form in the browser without sending anything.
        Returns True when the form was filled, False on failure.
        """
        # Re-login when needed: without this an expired session dies in
        # locator timeouts instead of recovering (login() is a no-op when
        # already authenticated).
        self._open_module(".ico32-modul-vyuka", ".ico32-modul-komens",
                          ".ico32-modul-omluvitAbsenci")
        # Opening the form is a navigation: wait for it with that budget.
        try:
            self.page.locator("#cphmain_excuseFromDate_I").first.wait_for(state="visible", timeout=self._nav_ms)
        except Exception:
            pass

        if is_days:
            self.page.locator("#cphmain_cbExcuseWholeDay_S_D").click()
        else:
            self.page.locator("#cphmain_teachingLesson_S_D").click()

        # Each date is cleared, typed and confirmed with ENTER; every ENTER
        # fires a postback that re-renders the form, so each value is
        # waited out instead of retyped.
        settle_ms = self._settle_ms()
        _t_phase = time.monotonic()
        date_from = self.page.locator("#cphmain_excuseFromDate_I").first
        date_from.wait_for(state="visible", timeout=self._element_ms)
        date_from.click()
        date_from.fill("")
        date_from.press_sequentially(day_start, delay=10)
        date_from.press("Enter")
        if not self._wait_for_date_value("#cphmain_excuseFromDate_I", day_start,
                                         timeout_ms=settle_ms):
            # One retype: the value may have arrived late via postback.
            # A date DevExpress never accepts must abort, never submit.
            if not self._retype_date(date_from, "#cphmain_excuseFromDate_I",
                                     day_start, settle_ms):
                self.log(f"Warning: Od date not accepted ({day_start}), aborting excuse (no submit).")
                return False
        self.log(f"From date entered in {time.monotonic() - _t_phase:.1f} s.")
        _t_phase = time.monotonic()

        date_to = self.page.locator("#cphmain_excuseToDate_I").first
        date_to.wait_for(state="visible", timeout=self._element_ms)
        _do_how = ""
        if _norm_date_str(day_start) == _norm_date_str(day_end):
            # Single-day excuse: the form may copy Od into Do. Clicking Do
            # blurs Od (committing it and triggering the copy); then wait
            # briefly for the copied value and read it only as a fallback.
            # The grace stays short: in practice the copy usually never
            # lands, and waiting the navigation budget here cost ~60 s per
            # excuse before the retype below (which commits in ~1 s).
            _do_how = " (copied by the form)"
            try:
                date_to.click()
            except InterruptedError:
                raise
            except Exception:
                pass
            if not self._wait_for_date_value(
                    "#cphmain_excuseToDate_I", day_end,
                    timeout_ms=min(_DO_COPY_GRACE_MS, settle_ms)):
                # The copied Do value may arrive late: one confirming read,
                # retype only on a proven mismatch (each ENTER re-renders).
                try:
                    _to_val = date_to.input_value(timeout=settle_ms)
                except InterruptedError:
                    raise
                except Exception:
                    _to_val = ""
                if not _to_val:
                    # Prázdné/nečitelné uprostřed postbacku není neshoda —
                    # formulář se ještě přenačítá. Počkat na připojení
                    # a přečíst jednou znovu, nepřepisovat naslepo.
                    try:
                        date_to.wait_for(state="attached", timeout=settle_ms)
                    except Exception:
                        pass
                    try:
                        _to_val = date_to.input_value(timeout=settle_ms)
                    except InterruptedError:
                        raise
                    except Exception:
                        _to_val = ""
                if not (_to_val and _norm_date_str(_to_val) == _norm_date_str(day_end)):
                    _do_how = " (retyped)"
                    date_to.click()
                    date_to.fill("")
                    date_to.press_sequentially(day_end, delay=10)
                    date_to.press("Enter")
                    if not self._wait_for_date_value("#cphmain_excuseToDate_I", day_end,
                                                     timeout_ms=settle_ms):
                        self.log(f"Warning: Do date not accepted ({day_end}), aborting excuse (no submit).")
                        return False
                else:
                    _do_how = " (confirmed by reading)"
        else:
            date_to.click()
            date_to.fill("")
            date_to.press_sequentially(day_end, delay=10)
            date_to.press("Enter")
            if not self._wait_for_date_value("#cphmain_excuseToDate_I", day_end,
                                             timeout_ms=settle_ms):
                if not self._retype_date(date_to, "#cphmain_excuseToDate_I",
                                         day_end, settle_ms):
                    self.log(f"Warning: Do date not accepted ({day_end}), aborting excuse (no submit).")
                    return False

        if not is_days and start_lesson is not None and end_lesson is not None:
            self.log(f"To date entered in {time.monotonic() - _t_phase:.1f} s{_do_how}.")
            _t_lesson = time.monotonic()
            if not self._select_lesson_safely(start_lesson, 0):
                self.log(f"Warning: start-lesson selection failed ({start_lesson}), aborting excuse (no submit).")
                return False
            self.log(f"Start lesson selected in {time.monotonic() - _t_lesson:.1f} s.")
            _t_lesson = time.monotonic()
            if not self._select_lesson_safely(end_lesson, 1):
                self.log(f"Warning: end-lesson selection failed ({end_lesson}), aborting excuse (no submit).")
                return False
            self.log(f"End lesson selected in {time.monotonic() - _t_lesson:.1f} s.")
            self.log("Lessons selected, typing the excuse text…")

        if not custom_text:
            def _first_text(templates, default):
                # Skip blank templates: they would submit an empty excuse.
                for candidate in templates or []:
                    if str(candidate or "").strip():
                        return candidate
                return default

            if is_days:
                date_range = f"{day_start} – {day_end}" if day_start != day_end else day_start
                custom_text = format_excuse_template(_first_text(self.long_absence_excuses, "Omluvte prosím absenci."), date_str=date_range, signature_str=self.signature)
            else:
                lessons_range = f"{start_lesson}. – {end_lesson}." if start_lesson != end_lesson else str(start_lesson)
                if (excuse_type or "").lower() == "income":
                    templates = self.late_income_excuses or ["Omluvte prosím pozdní příchod."]
                elif (excuse_type or "").lower() == "soon":
                    templates = self.left_soon_excuses or ["Omluvte prosím předčasný odchod."]
                else:
                    templates = self.short_absence_excuses or ["Omluvte prosím absenci."]
                custom_text = format_excuse_template(_first_text(templates, "Omluvte prosím absenci."), date_str=day_start, lessons_str=lessons_range, signature_str=self.signature)

        _t_sync = time.monotonic()
        self._send_to_editor(custom_text)
        self.log("Text entered, waiting for the editor to sync…")
        if not self._wait_for_editor_sync(custom_text,
                                          timeout_ms=max(8000, self._element_ms)):
            self.log("Warning: excuse text sync not confirmed, aborting excuse (no submit).")
            return False
        self.log(f"Editor synced in {time.monotonic() - _t_sync:.1f} s.")
        return True

    def execute_excuse(self, day_start, day_end, start_lesson=None, end_lesson=None, custom_text=None, is_days=False, excuse_type: str = None):
        if not self.fill_excuse_form(day_start, day_end, start_lesson=start_lesson, end_lesson=end_lesson, custom_text=custom_text, is_days=is_days, excuse_type=excuse_type):
            return False
        return self._verify_submission()
