"""Shared simulated-clock helper for Phase 9 multi-day soak parity runs.

Used only by ``tools/parity/soak_refresh.py --today YYYY-MM-DD`` and
``tools/parity/demo_server_at.py --today YYYY-MM-DD``. Never touches
``strakalari/`` or ``tools/bakalari_demo_server.py``.
"""

from __future__ import annotations

import datetime as _dt
import importlib
import pkgutil
import sys


def _preload_submodules(prefix: str) -> None:
    if prefix not in sys.modules:
        try:
            importlib.import_module(prefix)
        except Exception:
            return
    mod = sys.modules.get(prefix)
    path = getattr(mod, "__path__", None)
    if path is None:
        return
    for info in pkgutil.walk_packages(path, prefix + "."):
        if info.name not in sys.modules:
            try:
                importlib.import_module(info.name)
            except Exception:
                pass


def install_fake_clock(day_iso: str, module_prefixes: tuple[str, ...]) -> _dt.datetime:
    """Pin ``date.today()`` and ``datetime.now()`` on loaded modules to ``day_iso`` at 12:00:00."""
    for prefix in module_prefixes:
        _preload_submodules(prefix)

    y, m, d = (int(part) for part in day_iso.split("-"))
    fixed_dt = _dt.datetime(y, m, d, 12, 0, 0)
    fixed_d = fixed_dt.date()

    class _DateMeta(type):
        def __instancecheck__(cls, instance: object) -> bool:
            return isinstance(instance, _dt.date)

    class _DatetimeMeta(type):
        def __instancecheck__(cls, instance: object) -> bool:
            return isinstance(instance, _dt.datetime)

    class FixedDate(_dt.date, metaclass=_DateMeta):
        @classmethod
        def today(cls) -> _dt.date:
            return fixed_d

    class FixedDatetime(_dt.datetime, metaclass=_DatetimeMeta):
        @classmethod
        def now(cls, tz=None) -> _dt.datetime:
            if tz is not None:
                return _dt.datetime(y, m, d, 12, 0, 0, tzinfo=tz)
            return fixed_dt

        @classmethod
        def today(cls) -> _dt.datetime:
            return fixed_dt

    for name, mod in list(sys.modules.items()):
        if mod is None or not any(name == p or name.startswith(p + ".") for p in module_prefixes):
            continue
        for attr, val in list(vars(mod).items()):
            if val is _dt.datetime:
                setattr(mod, attr, FixedDatetime)
            elif val is _dt.date:
                setattr(mod, attr, FixedDate)
    return fixed_dt
