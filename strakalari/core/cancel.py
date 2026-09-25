"""Cooperative cancellation for Playwright waits.

The GUI sets a flag when the user hits Zrušit; the refresh worker thread is
usually blocked inside a Playwright wait (``wait_for`` / ``wait_for_function``
/ ``goto`` / ``click``) with a 15-60 s ceiling, so a plain flag check between
fetch phases only takes effect after the running wait times out.

Wrapping the page with :func:`wrap_page` chunks every blocking wait into
short slices (250 ms for visibility/content waits, 1 s for clicks, 10 s
for navigations, 100 ms for sleeps) and raises ``InterruptedError`` the moment
the cancel predicate fires. Navigation-triggering clicks (``once=True``)
and forced clicks are the exception: they are never retried, because a
retry after a dispatched click would navigate or submit twice. Callers already treat ``InterruptedError`` as
"cancelled by user", so no other flow changes are needed. Slice errors that
are not cancellation (timeouts) are retried until the original total budget
runs out, preserving the slow-connection tolerance of the full timeouts.

The wrappers degrade gracefully: objects without the expected Playwright
methods (test doubles, ``None``) pass straight through.
"""

from __future__ import annotations

from typing import Any, Callable

try:
    from playwright.sync_api import Locator as _PwLocator
except Exception:  # pragma: no cover - Playwright absent in some test envs
    _PwLocator = None  # type: ignore[assignment]

try:
    from unittest.mock import NonCallableMock as _MockBase
except Exception:  # pragma: no cover - never happens on CPython
    _MockBase = ()  # type: ignore[assignment]

# Playwright's default when no timeout is given (None): 30 s. The wrappers
# must preserve it — translating None to 0 would *disable* the timeout
# (infinite wait) instead.
DEFAULT_TIMEOUT_MS = 30000


# Slice budgets: cancel latency is bounded by the largest one. Locator and
# content waits simply retry short slices (a timed-out slice waited for
# nothing, so retrying is harmless). Navigation is the exception: every
# ``page.goto`` call starts the load over, so re-issuing it on a slow
# link restarts the page from zero and it may never finish — see
# :func:`goto`, which issues once and then only waits.
WAIT_SLICE_MS = 250
CLICK_SLICE_MS = 1000
GOTO_SLICE_MS = 10000
SLEEP_SLICE_S = 0.1


def _budget(timeout: Any) -> int:
    if timeout is None:
        return DEFAULT_TIMEOUT_MS
    try:
        return max(0, int(timeout))
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_MS


def _is_cancelled(predicate: Callable[[], bool] | None) -> bool:
    if predicate is None:
        return False
    try:
        return bool(predicate())
    except Exception:
        return False


def raise_if_cancelled(is_cancelled: Callable[[], bool] | None) -> None:
    """Raises ``InterruptedError`` when the cancel predicate fires."""
    if _is_cancelled(is_cancelled):
        raise InterruptedError("Cancelled by user.")


def _with_budget(exc: Exception, total_ms: int, slice_ms: int) -> Exception:
    """Annotates a slice timeout with the full budget it exhausted.

    Chunked waits retry short slices until the original total runs out,
    then re-raise the last slice's error — whose message (e.g. \"Timeout
    250ms exceeded\") otherwise claims a fraction of what was actually
    waited. The exception type is preserved (callers catch it by type),
    only the message gains the real budget. Never raises.
    """
    try:
        total = int(total_ms)
        sl = int(slice_ms)
        if total > sl:
            suffix = f" (budget {total}ms in {sl}ms slices)"
            if exc.args and isinstance(exc.args[0], str):
                exc.args = (exc.args[0] + suffix,) + exc.args[1:]
            elif not exc.args:
                exc.args = (suffix.strip(),)
    except Exception:
        pass
    return exc


