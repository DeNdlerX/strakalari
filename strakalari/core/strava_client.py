import json
import os

from .helpers import clear_input, decrypt_strict, is_encrypted_flag, _resolve_path, example_path_for
from .config import _looks_like_placeholder
from .extractors.strava import extract_food_data, extract_ordered_food
from .error_report import UserError, is_timeout_error, timeout_user_message
from .i18n import t
from .strava_ordering import (  # noqa: F401 - re-exported for existing imports
    LOW_BALANCE_CODE,
    OrderingMixin,
    _is_page_chrome_notice,
    is_low_balance_notice,
)


class StravaClient(OrderingMixin):
    """Strava.cz session: login, cookie banner and menu scraping.

    Ordering lives in :class:`~.strava_ordering.OrderingMixin`.
    """

    def __init__(self, browser_manager, config_data, logger=None):
        self.bm = browser_manager
        # Cooperative cancellation (mirrors BakalariClient; set from
        # Strakalari.fetch_strava_data before each fetch).
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
        # strava_order_selected reset it per run). Lets callers submit the
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

    def _debug(self, what: str, exc: BaseException) -> None:
        """Logs a deliberately tolerated failure (see ``describe_swallowed``)."""
        from .helpers import describe_swallowed

        self.log(describe_swallowed(what, exc))

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
        except Exception as e:
            self._debug("Strava: cookie banner wait timed out", e)
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
            except Exception as e:
                self._debug("Strava login: submit click did not finish", e)
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
            except Exception as e:
                self._debug("Strava login: fallback submit click failed", e)

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
            except Exception as e:
                self._debug("Strava login: login-form probe failed", e)
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
        except Exception as e:
            self._debug("Strava: menu wait timed out", e)
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
