"""Late Cookiebot banner must not abort the Strava login.

Regression test: Cookiebot loads async and can pop up after the canteen
number (cislo) was typed, covering the rest of the form. login() must
re-dismiss around every field fill instead of dying on the first click
the overlay intercepts.
"""
import sys

sys.path.insert(0, ".")

from strakalari.core.strava_client import StravaClient


class _LateBannerLoc:
    def __init__(self, page, selector):
        self._page = page
        self._selector = selector

    @property
    def first(self):
        return self

    def wait_for(self, state=None, timeout=None):
        return True

    def click(self, timeout=None, force=False):
        if self._page.banner_up and '[name="jmeno"]' in self._selector:
            raise Exception("Element is obscured by #CybotCookiebotDialog")
        if self._page.banner_up and '[name="heslo"]' in self._selector:
            raise Exception("Element is obscured by #CybotCookiebotDialog")
        self._page.clicked.append(self._selector)

    def press_sequentially(self, value, delay=10):
        self._page.typed[self._selector] = value
        if '[name="cislo"]' in self._selector:
            # Async Cookiebot: the banner lands right after cislo is typed.
            self._page.banner_up = True

    def evaluate(self, js):
        return True

    def count(self):
        return 1

    def is_visible(self):
        return True


class _LateBannerPage:
    def __init__(self):
        self.banner_up = False
        self.dismiss_calls = 0
        self.clicked = []
        self.typed = {}
        self.url = "https://app.strava.cz/menu"

    def goto(self, url, timeout=None, wait_until=None):
        pass

    def locator(self, selector):
        return _LateBannerLoc(self, selector)

    def evaluate(self, js):
        if "CybotCookiebotDialog" in js or "Cookiebot" in js:
            return not self.banner_up
        return True

    def wait_for_function(self, js, timeout=None):
        return True

    def wait_for_timeout(self, ms):
        pass

    def content(self):
        return "<html></html>"


class _LateBannerBM:
    def __init__(self, page):
        self.page = page

    def random_sleep(self, s):
        pass


def test_login_survives_banner_appearing_after_cislo():
    page = _LateBannerPage()
    client = StravaClient(
        _LateBannerBM(page),
        {"use_strava": True, "strava_canteen_id": "1234",
         "strava_username": "user", "strava_password": "pw",
         "element_wait_s": 2},
        logger=lambda m: None,
    )
    real_dismiss = client._dismiss_cookies

    def dismiss_spy(timeout_ms=None, retries=4):
        result = real_dismiss(timeout_ms, retries)
        page.dismiss_calls += 1
        page.banner_up = False  # consent stored, banner gone
        return result

    client._dismiss_cookies = dismiss_spy
    client.login()

    assert client.logged_in
    assert page.dismiss_calls >= 2
    assert '[name="jmeno"]' in page.typed
    assert '[name="heslo"]' in page.typed


def test_save_confirm_ignores_decorative_slash_error_text():
    """A visible '/' separator matching an error selector is not a failure.

    Regression: the post-save error check treated ANY non-empty text as
    a failed submit, so a decorative element (e.g. a '/' glyph matching
    .error / [role='alert']) reported 'save button failed' even though
    the order was saved online.
    """

    class _Btn:
        @property
        def first(self):
            return self

        def wait_for(self, state=None, timeout=None):
            return True

        def evaluate(self, js):
            return True

        def click(self, timeout=None):
            return True

    class _JunkErr:
        def is_visible(self):
            return True

        def inner_text(self):
            return "/"

    class _ErrLoc:
        def all(self):
            return [_JunkErr()]

        # Legacy path used before the fix iterated .first only.
        @property
        def first(self):
            return self

        def count(self):
            return 1

        def is_visible(self):
            return True

        def inner_text(self):
            return "/"

    class _Page:
        url = "https://app.strava.cz/menu"

        def locator(self, selector):
            if "alert-danger" in selector:
                return _ErrLoc()
            return _Btn()

        def wait_for_timeout(self, ms):
            pass

    class _BM:
        def __init__(self, page):
            self.page = page

        def random_sleep(self, s):
            pass

    client = StravaClient(
        _BM(_Page()),
        {"use_strava": True, "element_wait_s": 2},
        logger=lambda m: None,
    )
    client._dismiss_cookies = lambda *a, **k: True
    client._verified = lambda mid: True
    assert client.save_confirm(["table1&1&0"]) is True


def test_login_waits_for_banner_before_touching_form():
    """Slow banner must settle before the first field fill, not mid-fill.

    The banner script loads async after goto: login() has to wait for
    the banner state (shown / consented) and dismiss it BEFORE typing
    anything, instead of racing it and retrying around the overlay.
    """

    class _SlowLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def wait_for(self, state=None, timeout=None):
            return True

        def click(self, timeout=None, force=False):
            if self._page.banner_up:
                raise Exception("Element is obscured by #CybotCookiebotDialog")
            self._page.events.append(f"click:{self._selector}")

        def press_sequentially(self, value, delay=10):
            if self._page.banner_up:
                raise Exception("Element is obscured by #CybotCookiebotDialog")
            self._page.events.append(f"fill:{self._selector}")

        def evaluate(self, js):
            return True

        def count(self):
            return 1

        def is_visible(self):
            return True

    class _SlowPage:
        url = "https://app.strava.cz/menu"

        def __init__(self):
            self.events = []
            self.banner_loaded = False
            self.banner_up = False

        def goto(self, url, timeout=None, wait_until=None):
            pass

        def locator(self, selector):
            return _SlowLoc(self, selector)

        def wait_for_function(self, js, timeout=None):
            # The banner script finishes loading while we wait for it.
            self.events.append("wait-for-banner")
            self.banner_loaded = True
            self.banner_up = True

        def evaluate(self, js):
            if "Cookiebot" in js or "CybotCookiebotDialog" in js:
                if not self.banner_loaded:
                    return "pending"
                return "banner" if self.banner_up else "consented"
            return True

        def wait_for_timeout(self, ms):
            pass

    class _BM:
        def __init__(self, page):
            self.page = page

        def random_sleep(self, s):
            pass

    page = _SlowPage()
    client = StravaClient(
        _BM(page),
        {"use_strava": True, "strava_canteen_id": "1234",
         "strava_username": "user", "strava_password": "pw",
         "element_wait_s": 2},
        logger=lambda m: None,
    )

    def dismiss_spy(timeout_ms=None, retries=4):
        page.events.append("dismiss")
        page.banner_up = False
        return True

    client._dismiss_cookies = dismiss_spy
    client.login()

    assert client.logged_in
    assert "wait-for-banner" in page.events
    first_fill = next(i for i, e in enumerate(page.events) if e.startswith("fill:"))
    assert page.events.index("wait-for-banner") < first_fill
    assert page.events.index("dismiss") < first_fill


def test_wait_for_banner_unknown_never_raises():
    """Blocked banner script (no Cookiebot API) must not hang or raise."""

    class _BarePage:
        def wait_for_function(self, js, timeout=None):
            raise Exception("timeout")

        def evaluate(self, js):
            raise Exception("no js")

    class _BM:
        def __init__(self, page):
            self.page = page

    client = StravaClient(_BM(_BarePage()), {"use_strava": True}, logger=lambda m: None)
    assert client._wait_for_cookie_banner(timeout_ms=10) == "unknown"