def wait_visible(locator: Any, timeout_ms: int,
                 is_cancelled: Callable[[], bool] | None) -> Any:
    """Chunked ``locator.wait_for(state='visible')`` honoring cancellation."""
    raise_if_cancelled(is_cancelled)
    total = max(0, int(timeout_ms))
    if total <= 0:
        return locator.wait_for(state="visible", timeout=0)
    deadline_slices = (total + WAIT_SLICE_MS - 1) // WAIT_SLICE_MS
    last_exc: Exception | None = None
    for _ in range(max(1, deadline_slices)):
        raise_if_cancelled(is_cancelled)
        try:
            return locator.wait_for(state="visible", timeout=WAIT_SLICE_MS)
        except InterruptedError:
            raise
        except Exception as exc:  # noqa: BLE001 - slice timeout, retry
            last_exc = exc
    if last_exc is not None:
        raise _with_budget(last_exc, total, WAIT_SLICE_MS)
    return None


def wait_state(locator: Any, state: str, timeout_ms: int,
               is_cancelled: Callable[[], bool] | None) -> Any:
    """Chunked ``locator.wait_for(state=...)`` for any state (visible/detached)."""
    raise_if_cancelled(is_cancelled)
    total = max(0, int(timeout_ms))
    if total <= 0:
        return locator.wait_for(state=state, timeout=0)
    slices = (total + WAIT_SLICE_MS - 1) // WAIT_SLICE_MS
    last_exc: Exception | None = None
    for _ in range(max(1, slices)):
        raise_if_cancelled(is_cancelled)
        try:
            return locator.wait_for(state=state, timeout=WAIT_SLICE_MS)
        except InterruptedError:
            raise
        except Exception as exc:  # noqa: BLE001 - slice timeout, retry
            last_exc = exc
    if last_exc is not None:
        raise _with_budget(last_exc, total, WAIT_SLICE_MS)
    return None


def wait_function(page: Any, js: str, timeout_ms: int,
                  is_cancelled: Callable[[], bool] | None) -> Any:
    """Chunked ``page.wait_for_function`` honoring cancellation."""
    raise_if_cancelled(is_cancelled)
    total = max(0, int(timeout_ms))
    if total <= 0:
        return page.wait_for_function(js, timeout=0)
    slices = (total + WAIT_SLICE_MS - 1) // WAIT_SLICE_MS
    last_exc: Exception | None = None
    for _ in range(max(1, slices)):
        raise_if_cancelled(is_cancelled)
        try:
            return page.wait_for_function(js, timeout=WAIT_SLICE_MS)
        except InterruptedError:
            raise
        except Exception as exc:  # noqa: BLE001 - slice timeout, retry
            last_exc = exc
    if last_exc is not None:
        raise _with_budget(last_exc, total, WAIT_SLICE_MS)
    return None


def click(locator: Any, timeout_ms: int,
          is_cancelled: Callable[[], bool] | None) -> Any:
    """Chunked locator.click: a slice timeout means not actionable yet.

    A timed-out click dispatched nothing — BUT only while it never got
    past actionability checks. A click that already dispatched and then
    times out waiting for its navigation MUST NOT be retried: the retry
    fires the navigation again (visible refresh loop) or submits twice.
    Use click_once for anything that triggers a navigation.
    Cancellation raises InterruptedError.
    """
    raise_if_cancelled(is_cancelled)
    total = max(0, int(timeout_ms))
    if total <= 0:
        return locator.click(timeout=0)
    slices = (total + CLICK_SLICE_MS - 1) // CLICK_SLICE_MS
    last_exc: Exception | None = None
    for _ in range(max(1, slices)):
        raise_if_cancelled(is_cancelled)
        try:
            return locator.click(timeout=CLICK_SLICE_MS)
        except InterruptedError:
            raise
        except Exception as exc:  # noqa: BLE001 - not actionable yet, retry
            last_exc = exc
    if last_exc is not None:
        raise _with_budget(last_exc, total, CLICK_SLICE_MS)
    return None


