import json
import os
import re

from .helpers import clear_input, decrypt_strict, is_encrypted_flag, _resolve_path, example_path_for
from .config import _looks_like_placeholder
from .extractors.strava import extract_food_data, extract_ordered_food
from .error_report import UserError, is_timeout_error, timeout_user_message
from .i18n import t

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


class StravaClient:
    def __init__(self, browser_manager, config_data, logger=None):
        self.bm = browser_manager
        # Cooperative cancellation (mirrors BakalariClient; set from
        # Strakalari.fetchStravaData before each fetch).
        self.cancel_requested = False
        # Optional live predicate (e.g. GUI state) polled alongside the
        # flag so a cancel issued mid-fetch is honored without re-setting.
        self.cancel_callback = None
        # Cancel-aware page: every blocking wait is chunked so Zrušit
        # preempts the run instead of waiting out the full 15-60 s timeout.
        from .cancel import wrap_page

        self.page = wrap_page(self.bm.page, self._cancelled)
        self.config = config_data

        self.strava_url = self.config.get("strava_url", "https://strava.cz")

        # Legacy key aliases (read-only compat: nothing writes strava_id /
        # strava_user / strava_enable anymore; the settings UI uses the
        # canonical strava_canteen_id / strava_username / use_strava keys).
        raw_strava_id = self.config.get("strava_canteen_id", "") or self.config.get("strava_id", "")
        self.strava_id = str(raw_strava_id).strip()
        self.strava_username = self.config.get("strava_username", "") or self.config.get("strava_user", "")
        self.strava_password = self.config.get("strava_password", "")
        self.strava_password_encrypted = self.config.get("strava_password_encrypted", False)
        self.strava_enable = self.config.get("use_strava", self.config.get("strava_enable", True))

        self.strava_blacklist = _resolve_path(self.config.get("strava_blacklist", "./strava_blacklist.json"))
        self.logger = logger
        self.logged_in = False

        self.strava_blacklist_json = []
        self.blacklist_broken = False
        bl_path = self.strava_blacklist
        if self.strava_enable:
            if not os.path.exists(bl_path):
                example_bl = example_path_for(bl_path)
                if os.path.exists(example_bl):
                    bl_path = example_bl
            if os.path.exists(bl_path):
                try:
                    with open(bl_path, "r", encoding="utf-8") as f:
                        loaded = json.load(f)
                    if isinstance(loaded, list):
                        # Never let the example template placeholder govern
                        # real filtering (fresh installs may only have the
                        # example file; a copied example stays harmless).
                        # Same placeholder logic as ConfigManager.
                        self.strava_blacklist_json = [
                            kw for kw in loaded
                            if kw and not _looks_like_placeholder(kw)
                        ]
                    else:
                        self.log(f"Warning: strava blacklist is not a JSON list, treating as empty: {bl_path}")
                        self.strava_blacklist_json = []
                except Exception as e:
                    from .helpers import quarantine_corrupt_file

                    # Fail closed for automatic ordering: an unreadable
                    # blacklist must not silently re-allow banned meals.
                    # (Explicit manual picks bypass the blacklist by design.)
                    # Only undecodable content is quarantined, never a
                    # merely busy file or the shipped example.
                    self.blacklist_broken = True
                    backup = ""
                    if (isinstance(e, ValueError)
                            and os.path.abspath(bl_path) != os.path.abspath(
                                example_path_for(bl_path))):
                        backup = quarantine_corrupt_file(bl_path)
                    hint = f" (preserved at {backup})" if backup else ""
                    self.log(f"Warning: Could not read strava blacklist: {e}{hint}")
                    self.strava_blacklist_json = []

        self.foodHTML = ""
        self.foodDict = {}
        self.orderedDict = {}
        # Clicks performed by order() since the last reset (evaluate() and
        # stravaOrderSelected reset it per run). Lets callers submit the
        # form only when the page was actually touched.
        self.clicks_made = 0
        # Set by order() when Strava rejected a click for lack of money
        # (Warning [5005]); every further meal order would fail the same
        # way, so callers stop ordering and tell the user to top up.
        self.insufficient_balance = False
        self.last_notice = ""

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
    def _nav_ms(self) -> int:
        # Budget for waits that follow a navigation-triggering click
        # (login submit → app redirect). Same contract as Bakalari's:
        # the page-load knob, never less than the element knob.
        try:
            return max(int(self._element_ms), int(self._page_load_ms))
        except Exception:
            return 60000

    @property
    def _action_ms(self) -> int:
        # Short cap for clicks inside the login flow (field fills, submit).
        # Cookiebot can slide over the form mid-fill, and a covered click
        # would otherwise burn the full 30 s element wait before the retry
        # loop gets a chance to dismiss the banner and try again.
        return min(self._element_ms, 5000)

    def _wait_for_page_settled(self, timeout_ms: int) -> bool:
        """Waits for the current page to finish loading, never navigating.

        Same contract as BakalariClient._wait_for_page_settled: waiting
        out a still-loading page beats re-issuing a navigation
        (\"refresh\") that would restart the load from zero on a slow
        link. Never raises except ``InterruptedError`` on cancel.
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

    def _is_authenticated(self, timeout_ms: int) -> bool:
        """True when the canteen menu is already on screen. Never raises."""
        try:
            self.page.locator(
                "xpath=//div[contains(@id, '.')]//label | //label[contains(@for, 'table')]"
            ).first.wait_for(state="visible", timeout=max(0, int(timeout_ms)))
            return True
        except InterruptedError:
            raise
        except Exception:
            return False

    def _goto(self, url: str):
        # One navigation, never re-issued (same contract as Bakaláři's
        # _goto): re-navigating restarts a slow load from zero.
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

    def _cookies_gone(self) -> bool:
        """True when the Cookiebot banner is dismissed/consented."""
        try:
            consented = self.page.evaluate(
                "() => { try {"
                " if (window.Cookiebot && window.Cookiebot.consented) return true;"
                " const d = document.getElementById('CybotCookiebotDialog');"
                " if (!d) return true;"
                " if (getComputedStyle(d).display === 'none') return true;"
                " if (!d.classList.contains('CybotCookiebotDialogActive')) return true;"
                " return false;"
                " } catch (e) { return false; } }"
            )
            if consented:
                return True
        except Exception:
            pass
        try:
            dlg = self.page.locator("#CybotCookiebotDialog")
            if dlg.count() == 0:
                return True
            return not dlg.first.is_visible()
        except Exception:
            return False

    # Single source of truth for the Cookiebot state probe: 'consented'
    # (stored consent — no banner will come), 'banner' (dialog up or its
    # buttons rendered), 'blocked' (uc.js finished loading >0.5 s ago but
    # never ran — DNS/ad blocking; no banner will come), 'pending' (script
    # not loaded yet). Until uc.js runs, window.Cookiebot is just the
    # <script id="Cookiebot"> element (named access), hence the
    # HTMLElement check.
    _BANNER_STATE_JS = (
        "() => { try {"
        " if (window.Cookiebot && window.Cookiebot.consented) return 'consented';"
        " if (document.getElementById("
        "'CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll')) return 'banner';"
        " if (document.getElementById("
        "'CybotCookiebotDialogBodyButtonDecline')) return 'banner';"
        " var d = document.getElementById('CybotCookiebotDialog');"
        " if (d && getComputedStyle(d).display !== 'none'"
        " && d.classList.contains('CybotCookiebotDialogActive')) return 'banner';"
        " if (!window.Cookiebot || window.Cookiebot instanceof HTMLElement) {"
        " var ents = performance.getEntriesByType('resource');"
        " for (var i = 0; i < ents.length; i++) {"
        " var e = ents[i];"
        " if (e.name.indexOf('consent.cookiebot.com/uc.js') !== -1"
        " && performance.now() - (e.startTime + e.duration) > 500) return 'blocked';"
        " } }"
        " return 'pending';"
        " } catch (e) { return 'unknown'; } }"
    )

    def _wait_for_cookie_banner(self, timeout_ms: int = None) -> str:
        """Waits until the Cookiebot state is known — before touching the form.

        Cookiebot loads async after ``goto``: filling the login form
        immediately races the banner sliding in mid-fill. Waits (bounded,
        capped below the full element wait) for stored consent or a
        rendered banner. Returns ``'consented'`` / ``'banner'`` /
        ``'blocked'`` (uc.js failed to load — returns within ~0.5 s of the
        failure instead of burning the cap) / ``'unknown'`` (timeout —
        banner blocked or absent). Callers
        proceed on ``'unknown'`` anyway; the per-field dismiss retries
        stay as a safety net. Never raises.
        """
        if timeout_ms is None:
            # Capped below the full element wait: this only settles whether
            # the banner will come at all — the per-field dismiss retries
            # stay as a safety net for a banner that arrives later.
            timeout_ms = min(self._element_ms, 8000)
        state_js = f"({self._BANNER_STATE_JS})()"
        try:
            self.page.wait_for_function(
                f"{state_js} !== 'pending'",
                timeout=max(0, int(timeout_ms)),
            )
        except InterruptedError:
            raise
        except Exception:
            pass
        try:
            state = self.page.evaluate(state_js)
            return str(state) if state else "unknown"
        except Exception:
            return "unknown"

    def _dismiss_cookies(self, timeout_ms: int = None, retries: int = 4) -> bool:
        """Clicks the Cookiebot 'Allow all' button and verifies it took effect.

        The button is visible before Cookiebot's click handler is attached,
        so a single blind click can silently do nothing (dialog stays open
        and later blocks the login form). Retry + verify fixes that race.

        Returns immediately when no banner is present — the waits below
        only run when a banner actually needs clicking. Callers arriving
        fresh from ``goto`` must run ``_wait_for_cookie_banner`` first
        (an absent dialog reads as "gone", so this alone cannot tell
        "not loaded yet" from "never coming").
        """
        if timeout_ms is None:
            timeout_ms = self._element_ms
        # Short caps: the banner is either there or not — never burn the
        # full element wait just looking for it.
        btn_ms = max(500, min(int(timeout_ms), 5000))
        selectors = [
            "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll",
            "#CybotCookiebotDialogBodyButtonDecline",
        ]
        if self._cookies_gone():
            return True
        for _ in range(retries):
            if self._cookies_gone():
                return True
            clicked = False
            for sel in selectors:
                try:
                    btn = self.page.locator(sel)
                    btn.wait_for(state="visible", timeout=btn_ms)
                except Exception:
                    continue
                try:
                    btn.click(timeout=btn_ms)
                    clicked = True
                    break
                except Exception:
                    pass
                try:
                    btn.click(force=True, timeout=btn_ms)
                    clicked = True
                    break
                except Exception:
                    pass
                try:
                    btn.evaluate("el => el.click()")
                    clicked = True
                    break
                except Exception:
                    pass
            # Give Cookiebot a moment to store consent + run close animation.
            # Poll instead of a fixed sleep — exits the moment the banner is
            # gone, caps at ~800ms when the close animation is slow.
            for _ in range(8):
                if self._cookies_gone():
                    break
                try:
                    self.page.wait_for_timeout(100)
                except Exception:
                    try:
                        self.bm.random_sleep(0.1)
                    except Exception:
                        pass
            if clicked and self._cookies_gone():
                return True
        return self._cookies_gone()

    def _fill_login_field(self, name: str, value: str, attempts: int = 3) -> None:
        """Fills one login field, surviving a late Cookiebot banner.

        Cookiebot loads async and can pop up between field fills (e.g.
        right after the canteen number), covering the rest of the form.
        A single dismiss at page load can't catch that, so every attempt
        re-dismisses first and a click blocked by the overlay is retried
        instead of aborting the whole login.
        """
        loc = self.page.locator(f'[name="{name}"]').first
        loc.wait_for(state="visible", timeout=self._element_ms)
        last_err: Exception | None = None
        for _ in range(max(1, attempts)):
            self._dismiss_cookies()
            try:
                try:
                    loc.click(timeout=self._action_ms)
                except Exception:
                    loc.evaluate("el => el.click()")
                # A failed earlier attempt may have typed part of the value.
                clear_input(loc)
                loc.press_sequentially(value, delay=10)
                return
            except Exception as e:
                last_err = e
                continue
        if last_err is not None:
            raise last_err

    def login(self):
        self._raise_if_cancelled()
        if not str(getattr(self, "strava_id", "") or "").strip():
            raise UserError(t("strava_missing_canteen"))
        if not str(getattr(self, "strava_username", "") or "").strip():
            raise UserError(t("strava_missing_user"))
        if not str(getattr(self, "strava_password", "") or "").strip():
            raise UserError(t("strava_missing_password"))
        url = str(self.strava_url or "https://strava.cz").strip()
        if url and not url.startswith(("http://", "https://")):
            url = f"https://{url}"
        if url.startswith("http://"):
            self.log("Warning: Strava URL uses plain http:// — credentials will travel unencrypted.")
        # Fast path: a still-valid session must not navigate. Only probed
        # after a successful login in this instance (a cold client could
        # mistake the login page for the menu). A still-loading page is
        # waited out, never refreshed; only a settled one may navigate.
        _skip_goto = False
        if getattr(self, "logged_in", False):
            try:
                if self._is_authenticated(min(self._element_ms, 3000)):
                    return
            except InterruptedError:
                raise
            except Exception:
                pass
            try:
                _settled = self._wait_for_page_settled(self._page_load_ms)
            except InterruptedError:
                raise
            except Exception:
                _settled = False
            try:
                if self._is_authenticated(min(self._element_ms, 10000)):
                    return
            except InterruptedError:
                raise
            except Exception:
                pass
            if not _settled:
                _skip_goto = True
        if _skip_goto:
            self.log("Strava page still loading after the full page budget — "
                     "waiting it out instead of refreshing.")
            # A valid session's menu may just arrive late; otherwise the
            # form fills below wait out a still-arriving login page.
            try:
                if self._is_authenticated(self._nav_ms):
                    return
            except InterruptedError:
                raise
            except Exception:
                pass
        else:
            self._goto(url)

        # Cookiebot loads async: settle the banner state BEFORE touching
        # the form — never fill through a banner that is still on its way
        # in. Per-field fills below still re-dismiss as a safety net.
        self._wait_for_cookie_banner()
        if not self._dismiss_cookies():
            self.log("Warning: cookie banner is still up — continuing, field fills will retry around it.")

        self._fill_login_field("cislo", self.strava_id)
        self._fill_login_field("jmeno", self.strava_username)

        if is_encrypted_flag(self.strava_password_encrypted):
            correct_password = decrypt_strict(self.strava_password)
            if correct_password is None:
                raise UserError(t("strava_password_undecryptable"))
        else:
            correct_password = self.strava_password

        self._fill_login_field("heslo", correct_password)
        # The banner loads async and can pop up after the first dismiss —
        # clear it again right before submitting so it can't cover the button.
        self._dismiss_cookies()
        self._raise_if_cancelled()
        # The submit is scoped to the login form (the Cookiebot banner has
        # buttons too). It is clicked at most once: a dispatched click
        # whose cross-domain redirect is slow must never be repeated — the
        # menu check below tells a slow submit from a failed one.
        _submitted = False
        for _ in range(3):
            self._raise_if_cancelled()
            self._dismiss_cookies()
            try:
                form_submit = self.page.locator(
                    'xpath=//input[@name="heslo"]/ancestor::form//button[@type="submit"]'
                ).first
                form_submit.wait_for(state="visible", timeout=self._element_ms)
            except InterruptedError:
                raise
            except Exception:
                continue
            try:
                form_submit.click(timeout=self._nav_ms, once=True)
            except InterruptedError:
                raise
            except Exception:
                pass
            _submitted = True
            break
        if not _submitted:
            # Last resort: keep it scoped to the login form (a global
            # [type="submit"] could hit the Cookiebot banner) and never let
            # a slow page raise — the menu check below fails loudly anyway.
            # Single attempt: same no-double-submit rule as above.
            self._dismiss_cookies()
            try:
                self.page.locator(
                    'xpath=//input[@name="heslo"]/ancestor::form//*[@type="submit"]'
                ).first.click(timeout=self._nav_ms, once=True)
            except Exception:
                pass

        # Login navigates (strava.cz -> app.strava.cz) where the banner can
        # appear again — dismiss before waiting for the menu.
        self._dismiss_cookies()

        # Verify the login: wait for the menu (navigation budget — the
        # submit redirects strava.cz -> app.strava.cz), fail loudly when
        # the login form is still shown.
        menu_locator = self.page.locator(
            "xpath=//div[contains(@id, '.')]//label | //label[contains(@for, 'table')]"
        ).first
        try:
            menu_locator.wait_for(state="visible", timeout=self._nav_ms)
            self.logged_in = True
        except InterruptedError:
            raise
        except Exception:
            self._raise_if_cancelled()
            try:
                login_form = self.page.locator('[name="heslo"]').first
                if login_form.count() > 0 and login_form.is_visible():
                    raise UserError(t("strava_login_failed"))
            except UserError:
                raise
            except InterruptedError:
                raise
            except Exception:
                pass
            # Menu structure may differ per canteen — do NOT claim success:
            # an unverified login must fail loudly, not report a pass.
            self.log("Warning: Could not verify Strava login (menu not found).")
            self.logged_in = False
            raise RuntimeError("Strava login could not be verified (menu not found).") from None

    def fetch_data(self):
        self._raise_if_cancelled()
        # Fetching without a session only scrapes the login page.
        if not self.logged_in:
            self.login()
        else:
            # Sessions expire server-side: re-probe the menu before
            # scraping (a login page would read as an empty menu). A
            # failed re-login surfaces as an error.
            if not self._is_authenticated(min(self._element_ms, 10000)):
                self.login()
        try:
            food_locator = self.page.locator("xpath=//div[contains(@id, '.')]//label | //label[contains(@for, 'table')]").first
            food_locator.wait_for(state="visible", timeout=self._element_ms)
        except InterruptedError:
            raise
        except Exception:
            pass
        # No blind render pause: the locator wait above already returns the
        # moment the menu is in the DOM.

        self._raise_if_cancelled()
        self.foodHTML = self.page.content()
        try:
            self.foodDict = extract_food_data(self.foodHTML)
            self.orderedDict = extract_ordered_food(self.foodHTML)
            self._reconcile_ordered_live()
        except Exception as e:
            self.log(f"Warning: Could not extract food data: {e} — showing no menu, not stale data.")
            # Never serve the previous menu as fresh: downstream refresh
            # paths treat an empty menu as a failed fetch and keep the
            # last good cache instead of overwriting it.
            self.foodDict = {}
            self.orderedDict = {}

        return {
            "foodDict": self.foodDict,
            "orderedDict": self.orderedDict
        }

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
