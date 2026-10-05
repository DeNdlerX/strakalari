"""Microsoft Store (MSIX) runtime detection.

The same frozen binary ships in the classic Inno Setup installer and in
the Store MSIX package: behaviour differences are decided at runtime via
package identity, NOT via a separate build flavour. Anything that the
Store owns (updates) or that the MSIX container forbids (HKCU Run
autostart, writes next to the exe) is gated on :func:`is_store_package`.
"""

from __future__ import annotations

import functools
import os
import sys

#: Error code GetCurrentPackageFullName returns for unpackaged processes.
_APPMODEL_ERROR_NO_PACKAGE = 15700


def _has_package_identity() -> bool:
    """True when the process runs with a package identity (MSIX)."""
    if sys.platform != "win32":
        return False
    try:
        import ctypes

        length = ctypes.c_uint(0)
        rc = ctypes.windll.kernel32.GetCurrentPackageFullName(
            ctypes.byref(length), None
        )
        # Packaged -> ERROR_INSUFFICIENT_BUFFER (122); unpackaged -> 15700.
        return rc != _APPMODEL_ERROR_NO_PACKAGE
    except Exception:
        return False


@functools.lru_cache(maxsize=1)
def is_store_package() -> bool:
    """True when the frozen app runs inside the Store MSIX package (cached).

    Dev runs never count: the Microsoft Store's python.exe is itself
    packaged, and must not switch off update checks or autostart.
    """
    return bool(getattr(sys, "frozen", False)) and _has_package_identity()


def legacy_desktop_data_dir() -> str | None:
    """Where the classic Inno install keeps user data, if it exists.

    The per-user Inno Setup installs next to the exe, i.e.
    ``%LOCALAPPDATA%\\Programs\\Strakalari`` — while the Store build
    resolves to ``%LOCALAPPDATA%\\Strakalari`` (see
    ``strakalari.core.helpers``). Returns None when there is nothing to
    migrate from.
    """
    if sys.platform != "win32":
        return None
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    if not base:
        return None
    legacy = os.path.join(base, "Programs", "Strakalari")
    if os.path.isfile(os.path.join(legacy, "config.json")):
        return legacy
    return None
