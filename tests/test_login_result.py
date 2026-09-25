"""Login result wait: fast fail on bad credentials, truthful diagnostics.

Regression tests for a refresh failing with "Timeout 250ms exceeded"
after clicking the Bakalari login button. The 250ms was a single cancel
slice (the full element budget was actually waited), and the real cause
— wrong credentials answered on the same login form — was never probed.
"""
import time

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

    def _state(self):
        return self._page.states.get(self._selector, {})

    def is_visible(self):
        return bool(self._state().get("visible", False))

    def inner_text(self):
        return self._state().get("text", "")

    def wait_for(self, state=None, timeout=None):
        if state == "visible" and self.is_visible():
            return True
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout(f"Timeout {timeout}ms exceeded.")

    def click(self, timeout=None, **kwargs):
        return True


class _FakePage:
    def __init__(self, states, url="https://skola.bakalari.cz/login",
                 body_text=""):
        self.states = states
        self.url = url
        self.body_text = body_text

    def locator(self, selector):
        return _FakeLocator(self, selector)

    def get_by_text(self, *args, **kwargs):
        return _FakeLocator(self, "")

    def goto(self, url, timeout=None, wait_until=None):
        return True

    def wait_for_function(self, js, timeout=None):
        time.sleep(min((timeout or 0) / 1000.0, 10))
        raise _Timeout("condition never true")

    def wait_for_timeout(self, ms):
        time.sleep(ms / 1000.0)

    def evaluate(self, js):
        if "innerText" in js:
            return self.body_text
        if "document.title" in js:
            return "Bakalari"
        return ""


def _client(page):
    from strakalari.core.bakalari_client import BakalariClient

    bm = type("BM", (), {"page": page})()
    return BakalariClient(
        bm,
        {"bakalari_url": "https://skola.bakalari.cz",
         "element_wait_s": 30},
        logger=None,
    )


def test_login_success_returns_immediately():
    page = _FakePage({".ico32-modul-vyuka": {"visible": True}})
    started = time.monotonic()
    _client(page)._wait_for_login_result(30000)
    assert time.monotonic() - started < 5.0


def test_wrong_password_fails_fast_with_user_error():
    from strakalari.core.error_report import UserError

    page = _FakePage({
        ".login-error": {"visible": True,
                         "text": "Nesprávné uživatelské jméno nebo heslo."},
        "#username": {"visible": True},
    })
    started = time.monotonic()
    with pytest.raises(UserError) as exc_info:
        _client(page)._wait_for_login_result(30000)
    assert time.monotonic() - started < 5.0
    assert "heslo" in str(exc_info.value)


def test_keyword_fallback_without_error_node():
    from strakalari.core.error_report import UserError

    page = _FakePage(
        {"#username": {"visible": True}},
        body_text="Vítejte. Nesprávné heslo, zkuste to prosím znovu.",
    )
    with pytest.raises(UserError) as exc_info:
        _client(page)._wait_for_login_result(30000)
    assert "heslo" in str(exc_info.value)


def test_timeout_raises_user_error_with_diagnostics():
    from strakalari.core.error_report import UserError

    page = _FakePage(
        {"#username": {"visible": True}},
        body_text="Vítejte, zadejte jméno a heslo.",
        url="https://skola.bakalari.cz/login",
    )
    started = time.monotonic()
    with pytest.raises(UserError) as exc_info:
        _client(page)._wait_for_login_result(1200)
    elapsed = time.monotonic() - started
    assert elapsed >= 1.0
    message = str(exc_info.value)
    assert "250ms" not in message
    assert "login_form=visible" in message
    assert "skola.bakalari.cz" in message


def test_slice_timeout_reports_full_budget_and_keeps_type():
    from strakalari.core.cancel import wait_visible

    loc = _FakeLocator(_FakePage({}), ".ico32-modul-vyuka")
    with pytest.raises(_Timeout) as exc_info:
        wait_visible(loc, 1000, lambda: False)
    assert "budget 1000ms in 250ms slices" in str(exc_info.value)
