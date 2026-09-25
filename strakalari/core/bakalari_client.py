"""Bakaláři web client (Playwright): session, login and navigation.

The class is assembled from mixins so no single file carries the whole
scraper: ``bakalari_timetable`` (weekly + stable timetable),
``bakalari_data`` (marks, absence, sent excuses, substitutions, baseline)
and ``bakalari_excuse`` (the excuse form). Pure parsing helpers live in
``bakalari_common`` and are re-exported here for existing imports.
"""

from .helpers import clear_input, decrypt_strict, is_encrypted_flag
from .i18n import t
from .error_report import (
    UserError,
    is_timeout_error,
    timeout_user_message,
)
from .bakalari_common import (
    parse_timetable_detail,
    _html_lesson_days,
    week_offsets,
)
from .bakalari_data import DataMixin
from .bakalari_excuse import ExcuseFormMixin
from .bakalari_timetable import TimetableMixin

__all__ = ["BakalariClient", "parse_timetable_detail", "week_offsets", "_html_lesson_days"]


class BakalariClient(TimetableMixin, DataMixin, ExcuseFormMixin):
    """Bakaláři web session: login and navigation; scraping and the excuse
    form live in the mixins (bakalari_timetable / bakalari_data / bakalari_excuse)."""

    def __init__(self, browser_manager, config_data, logger=None):
        self.bm = browser_manager
        # Cancel-aware page: every blocking wait is chunked so Zrušit
        # preempts the run within ~250 ms instead of after the full
        # 15-60 s timeout. The predicate is live — the GUI worker sets
        # the flag later via cancel_requested / cancel_callback.
        from .cancel import wrap_page

        self.page = wrap_page(self.bm.page, self._cancelled)
        self.config = config_data

        self.bakalari_url = self.config.get("bakalari_url", "")
        self.username = self.config.get("bakalari_username", "")
        self.password = self.config.get("bakalari_password", "")
        self.password_encrypted = self.config.get("bakalari_password_encrypted", False)
        try:
            self.go_back_weeks = min(max(int(self.config.get("go_back_weeks", 4)), 0), 52)
        except (TypeError, ValueError):
            self.go_back_weeks = 4
        try:
            self.go_forward_weeks = min(max(int(self.config.get("go_forward_weeks", 1)), 0), 8)
        except (TypeError, ValueError):
            self.go_forward_weeks = 1
        self.signature = self.config.get("your_signature", "")

        self.late_income_excuses = self.config.get("late_income_excuses", [])
        self.left_soon_excuses = self.config.get("left_soon_excuses", [])
        self.long_absence_excuses = self.config.get("long_absence_excuses", [])
        self.short_absence_excuses = self.config.get("short_absence_excuses", [])

        self.logger = logger
        self.logged_in = False
        # Cooperative cancellation (mirrors StravaClient.cancel_requested;
        # set from Strakalari.fetchBakalariData before each fetch).
        self.cancel_requested = False
        # Optional live predicate (e.g. GUI state) polled alongside the flag
        # so a cancel issued mid-fetch is honored without re-setting flags.
        self.cancel_callback = None

        self.timetable_sources = []
        self.timetableData = {}
        self.absencePercentages = {}
        # Full overview rows from the same page: elapsed hours + school
        # verdict badges per subject (see extract_absence_details).
        self.absenceDetails = {}
        # School-official subject set (Výuka → Přehled předmětů): only
        # these count toward absence limits. Empty until fetched.
        self.subjectDirectory = {}
        # Průběžná klasifikace (see get_grades): {subject: [{Grade, Weight, Date}]},
        # each subject list sorted by date (oldest first). Empty until fetched.
        self.grades = {}
        # Last grades-scrape failure ("") when fresh; non-empty means the
        # displayed marks are last-known/stale, not freshly scraped.
        self.grades_error = ""
        # Already-sent excuses scraped from Komens → Odeslané
        # (see fetch_sent_excuses). Empty until synced; never part of
        # fetch_data() so routine refreshes stay read-only and fast.
        self.sentExcuses = []
        # Last sent-excuse sync failure ("") = fresh/OK; non-empty = unknown.
        self.sentExcuses_error = ""
        # Learned stable timetable (SlotBaseline per slot) + actual-vs-stable
        # diffs for the loaded weeks — filled by update_stable_baseline()
        # during fetch_data() so the run itself compares against stable.
        self.stableBaseline = {}
        # True when the baseline is the scraped "Stálý" template week
        # (complete: empty slots are free periods). False for the learned
        # fallback, where an empty slot only means "no data".
        self.stable_complete = False
        # Last absence-scrape failure ("") when fresh; non-empty means the
        # displayed percentages are last-known/stale, not freshly scraped.
        self.absence_error = ""
        self.weekChanges = []
        # Raw scraped "Stálý rozvrh" (stable timetable) view, keyed by day
        # like timetableData. Empty when the button wasn't found — the
        # baseline is then learned from the actual weeks instead.
        self.stableTimetableData = {}
        # Personal substitution feed (Výuka → Suplování), tri-state like
        # sentExcuses: a list (possibly empty) = the feed was actually
        # read; None = unknown (not yet synced, failed or skipped).
        self.substitutions = None
        self.substitutions_error = ""

    def log(self, msg):
        if self.logger:
            self.logger(msg)

    def _cancelled(self) -> bool:
        if getattr(self, "cancel_requested", False):
            return True
        cb = getattr(self, "cancel_callback", None)
        if callable(cb):
            try:
                return bool(cb())
            except Exception:
                return False
        return False

    def _raise_if_cancelled(self) -> None:
        """Aborts the run promptly when the user hit Zrušit."""
        from .cancel import raise_if_cancelled

        raise_if_cancelled(self._cancelled)

    # -- Slow-connection tolerant timeouts (seconds in config) --
    def _seconds(self, key: str, default: float) -> float:
        import math as _math

        try:
            value = float(self.config.get(key, default))
        except (TypeError, ValueError):
            return default
        # Negative/NaN/inf timeouts come from hand-edited configs; fall back
        # instead of crashing waits (int(nan * 1000) raises).
        try:
            if not _math.isfinite(value) or value < 0:
                return default
        except (TypeError, ValueError):
            return default
        return value

    def _timeout_ms(self, key: str, default_ms: int) -> int:
        return int(self._seconds(key, default_ms / 1000.0) * 1000)

    @property
    def _page_load_ms(self) -> int:
        return self._timeout_ms("page_load_timeout_s", 60000)

    @property
    def _element_ms(self) -> int:
        return self._timeout_ms("element_wait_s", 30000)

    @property
    def _week_settle_s(self) -> float:
        return self._seconds("week_switch_delay_s", 2.5)

    @property
    def _nav_ms(self) -> int:
        # Budget for waits after a navigation-triggering click (module
        # menu entries are full page loads): the page-load setting, never
        # less than the element setting. Event-driven, so fast pages pay
        # nothing.
        try:
            return max(int(self._element_ms), int(self._page_load_ms))
        except Exception:
            return 60000

    def _open_module(self, *selectors: str) -> None:
        """Logs in when needed, then clicks through the module menu.

        Never navigates by URL: right after login() the app is usually on
        screen, and a ``_goto()`` would restart the page load on a slow
        link. Every menu click is itself a navigation, so each following
        entry is waited out with the navigation budget.
        """
        self.login()
        self.page.locator(selectors[0]).first.wait_for(
            state="visible", timeout=self._element_ms)
        self._dismiss_cookies()
        for selector in selectors:
            self._wait_for_module(selector)
            self.page.locator(selector).first.click(timeout=self._nav_ms, once=True)

    def _wait_for_module(self, selector: str) -> None:
        """Waits for a module menu entry with the navigation budget.

        Same contract as a plain visible-wait, but tolerates the full
        page load the preceding menu click triggered. Never navigates.
        """
        self._raise_if_cancelled()
        self.page.locator(selector).first.wait_for(
            state="visible", timeout=self._nav_ms)

    def _settle_ms(self) -> int:
        # Ceiling for AJAX content waits (week switch, stable view,
        # absence, grades, directory, outbox): week_switch_delay_s is the
        # floor, element_wait_s the ceiling. Event-driven.
        try:
            return max(int(self._week_settle_s * 1000),
                       int(self._element_ms))
        except Exception:
            return 30000

    def _wait_for_page_settled(self, timeout_ms: int) -> bool:
        """Waits for the current page to finish loading, never navigating.

        On a slow link the page is often still loading in the background
        when a wait expires — re-issuing a navigation (\"refresh\") then
        restarts the load from zero and it may never finish. Callers must
        wait out the same load instead. Returns True when
        ``document.readyState`` reached interactive/complete, False on
        timeout. Never raises except ``InterruptedError`` on cancel.
        """
        try:
            total = max(0, int(timeout_ms))
        except (TypeError, ValueError):
            return False
        if total <= 0:
            return False
        try:
            self.page.wait_for_function(
                "() => document.readyState === 'interactive'"
                " || document.readyState === 'complete'",
                timeout=total,
            )
            return True
        except InterruptedError:
            raise
        except Exception:
            return False

    def _goto(self, url: str):
        # One navigation, never re-issued: re-navigating restarts a slow
        # load from zero (cancel.goto waits the same load out instead).
        # Logged so slow-net logs show exactly when a page was loaded.
        self.log(f"Navigating to {url} (budget {self._page_load_ms // 1000} s)...")
        try:
            self.page.goto(url, timeout=self._page_load_ms, wait_until="domcontentloaded")
        except InterruptedError:
            raise
        except Exception as exc:
            self._raise_if_cancelled()
            if is_timeout_error(exc):
                self.log(f"Navigation timeout after {self._page_load_ms // 1000} s: {exc}")
                raise UserError(timeout_user_message()) from exc
            raise

    def _sleep_s(self, seconds: float):
        from .cancel import sleep as _cancel_sleep

        _cancel_sleep(self.page, self.bm, seconds, self._cancelled)

    def _auth_state(self, timeout_ms: int) -> str:
        """Current page auth state: ``authenticated`` | ``login`` | ``unknown``.

        A single event-driven wait for EITHER the app module menu or the
        login form — returns the moment one appears, so (unlike two
        sequential locator waits) it never burns a full timeout in the
        common case. ``unknown`` = neither appeared (slow net, error
        page, fresh blank tab). Never raises.
        """
        try:
            self.page.wait_for_function(
                "() => document.body && ("
                "!!document.querySelector('.ico32-modul-vyuka') "
                "|| !!document.querySelector('#username'))",
                timeout=timeout_ms,
            )
        except InterruptedError:
            raise
        except Exception:
            return "unknown"
        try:
            if self.page.locator(".ico32-modul-vyuka").first.is_visible():
                return "authenticated"
        except Exception:
            pass
        try:
            if self.page.locator("#username").first.is_visible():
                return "login"
        except Exception:
            pass
        return "unknown"

    def _login_error_text(self) -> str:
        """Visible login-failure message, or ``""`` when none. Never raises.

        Bakalari answers wrong credentials on the same login form (no
        navigation), so waiting blindly for the post-login menu burns the
        whole element budget before reporting a useless slice timeout.
        Dedicated error nodes are probed first, with a failure-keyword
        scan of the body text as fallback (trusted only while the login
        form is still on screen).
        """
        page = self.page
        if page is None:
            return ""
        for sel in (
            ".login-error",
            ".validation-summary-errors",
            ".alert-danger",
            ".dx-invalid-message",
            "#loginError",
        ):
            try:
                loc = page.locator(sel).first
                if loc.is_visible():
                    text = (loc.inner_text() or "").strip()
                    if text:
                        return text[:300]
            except Exception:
                continue
        try:
            form_visible = page.locator("#username").first.is_visible()
        except Exception:
            return ""
        if not form_visible:
            return ""
        try:
            body = page.evaluate(
                "() => (document.body ? document.body.innerText : '')"
            ) or ""
        except Exception:
            return ""
        lowered = str(body).lower()
        for keyword in (
            "nesprávné", "neplatné", "chybné", "neúspěšné",
            "špatné", "nespravne", "invalid", "incorrect",
        ):
            idx = lowered.find(keyword)
            if idx >= 0:
                return str(body)[max(0, idx - 40):idx + 120].strip()[:300]
        return ""

    def _wait_for_login_result(self, timeout_ms: int) -> None:
        """Waits for the post-login menu, failing fast on bad credentials.

        Returns on success. Raises ``UserError`` (never a raw Playwright
        timeout) when Bakalari reports wrong credentials or the menu
        never appears within ``timeout_ms`` — with page diagnostics
        (URL, login-form state) so the log says what actually happened.
        """
        import time as _time

        total_ms = max(0, int(timeout_ms))
        deadline = _time.monotonic() + total_ms / 1000.0
        last_exc: Exception | None = None
        while True:
            self._raise_if_cancelled()
            try:
                if self.page.locator(".ico32-modul-vyuka").first.is_visible():
                    return
            except InterruptedError:
                raise
            except Exception as exc:
                last_exc = exc
            err_text = self._login_error_text()
            if err_text:
                raise UserError(t("bak_login_rejected", detail=err_text[:200]))
            remaining_ms = int((deadline - _time.monotonic()) * 1000)
            if remaining_ms <= 0:
                break
            try:
                self.page.locator(".ico32-modul-vyuka").first.wait_for(
                    state="visible", timeout=min(1000, remaining_ms))
                return
            except InterruptedError:
                raise
            except Exception as exc:
                last_exc = exc
        diag = []
        try:
            diag.append(f"url={self.page.url}")
        except Exception:
            pass
        try:
            form = self.page.locator("#username").first.is_visible()
            diag.append(f"login_form={'visible' if form else 'gone'}")
        except Exception:
            pass
        detail = ", ".join(diag)
        raise UserError(t("bak_login_timeout", seconds=max(1, total_ms // 1000),
                            detail=detail)) from last_exc

    def login(self):
        url = str(self.bakalari_url or "").strip()
        if not url:
            raise UserError(t("bak_missing_url"))
        if not str(self.username or "").strip():
            raise UserError(t("bak_missing_user"))
        if not str(self.password or "").strip():
            raise UserError(t("bak_missing_password"))
        if url and not url.startswith(("http://", "https://")):
            url = f"https://{url}"
        probe_ms = max(1000, min(self._element_ms, 10000))
        # Cold start: a fresh browser profile opens on about:blank — no
        # session, no load. Probing it would only burn seconds of blank
        # screen, so the one necessary navigation happens at once.
        try:
            _cur_url = str(self.page.url or "").strip().lower()
        except Exception:
            _cur_url = ""
        _cold_start = _cur_url in ("", "about:blank", "blank", "data:,")
        # Fast path: every fetch and excuse submit calls login(), so a
        # still-valid session must not navigate. The session is probed on
        # the page (server sessions expire), never trusted from a flag.
        if not _cold_start:
            try:
                if self._auth_state(min(probe_ms, 3000)) == "authenticated":
                    self.logged_in = True
                    return
            except InterruptedError:
                raise
            except Exception:
                pass
        # Slow link: a page still loading after the short probe is waited
        # out, never refreshed. Only a settled page showing neither the
        # app nor the login form earns a fresh navigation.
        _state = "unknown"
        if not _cold_start:
            try:
                _state = self._auth_state(min(probe_ms, 3000))
            except InterruptedError:
                raise
            except Exception:
                _state = "unknown"
            if _state == "authenticated":
                self.logged_in = True
                return
        _navigated = False
        if _cold_start:
            if url.startswith("http://"):
                self.log("Warning: Bakaláři URL uses plain http:// — credentials will travel unencrypted.")
            self._goto(url)
            _navigated = True
            _state = "unknown"
        elif _state != "login":
            # The page had neither the app nor the form after the fast
            # probes — give its load the full page budget before deciding
            # anything (this is the wait the slow link needs).
            self.log("Waiting for the Bakaláři page to load…")
            try:
                _settled = self._wait_for_page_settled(self._page_load_ms)
            except InterruptedError:
                raise
            except Exception:
                _settled = False
            if _settled:
                try:
                    _state = self._auth_state(probe_ms)
                except InterruptedError:
                    raise
                except Exception:
                    pass
                if _state == "authenticated":
                    self.logged_in = True
                    return
            if _settled and _state != "login":
                if url.startswith("http://"):
                    self.log("Warning: Bakaláři URL uses plain http:// — credentials will travel unencrypted.")
                self._goto(url)
                _navigated = True
            # else: still loading after the full page budget, or the login
            # form appeared while settling — no navigation either way.
        if _navigated:
            # A leftover consent banner can cover the login form — clear it
            # before probing (never raises; no-op when absent).
            if not self._dismiss_cookies():
                self.log("Warning: cookie banner is still up — continuing, field fills will retry around it.")
            # The fresh navigation may land straight in the app (session
            # cookie still valid) — but never assume it, just check.
            if self._auth_state(probe_ms) == "authenticated":
                self.logged_in = True
                return
        elif _state != "login":
            # Form not confirmed on screen: one decisive wait for the app
            # or the form, then fail fast — a page showing nothing after
            # its load budget plus this wait is hung, not slow.
            try:
                _state = self._auth_state(self._nav_ms)
            except InterruptedError:
                raise
            except Exception:
                _state = "unknown"
            if _state == "authenticated":
                self.logged_in = True
                return
            if _state != "login":
                raise UserError(t("bak_not_loading", seconds=self._page_load_ms // 1000))

        try:
            # Type key by key: DevExpress login inputs can ignore fill().
            self._raise_if_cancelled()
            user_loc = self.page.locator("#username").first
            user_loc.wait_for(state="visible", timeout=self._element_ms)
            user_loc.click()
            # The form keeps the username after a failed login postback:
            # typing on top of it would double it.
            clear_input(user_loc)
            user_loc.press_sequentially(self.username, delay=10)

            if is_encrypted_flag(self.password_encrypted):
                correct_password = decrypt_strict(self.password)
                if correct_password is None:
                    raise UserError(t("bak_password_undecryptable"))
            else:
                correct_password = self.password

            pass_loc = self.page.locator("#password").first
            pass_loc.wait_for(state="visible", timeout=self._element_ms)
            pass_loc.click()
            clear_input(pass_loc)
            pass_loc.press_sequentially(correct_password, delay=10)

            login_btn = self.page.locator("#loginButton").first
            login_btn.wait_for(state="visible", timeout=self._element_ms)
            self._raise_if_cancelled()
            # The login submit is a full postback navigation — the click
            # itself can stall behind it on a slow link, so it gets the
            # navigation budget, not the bare element one.
            login_btn.click(timeout=self._nav_ms, once=True)

            # Wait for the post-login menu with the navigation budget;
            # wrong credentials still fail fast (error probe every second).
            self._wait_for_login_result(self._nav_ms)
            self.logged_in = True
            # The cookies banner pops up after login and overlays the
            # modules — dismiss it before any further clicks.
            self._dismiss_cookies()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Login failed: {e}")
            raise
