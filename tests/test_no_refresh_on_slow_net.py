"""Slow connection: wait the page out, never refresh it.

Regression tests for the "keeps refreshing on slow internet" bug: the
login fast-path probes (3 s) expired while the page was still loading and
the code answered with a fresh navigation — restarting the load from zero,
sometimes forever. Every phase (login, grades, outbox, directory,
substitutions, excuse form, Strava login) had the same shape.

Contract under test:
* a page that is still loading is NEVER navigated (goto count == 0);
  full-budget waits simply wait it out;
* only a settled page showing neither the app nor the login form earns
  one fresh navigation (cold start on a blank tab);
* a cold start on about:blank navigates at once (no probes on a blank tab);
* navigation-triggering clicks fire exactly once: a dispatched click
  whose navigation outlasts the budget is never retried (no refresh
  loop, no double submit); the actionability wait before it stays
  cancel-responsive;
* the UI timeout knobs govern every wait (no hidden caps).

Fakes never sleep: they raise immediately, so the cancel-wrapper slice
loops exhaust their logical budgets in milliseconds of real time.
"""
from types import SimpleNamespace

import pytest


class _Timeout(Exception):
    pass


class _FakeLocator:
    def __init__(self, page, selector):
        self._page = page
        self._selector = selector

    @property
    def first(self):
        return self

    def nth(self, index):
        return self

    def _state(self):
        return self._page.states.get(self._selector, {})

    def is_visible(self):
        return bool(self._state().get("visible", False))

    def count(self):
        return 1 if self._selector in self._page.states else 0

    def inner_text(self):
        return self._state().get("text", "")

    def input_value(self, timeout=None):
        return self._state().get("value", "")

    def wait_for(self, state=None, timeout=None):
        self._page.waits.append((self._selector, state, timeout))
        if state == "detached":
            return True  # simulates the submitted form navigating away
        if self.is_visible():
            return True
        # The Strava submit button: tests enable it via submit_visible.
        if 'type="submit"' in self._selector and self._page.submit_visible:
            return True
        raise _Timeout(f"Timeout {timeout}ms exceeded.")

    def click(self, timeout=None, **kwargs):
        self._page.clicks.append((self._selector, timeout))
        # fail_first: the first click on this selector raises AFTER the
        # click was dispatched — simulates Playwright serializing the
        # click behind its slow navigation ("waiting for scheduled
        # navigations to finish") and the slice/budget expiring there.
        # Retrying such a click would navigate/submit AGAIN.
        if (self._selector in self._page.click_fail_first
                and self._selector not in self._page._click_failed):
            self._page._click_failed.add(self._selector)
            raise _Timeout(f"Timeout {timeout}ms exceeded.")
        if self._selector in self._page.click_always_fail:
            raise _Timeout(f"Timeout {timeout}ms exceeded.")
        return True

    def press_sequentially(self, text, delay=None):
        self._page.typed.append((self._selector, text))
        return True

    def press(self, key):
        return True

    def fill(self, text):
        return True

    def evaluate(self, js):
        return self._page.evaluate(js)

    def scroll_into_view_if_needed(self, timeout=None):
        return True


class _FakePage:
    """Static DOM + a settled flag + optional slow-auth simulation.

    states: {selector: {"visible": bool, "text": str, "value": str}}.
    settled=False: readyState never reaches interactive/complete.
    auth_failures=N: the first N auth-probe wait_for_function calls raise
    (the page is still loading), later ones evaluate the states — this
    simulates the slow link where the 3 s probes expire mid-load.
    """

    def __init__(self, states, settled=True, auth_failures=0,
                 submit_visible=False, body_text="", url="https://bakaweb.gekom.cz/next/"):
        self.states = states
        self.settled = settled
        self.auth_failures = auth_failures
        self.submit_visible = submit_visible
        self.body_text = body_text
        self.url = url
        self.click_fail_first = set()  # selectors whose first click raises post-dispatch
        self.click_always_fail = set()  # selectors whose every click raises
        self._click_failed = set()
        self.goto_count = 0
        self.typed = []
        self.waits = []  # (selector, state, timeout) per wait_for call
        self.clicks = []  # (selector, timeout) per click call
        self._auth_calls = 0

    def locator(self, selector):
        return _FakeLocator(self, selector)

    def get_by_text(self, *args, **kwargs):
        return _FakeLocator(self, "")

    def goto(self, url, timeout=None, wait_until=None):
        self.goto_count += 1
        return True

    def wait_for_function(self, js, timeout=None):
        js_text = str(js)
        if "readyState" in js_text:
            if self.settled:
                return True
            raise _Timeout("still loading")
        if "ico32-modul" in js_text or "username" in js_text:
            self._auth_calls += 1
            if self._auth_calls <= self.auth_failures:
                raise _Timeout("probe expired mid-load")
            if self.states.get(".ico32-modul-vyuka", {}).get("visible"):
                return True
            if self.states.get("#username", {}).get("visible"):
                return True
            raise _Timeout("neither app nor login form")
        # Any other content wait (grid rows, editor sync, ...): succeed
        # only when the test explicitly marks it via states["*js-ok*"].
        if self.states.get("*js-ok*"):
            return True
        raise _Timeout("condition never true")

    def wait_for_timeout(self, ms):
        return True

    def evaluate(self, js):
        js_text = str(js)
        if "Cookiebot" in js_text or "Cybot" in js_text:
            return True  # consented / no banner
        if "innerText" in js_text:
            return self.body_text
        return ""


