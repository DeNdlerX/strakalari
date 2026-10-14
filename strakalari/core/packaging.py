"""How the app is packaged: Microsoft Store (MSIX) or the phone app.

The same frozen binary ships in the classic Inno Setup installer and in
the Store MSIX package: behaviour differences are decided at runtime via
package identity, NOT via a separate build flavour. Anything that the
Store owns (updates) or that the MSIX container forbids (HKCU Run
autostart, writes next to the exe) is gated on :func:`is_store_package`.

The Android / iOS app (``tools/make_mobile.py``) runs the same sources;
everything desktop-only is gated on :func:`is_mobile`.
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


def mobile_platform() -> str | None:
    """``"android"`` / ``"ios"`` inside the phone app (``flet build``), else None.

    The Flet host sets ``FLET_PLATFORM`` before Python starts; CPython
    3.13+ also reports the OS in ``sys.platform``.
    """
    for value in (os.environ.get("FLET_PLATFORM", ""), sys.platform):
        value = str(value or "").strip().lower()
        if value in ("android", "ios"):
            return value
    return None


def is_mobile() -> bool:
    """True inside the Android / iOS app: no tray, autostart, subprocesses
    or self-update there, and the data dir is the app's private storage."""
    return mobile_platform() is not None


def mobile_store() -> str | None:
    """``"play"`` / ``"app_store"`` when the phone app came from a store
    (which then owns updates), None for the GitHub APK and off the phone.

    iOS apps only come from the App Store. For Android the build decides:
    ``tools/make_mobile.py`` writes ``_distribution.py`` next to this module
    (``aab`` = Google Play, ``apk`` = GitHub); the repo has no such file.
    """
    platform = mobile_platform()
    if platform == "ios":
        return "app_store"
    if platform != "android":
        return None
    import importlib

    try:
        # By name: the module only exists in staged builds.
        dist = importlib.import_module(f"{__package__}._distribution")
    except ImportError:
        return None
    return "play" if getattr(dist, "CHANNEL", "") == "play" else None


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
