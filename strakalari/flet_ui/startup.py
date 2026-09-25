"""Frozen-startup hardening: stdio guards for windowed builds."""

from __future__ import annotations


def ensure_stdio() -> None:
    """Points missing/broken stdio streams at devnull. Never raises.

    PyInstaller windowed (``console=False``) apps start with ``sys.stdout``
    and ``sys.stderr`` set to None. Anything touching them dies: our own
    warning prints, and uvicorn's logging formatter, which calls
    ``.isatty()`` during the Flet server bootstrap shared by the desktop
    and web paths — the frozen app then never listens, hanging on a
    traceback dialog with no server behind it. Dev runs already own a
    console, so this is a no-op there.
    """
    import os
    import sys

    shared = None
    for name in ("stdout", "stderr"):
        try:
            stream = getattr(sys, name, None)
            if (
                stream is not None
                and hasattr(stream, "write")
                and hasattr(stream, "isatty")
            ):
                continue
            if shared is None:
                shared = _console_log() or open(os.devnull, "w", encoding="utf-8")
            setattr(sys, name, shared)
        except Exception:
            pass


#: Where a windowed (frozen) build's warnings and tracebacks go. Without
#: it every ``print("Warning: …")`` in the app vanished into devnull.
CONSOLE_LOG = "./console.log"
CONSOLE_LOG_MAX_BYTES = 1024 * 1024


def _console_log():
    """Line-buffered append handle on ``console.log`` (rotated), or None."""
    import os
    from datetime import datetime

    try:
        from strakalari.core.helpers import _resolve_path

        path = _resolve_path(CONSOLE_LOG)
        try:
            if os.path.getsize(path) > CONSOLE_LOG_MAX_BYTES:
                os.replace(path, path + ".old")
        except OSError:
            pass  # missing, or the other process is rotating it
        handle = open(path, "a", encoding="utf-8", errors="replace", buffering=1)
        handle.write(f"\n=== {datetime.now():%Y-%m-%d %H:%M:%S} pid {os.getpid()} ===\n")
        return handle
    except Exception:  # noqa: BLE001 - stdio setup must never fail startup
        return None