def _bakalari(page, config=None):
    from strakalari.core.bakalari_client import BakalariClient

    cfg = {"bakalari_url": "https://skola.bakalari.cz",
           "bakalari_username": "user",
           "bakalari_password": "secret"}
    cfg.update(config or {})
    return BakalariClient(SimpleNamespace(page=page), cfg, logger=None)


def _strava(page, config=None):
    from strakalari.core.strava_client import StravaClient

    cfg = {"strava_url": "https://strava.cz",
           "strava_canteen_id": "123",
           "strava_username": "user",
           "strava_password": "secret",
           "use_strava": False}
    cfg.update(config or {})
    return StravaClient(SimpleNamespace(page=page), cfg, logger=None)


LOGIN_FORM = {
    "#username": {"visible": True},
    "#password": {"visible": True},
    "#loginButton": {"visible": True},
    ".ico32-modul-vyuka": {"visible": True},  # menu after submit
}


def test_bakalari_login_never_refreshes_loading_page():
    """App still loading when probes expire: wait it out, zero navigations."""
    page = _FakePage(dict(LOGIN_FORM), settled=False, auth_failures=24,
                     body_text="Vítejte, zadejte jméno a heslo.")
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 3})
    client.login()
    assert client.logged_in is True
    assert page.goto_count == 0


def test_bakalari_login_dead_page_fails_fast_without_refresh():
    """Nothing on screen and never settling: clear error, zero navigations.

    The old code charged ahead here and burned full element budgets on
    fields that never appear (minutes of apparent stillness). A page
    showing nothing after its load budget plus one decisive wait is
    hung, not slow — and must never be refreshed to find out.
    """
    from strakalari.core.error_report import UserError

    page = _FakePage({}, settled=False)
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    with pytest.raises(UserError) as exc_info:
        client.login()
    assert "nenačetla" in str(exc_info.value)
    assert page.goto_count == 0


def test_bakalari_login_navigates_once_from_blank_tab():
    """Settled page with neither app nor login form: one fresh navigation."""
    page = _FakePage({}, settled=True)
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    with pytest.raises(Exception):
        client.login()
    assert page.goto_count == 1


def test_bakalari_grades_never_navigates():
    """Menu unreachable: fail with an error, not with a refresh."""
    # Already inside the app (login fast-paths with zero navigations),
    # but the grades module never appears.
    page = _FakePage({".ico32-modul-vyuka": {"visible": True}})
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    assert client.get_grades() == {}
    assert client.grades_error != ""
    assert page.goto_count == 0


def test_bakalari_sent_excuses_never_navigates():
    page = _FakePage({"#username": {"visible": True}})
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    assert client.fetch_sent_excuses(limit=5) is None
    assert page.goto_count == 0


def test_bakalari_directory_never_navigates():
    page = _FakePage({".ico32-modul-vyuka": {"visible": True}})
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    assert client.fetch_subject_directory() == {}
    assert page.goto_count == 0


def test_bakalari_substitutions_never_navigates():
    page = _FakePage({".ico32-modul-vyuka": {"visible": True}})
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 2})
    assert client.fetch_substitutions() is None
    assert page.goto_count == 0


def test_settle_budget_honors_config_without_cap():
    page = _FakePage({})
    assert _bakalari(page, {"element_wait_s": 60})._settle_ms() == 60000
    assert _bakalari(page, {})._settle_ms() == 30000
    assert _bakalari(
        page,
        {"week_switch_delay_s": 10, "element_wait_s": 5})._settle_ms() == 10000


def test_strava_login_never_refreshes_loading_page():
    """Warm session, menu still loading: no navigation, loud failure."""
    from strakalari.core.error_report import UserError

    states = {
        '[name="cislo"]': {"visible": True},
        '[name="jmeno"]': {"visible": True},
        '[name="heslo"]': {"visible": True},
    }
    page = _FakePage(states, settled=False, submit_visible=True)
    client = _strava(page, {"page_load_timeout_s": 5, "element_wait_s": 3})
    client.logged_in = True
    with pytest.raises(UserError):
        client.login()
    assert page.goto_count == 0


def test_strava_cold_login_still_navigates_once():
    states = {
        '[name="cislo"]': {"visible": True},
        '[name="jmeno"]': {"visible": True},
        '[name="heslo"]': {"visible": True},
        "menu": {"visible": True},
    }
    page = _FakePage(states, settled=True, submit_visible=True)
    # Menu probe selector is an xpath the fake never marks visible, so
    # emulate a successful post-login menu via the generic js-ok flag is
    # not needed — instead expect the unverified-login RuntimeError path
    # but with exactly one navigation (cold start must navigate).
    client = _strava(page, {"page_load_timeout_s": 5, "element_wait_s": 3})
    with pytest.raises(Exception):
        client.login()
    assert page.goto_count == 1


