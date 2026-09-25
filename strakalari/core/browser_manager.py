import gc
import logging
import random
import time
import warnings
from playwright.sync_api import sync_playwright
from .browser import ensure_browser, init_browsers_path


class _SuppressAsyncioTeardownNoise(logging.Filter):
    """Drops Playwright's known-benign teardown chatter.

    After ``browser.close()`` any still-in-flight protocol callbacks
    complete with ``TargetClosedError``; when ``playwright.stop()`` then
    tears down the internal driver loop before asyncio retrieves those
    futures, asyncio logs "Task was destroyed but it is pending" /
    "Future exception was never retrieved" to stderr. The automation work
    itself already finished — this is GC noise, not a failure.
    """

    _NEEDLES = (
        "Task was destroyed but it is pending",
        "Future exception was never retrieved",
        "TargetClosedError",
        "Target page, context or browser has been closed",
        "Connection.run",
    )

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        return not any(needle in msg for needle in self._NEEDLES)


_installed_teardown_suppression = False


def _install_teardown_noise_suppression() -> None:
    """Installs process-wide suppression of Playwright teardown chatter.

    Installed once at import (not just around ``close()``): driver-thread
    callbacks and late GC finalizers run after a close returns. Only
    matching records are dropped; everything else passes through.
    """
    global _installed_teardown_suppression
    if _installed_teardown_suppression:
        return
    _installed_teardown_suppression = True
    try:
        logging.getLogger("asyncio").addFilter(_SuppressAsyncioTeardownNoise())
    except Exception:
        pass
    try:
        logging.getLogger().addFilter(_SuppressAsyncioTeardownNoise())
    except Exception:
        pass
    for _pattern in (
        r".*Task was destroyed but it is pending.*",
        r".*Future exception was never retrieved.*",
        r".*TargetClosedError.*",
        r".*Target page, context or browser has been closed.*",
    ):
        try:
            warnings.filterwarnings("ignore", message=_pattern, category=Warning)
        except Exception:
            pass
    try:
        import sys

        _prev_hook = sys.unraisablehook

        def _swallow_teardown_noise(args, _prev=_prev_hook) -> None:
            # ``Task.__del__``/``Future.__del__`` fall back here when the
            # driver loop is already gone — same benign noise, same drop.
            try:
                text = " ".join((
                    str(getattr(args, "err_msg", "") or ""),
                    str(getattr(args, "exc_type", "") or ""),
                    str(getattr(args, "exc_value", "") or ""),
                ))
                if any(n in text for n in _SuppressAsyncioTeardownNoise._NEEDLES):
                    return
            except Exception:
                pass
            try:
                _prev(args)
            except Exception:
                pass

        sys.unraisablehook = _swallow_teardown_noise
    except Exception:
        pass


_install_teardown_noise_suppression()