def click_once(locator: Any, timeout_ms: int,
               is_cancelled: Callable[[], bool] | None) -> Any:
    """One click attempt with the full budget, never retried.

    For clicks that trigger a navigation (module entries, login and
    form submits): Playwright holds the click behind the navigation it
    just triggered, so on a slow link even a dispatched click times
    out — retrying would navigate or submit again. Callers follow with
    an explicit wait for the navigation target instead, which tells a
    dispatched-but-slow click (target arrives) from one that never
    dispatched (target never arrives, loud failure). Cancellation is
    honored before the attempt.
    """
    raise_if_cancelled(is_cancelled)
    return locator.click(timeout=max(0, int(timeout_ms)))


def _wait_for_ongoing_load(page: Any, wait_until: str, total_ms: int,
                           is_cancelled: Callable[[], bool] | None) -> bool:
    """Waits for an already-issued navigation without restarting it.

    After a ``goto`` slice times out the page is usually still loading
    in the background — this waits out the remaining budget for that
    same load (load-state probe in small cancel-responsive slices)
    instead of issuing a new navigation. Returns True the moment the
    page reaches the wanted state, False when the budget runs out.
    Never raises except ``InterruptedError`` on cancel.
    """
    state = wait_until if wait_until in ('load', 'domcontentloaded', 'networkidle') else 'domcontentloaded'
    remaining = max(0, int(total_ms))
    wait_state = getattr(page, 'wait_for_load_state', None)
    if callable(wait_state):
        while remaining > 0:
            raise_if_cancelled(is_cancelled)
            step = min(WAIT_SLICE_MS, remaining)
            try:
                wait_state(state, timeout=step)
                return True
            except InterruptedError:
                raise
            except Exception:  # noqa: BLE001 - still loading, keep waiting
                remaining -= step
        return False
    wait_fn = getattr(page, 'wait_for_function', None)
    if callable(wait_fn):
        js = "() => document.readyState === 'interactive' || document.readyState === 'complete'"
        while remaining > 0:
            raise_if_cancelled(is_cancelled)
            step = min(WAIT_SLICE_MS, remaining)
            try:
                wait_fn(js, timeout=step)
                return True
            except InterruptedError:
                raise
            except Exception:  # noqa: BLE001 - still loading, keep waiting
                remaining -= step
        return False
    # Bare double with neither probe: burn the budget cancel-responsively
    # without re-navigating, then let the caller report the timeout.
    import time as _time

    while remaining > 0:
        raise_if_cancelled(is_cancelled)
        _time.sleep(min(0.1, remaining / 1000.0))
        remaining -= 100
    return False


def goto(page: Any, url: str, timeout_ms: int,
         is_cancelled: Callable[[], bool] | None,
         wait_until: str = "domcontentloaded") -> Any:
    """Issues ONE navigation, then waits out the rest of the budget.

    Re-issuing ``goto`` restarts the load from zero, so on a slow link
    retrying the navigation kept the page from ever finishing (every
    attempt died around the same point and started over). Instead the
    request goes out once: if its slice times out, the page is still
    loading in the background and the remaining budget passively waits
    for that same load. Only a hard failure that is not a timeout (DNS,
    refused — nothing in flight to wait for) gets one immediate
    re-issue, since the first attempt there usually dies on setup while
    the retry succeeds on the warm route.
    """
    from .error_report import is_timeout_error

    raise_if_cancelled(is_cancelled)
    total = max(0, int(timeout_ms))
    if total <= 0:
        return page.goto(url, timeout=0, wait_until=wait_until)
    import time as _time

    deadline = _time.monotonic() + total / 1000.0
    last_exc: Exception | None = None
    for _ in range(2):
        raise_if_cancelled(is_cancelled)
        remaining_ms = int((deadline - _time.monotonic()) * 1000)
        if remaining_ms <= 0:
            break
        try:
            return page.goto(url, timeout=min(GOTO_SLICE_MS, remaining_ms),
                             wait_until=wait_until)
        except InterruptedError:
            raise
        except Exception as exc:  # noqa: BLE001 - timeout: wait below; hard error: retry once
            last_exc = exc
            if is_timeout_error(exc):
                break
    if last_exc is None:
        return None  # pragma: no cover - loop always issues at least once
    if not is_timeout_error(last_exc):
        # Nothing was ever loading (and the one retry already ran) —
        # waiting longer cannot help.
        raise_if_cancelled(is_cancelled)
        raise _with_budget(last_exc, total, GOTO_SLICE_MS)
    remaining_ms = int((deadline - _time.monotonic()) * 1000)
    if remaining_ms > 0 and _wait_for_ongoing_load(page, wait_until, remaining_ms, is_cancelled):
        return None
    raise_if_cancelled(is_cancelled)
    raise _with_budget(last_exc, total, GOTO_SLICE_MS)