NAV_CFG = {"element_wait_s": 3, "page_load_timeout_s": 60}


def _unwrapped(client, page):
    """Bypass the cancel-chunking wrapper so fakes see full budgets."""
    client.page = page
    return client


def test_nav_budget_is_page_load_never_below_element():
    page = _FakePage({})
    assert _bakalari(page, NAV_CFG)._nav_ms == 60000
    assert _strava(page, NAV_CFG)._nav_ms == 60000
    assert _bakalari(
        page, {"element_wait_s": 30, "page_load_timeout_s": 5})._nav_ms == 30000


def test_komens_navigation_waits_use_page_budget():
    """The Komens click loads komens_zprava.aspx: the follow-up wait must
    tolerate the full page load (the exact Timeout 1000ms/30s failure
    from the slow-net log), never refresh."""
    page = _FakePage({".ico32-modul-vyuka": {"visible": True}})
    client = _unwrapped(_bakalari(page, NAV_CFG), page)
    assert client.fetch_sent_excuses(limit=5) is None
    komens_waits = [t for s, st, t in page.waits
                    if s == ".ico32-modul-komens" and st == "visible"]
    assert komens_waits and all(t == 60000 for t in komens_waits)
    assert page.goto_count == 0


def test_login_submit_uses_page_budget():
    page = _FakePage(dict(LOGIN_FORM), settled=True, auth_failures=10_000,
                     body_text="Vítejte, zadejte jméno a heslo.")
    client = _unwrapped(_bakalari(page, NAV_CFG), page)
    client.login()
    assert client.logged_in is True
    login_clicks = [t for s, t in page.clicks if s == "#loginButton"]
    assert login_clicks == [60000]
    assert page.goto_count == 1  # settled blank-ish page: single cold nav


def test_excuse_submit_uses_page_budget():
    page = _FakePage({"#button_poslat": {"visible": True}})
    client = _unwrapped(_bakalari(page, NAV_CFG), page)
    assert client._verify_submission() is True
    by_selector = {}
    for s, st, t in page.waits:
        by_selector.setdefault((s, st), []).append(t)
    assert by_selector.get(("#button_poslat", "visible")) == [60000]
    assert by_selector.get(("#button_poslat", "detached")) == [60000]
    assert (("#button_poslat", 60000) in
            [(s, t) for s, t in page.clicks])


def test_cold_start_blank_tab_skips_probes():
    """about:blank: navigate at once, no probe budgets burned on blank."""
    page = _FakePage(dict(LOGIN_FORM), url="about:blank")
    client = _bakalari(page, {"page_load_timeout_s": 5, "element_wait_s": 3})
    client.login()
    assert client.logged_in is True
    assert page.goto_count == 1
    # No fast/state probes before the navigation: only the single
    # post-navigation auth check ran.
    assert page._auth_calls == 1


def test_once_click_never_retries_dispatched_navigation():
    """A nav click that dispatches and then times out fires exactly once.

    The Komens row-click / excuse-submit shape: the navigation outlasts
    the budget AFTER dispatch. Retrying would reopen the same message or
    send the same excuse twice.
    """
    from strakalari.core.cancel import wrap_page

    page = _FakePage({".ico32-modul-komens": {"visible": True}})
    page.click_fail_first.add(".ico32-modul-komens")
    wrapped = wrap_page(page, lambda: False)
    with pytest.raises(_Timeout):
        wrapped.locator(".ico32-modul-komens").first.click(
            timeout=60000, once=True)
    assert [s for s, _ in page.clicks].count(".ico32-modul-komens") == 1


def test_once_click_cancel_during_actionability_wait():
    """Cancel is honored while waiting for the element — before any click."""
    from strakalari.core.cancel import wrap_page

    page = _FakePage({"#odhlasit": {"visible": False}})
    calls = {"n": 0}

    def _pred():
        calls["n"] += 1
        return calls["n"] >= 4

    wrapped = wrap_page(page, _pred)
    with pytest.raises(InterruptedError):
        wrapped.locator("#odhlasit").first.click(timeout=60000, once=True)
    assert [s for s, _ in page.clicks].count("#odhlasit") == 0


def test_chunked_click_still_retries_non_navigating_clicks():
    """Same-page clicks (field focus) keep retrying until their budget."""
    from strakalari.core.cancel import wrap_page

    page = _FakePage({"#username": {"visible": True}})
    page.click_always_fail.add("#username")
    wrapped = wrap_page(page, lambda: False)
    with pytest.raises(_Timeout) as exc_info:
        wrapped.locator("#username").first.click(timeout=5000)
    assert [s for s, _ in page.clicks].count("#username") == 5
    assert "budget 5000ms in 1000ms slices" in str(exc_info.value)
