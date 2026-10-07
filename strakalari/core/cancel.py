"""Cooperative cancellation.

The GUI sets a flag when the user hits Zrušit; the Bakaláři and Strava
clients check it before every request (and between fetch phases), so a
cancel takes effect as soon as the request in flight returns. Callers
treat ``InterruptedError`` as "cancelled by user".
"""

from __future__ import annotations

from typing import Callable


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