class BrowserManager:
    """Manages the Playwright browser lifecycle and provides robust DOM interactions."""
    def __init__(self, user_agent, is_maximized, is_headless, launch_retries: int = 2):
        self.playwright = None
        self.browser = None
        self.context = None
        self.page = None
        self.driver = None
        self._closed = False

        # Resolve the persistent browsers dir BEFORE the driver process
        # starts: Playwright's transport freezes PLAYWRIGHT_BROWSERS_PATH
        # into the driver env at start() time, so installing afterwards
        # without a restart would leave the driver looking at the stale
        # (ephemeral _MEIPASS) location.
        init_browsers_path()
        try:
            ensure_browser()
        except Exception:
            # ensure_browser logs its own reason; the launch loop below
            # surfaces the actionable error.
            pass

        try:
            self.playwright = sync_playwright().start()
            launch_args = []
            if is_maximized:
                launch_args.append("--start-maximized")

            last_err: Exception | None = None
            for attempt in range(int(launch_retries) + 1):
                try:
                    self.browser = self.playwright.chromium.launch(
                        headless=is_headless,
                        args=launch_args,
                    )
                    last_err = None
                    break
                except Exception as e:
                    last_err = e
                    msg = str(e)
                    if "Executable doesn't exist" in msg or "playwright install" in msg.lower():
                        ensure_browser()
                        # The driver inherited its browsers path at
                        # start(); restart it so a freshly installed (or
                        # re-pointed) persistent dir takes effect instead
                        # of retrying against the stale location.
                        try:
                            try:
                                self.playwright.stop()
                            except Exception:
                                pass
                            init_browsers_path()
                            self.playwright = sync_playwright().start()
                        except Exception as e_restart:
                            last_err = e_restart
                            if attempt < int(launch_retries):
                                time.sleep(1 + attempt)
                            continue
                        # Retry immediately after installing; don't count it.
                        try:
                            self.browser = self.playwright.chromium.launch(
                                headless=is_headless,
                                args=launch_args,
                            )
                            last_err = None
                            break
                        except Exception as e2:
                            last_err = e2
                    if attempt < int(launch_retries):
                        time.sleep(1 + attempt)
            if self.browser is None:
                raise RuntimeError(f"Could not launch Chrome after retries: {last_err}") from last_err

            context_kwargs = {"user_agent": user_agent}
            if is_maximized:
                context_kwargs["no_viewport"] = True

            self.context = self.browser.new_context(**context_kwargs)
            self.page = self.context.new_page()
            self.driver = self.page  # Backward compatibility alias
        except Exception:
            # Never leak a half-started Playwright process on init failure.
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __del__(self):  # defensive: never raise from GC / interpreter shutdown
        try:
            self.close()
        except Exception:
            pass

    def close(self):
        # Idempotent: Strakalari.close() and __exit__ may both fire.
        if getattr(self, "_closed", False):
            return
        self._closed = True
        # Close only the browser — it implicitly closes its contexts/pages.
        # Explicitly closing page/context first sends extra protocol messages
        # that race with teardown and surface as "Task was destroyed but it
        # is pending / TargetClosedError" noise on interpreter shutdown.
        #
        # Even browser-only teardown can leave in-flight protocol callbacks
        # that complete with TargetClosedError while playwright.stop() tears
        # down the internal driver loop, so: (1) let the connection drain
        # briefly between browser.close() and playwright.stop(), and
        # (2) suppress asyncio's teardown chatter for the duration (a forced
        # gc makes orphaned futures finalize inside the suppression window
        # instead of at some later random GC).
        noise_filter = _SuppressAsyncioTeardownNoise()
        attached: list = []
        for logger in (logging.getLogger("asyncio"), logging.getLogger()):
            try:
                logger.addFilter(noise_filter)
                attached.append(logger)
            except Exception:
                pass
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                browser = getattr(self, "browser", None)
                if browser is not None:
                    try:
                        browser.close()
                    except Exception:
                        pass
                for attr in ("page", "context", "browser"):
                    try:
                        setattr(self, attr, None)
                    except Exception:
                        pass
                if self.driver is not None:
                    self.driver = None
                # Let the protocol connection drain so pending callbacks
                # settle before the driver loop is torn down.
                try:
                    time.sleep(0.2)
                except Exception:
                    pass
                if self.playwright:
                    try:
                        self.playwright.stop()
                    except Exception:
                        pass
                    self.playwright = None
                try:
                    gc.collect()
                except Exception:
                    pass
        finally:
            for logger in attached:
                try:
                    logger.removeFilter(noise_filter)
                except Exception:
                    pass

    def _to_selector(self, by_or_sel, identifier=None):
        if identifier is None:
            return str(by_or_sel)
        by = str(by_or_sel).lower()
        if "id" in by:
            return f'[id="{identifier}"]'
        elif "class" in by:
            parts = [p.strip() for p in identifier.strip().split() if p.strip()]
            return f".{'.'.join(parts)}"
        elif "name" in by:
            return f'[name="{identifier}"]'
        elif "xpath" in by:
            return f"xpath={identifier}"
        elif "css" in by:
            return str(identifier)
        return str(identifier)

    def scroll_until_visible(self, by_or_sel, identifier=None, scroll_step=400, delay=0.05, max_scrolls=20):
        sel = self._to_selector(by_or_sel, identifier)

        def _check_and_scroll(loc):
            # Existence in the DOM is not enough — the element must be visible
            # to be clickable. Fall back to existence only if visibility
            # cannot be determined (e.g. mock objects in tests).
            try:
                if loc.count() > 0:
                    try:
                        return bool(loc.first.is_visible())
                    except Exception:
                        return True
            except Exception:
                pass
            return False

        try:
            loc = self.page.locator(sel).first
            if _check_and_scroll(loc): return loc
        except Exception:
            pass

        if identifier and "id" in str(by_or_sel).lower():
            try:
                label_loc = self.page.locator(f'label[for="{identifier}"]').first
                if _check_and_scroll(label_loc): return label_loc
            except Exception:
                pass

        for _ in range(max_scrolls):
            try:
                loc = self.page.locator(sel).first
                if _check_and_scroll(loc): return loc
            except Exception:
                pass
            self.page.evaluate(f"window.scrollBy(0, {scroll_step});")
            time.sleep(delay)

        return None

    def scroll_up(self):
        # Back to top; no settle sleep — callers wait explicitly for the
        # element they need next (scroll_until_visible / wait_for).
        try:
            self.page.evaluate("window.scrollTo(0, 0);")
        except Exception:
            pass

    def click_element(self, loc, identifier=None, timeout: int = 5000):
        if loc is None:
            return False
        try:
            loc.click(timeout=timeout)
            return True
        except Exception:
            pass
        try:
            loc.click(force=True, timeout=timeout)
            return True
        except Exception:
            pass
        if identifier:
            try:
                label = self.page.locator(f'label[for="{identifier}"]').first
                if label.count() > 0:
                    label.click(timeout=timeout)
                    return True
            except Exception:
                pass
        try:
            loc.evaluate("el => el.click()")
            return True
        except Exception:
            pass
        return False

    def random_sleep(self, base=0.25, max_jitter=0.25):
        time.sleep(base + random.random() * max_jitter)