def sleep(page: Any, bm: Any, seconds: float,
          is_cancelled: Callable[[], bool] | None) -> None:
    """Interruptible sleep: short page waits, then fallbacks, else wall clock."""
    if seconds <= 0:
        return
    raise_if_cancelled(is_cancelled)
    remaining = float(seconds)
    while remaining > 0:
        raise_if_cancelled(is_cancelled)
        chunk = min(SLEEP_SLICE_S, remaining)
        try:
            if page is not None:
                page.wait_for_timeout(int(chunk * 1000))
            else:
                raise RuntimeError("no page")
        except InterruptedError:
            raise
        except Exception:  # noqa: BLE001 - page gone (mocks/closed), fallback
            try:
                if bm is not None:
                    try:
                        bm.random_sleep(chunk, 0)
                    except TypeError:
                        bm.random_sleep(chunk)
                else:
                    raise RuntimeError("no bm")
            except InterruptedError:
                raise
            except Exception:  # noqa: BLE001 - last resort
                import time as _time

                _time.sleep(chunk)
        remaining -= chunk


class _Locator:
    """Thin cancel-aware wrapper around a Playwright locator."""

    __slots__ = ("_loc", "_is_cancelled")

    def __init__(self, loc: Any, is_cancelled: Callable[[], bool] | None) -> None:
        object.__setattr__(self, "_loc", loc)
        object.__setattr__(self, "_is_cancelled", is_cancelled)

    def _wrap(self, value: Any) -> Any:
        if isinstance(value, _Locator):
            return value
        if _PwLocator is not None and isinstance(value, _PwLocator):
            return _Locator(value, self._is_cancelled)
        # Test doubles expose locator-likes via .first / .nth(): anything
        # with wait_for + click quacks enough to wrap.
        if hasattr(value, "wait_for") and hasattr(value, "click"):
            return _Locator(value, self._is_cancelled)
        return value

    @property
    def first(self) -> Any:
        return self._wrap(self._loc.first)

    @property
    def last(self) -> Any:
        try:
            return self._wrap(self._loc.last)
        except AttributeError:
            raise

    def nth(self, index: int) -> Any:
        return self._wrap(self._loc.nth(index))

    def wait_for(self, *, state: str = "visible", timeout: Any = None) -> Any:
        budget = _budget(timeout)
        if state == "visible":
            return wait_visible(self._loc, budget, self._is_cancelled)
        return wait_state(self._loc, state, budget, self._is_cancelled)

    def click(self, timeout: Any = None, **kwargs: Any) -> Any:
        raise_if_cancelled(self._is_cancelled)
        force = bool(kwargs.get("force", False))
        # once=True: single attempt for navigation-triggering clicks —
        # a dispatched click whose navigation outlasts the budget must
        # never be retried (refresh loop / double submit). The flag is
        # consumed here, never passed to Playwright.
        once = bool(kwargs.pop("once", False))
        if force or once:
            # Never retried: a click that dispatched and then timed out
            # waiting for its navigation would navigate / submit AGAIN on
            # a retry (double excuse, double order). Cancel latency is
            # kept low by waiting for actionability first in short
            # cancel-aware slices; the click itself is one attempt with
            # whatever budget is left.
            total = _budget(timeout)
            if once and not force and total > 0:
                import time as _time

                started = _time.monotonic()
                wait_visible(self._loc, total, self._is_cancelled)
                elapsed_ms = int((_time.monotonic() - started) * 1000)
                total = max(1, total - elapsed_ms)
            raise_if_cancelled(self._is_cancelled)
            return self._loc.click(timeout=total, **kwargs)
        if kwargs:
            # Non-standard options (e.g. position): single attempt, the
            # preceding wait_for already made the wait cancellable.
            return self._loc.click(timeout=timeout, **kwargs)
        return click(self._loc, _budget(timeout), self._is_cancelled)

    def __getattr__(self, name: str) -> Any:
        value = getattr(object.__getattribute__(self, "_loc"), name)
        if callable(value):
            is_cancelled = object.__getattribute__(self, "_is_cancelled")

            def _checked(*args: Any, **kwargs: Any) -> Any:
                raise_if_cancelled(is_cancelled)
                return self._wrap(value(*args, **kwargs))

            return _checked
        return self._wrap(value)


class _Page:
    """Thin cancel-aware wrapper around a Playwright page."""

    __slots__ = ("_page", "_is_cancelled")

    def __init__(self, page: Any, is_cancelled: Callable[[], bool] | None) -> None:
        object.__setattr__(self, "_page", page)
        object.__setattr__(self, "_is_cancelled", is_cancelled)

    def _wrap_loc(self, value: Any) -> Any:
        if isinstance(value, _Locator):
            return value
        return _Locator(value, self._is_cancelled)

    def locator(self, *args: Any, **kwargs: Any) -> Any:
        raise_if_cancelled(self._is_cancelled)
        return self._wrap_loc(self._page.locator(*args, **kwargs))

    def get_by_text(self, *args: Any, **kwargs: Any) -> Any:
        raise_if_cancelled(self._is_cancelled)
        return self._wrap_loc(self._page.get_by_text(*args, **kwargs))

    def goto(self, url: str, timeout: Any = None,
             wait_until: str = "domcontentloaded", **kwargs: Any) -> Any:
        return goto(self._page, url, _budget(timeout),
                    self._is_cancelled, wait_until=wait_until)

    def wait_for_function(self, js: str, timeout: Any = None, **kwargs: Any) -> Any:
        return wait_function(self._page, js, _budget(timeout),
                             self._is_cancelled)

    def wait_for_timeout(self, timeout_ms: int) -> Any:
        raise_if_cancelled(self._is_cancelled)
        remaining = max(0, int(timeout_ms))
        while remaining > 0:
            raise_if_cancelled(self._is_cancelled)
            chunk = min(int(SLEEP_SLICE_S * 1000), remaining)
            self._page.wait_for_timeout(chunk)
            remaining -= chunk
        return None

    def __getattr__(self, name: str) -> Any:
        value = getattr(object.__getattribute__(self, "_page"), name)
        if callable(value):
            is_cancelled = object.__getattribute__(self, "_is_cancelled")

            def _checked(*args: Any, **kwargs: Any) -> Any:
                raise_if_cancelled(is_cancelled)
                result = value(*args, **kwargs)
                if hasattr(result, "wait_for") and hasattr(result, "click"):
                    return _Locator(result, is_cancelled)
                return result

            return _checked
        return value


def wrap_page(page: Any, is_cancelled: Callable[[], bool] | None) -> Any:
    """Wraps a Playwright page so all blocking waits honor cancellation.

    Returns ``page`` unchanged for ``None`` (browser-less clients), for
    ``unittest.mock`` doubles (their attribute setups must keep working
    untouched), and for objects that do not look like pages (no
    ``locator`` method). Idempotent: an already-wrapped page is returned
    as-is.
    """
    if page is None or isinstance(page, _Page):
        return page
    if _MockBase and isinstance(page, _MockBase):
        return page
    if not hasattr(page, "locator"):
        return page
    return _Page(page, is_cancelled)
