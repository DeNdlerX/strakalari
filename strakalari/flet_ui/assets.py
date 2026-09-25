"""Shared resolution of bundled branding assets (app + tray icons).

Works both from a source checkout (``<repo>/assets``) and from a
PyInstaller bundle (``sys._MEIPASS/assets``), with ``FLET_ASSETS_DIR``
(flet build output) as a middle fallback.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

_ASSET_FILES = (
    "icon.ico",
    "icon.png",
    "favicon.png",
    "tray-icon.png",
    "tray-icon.ico",
    "logo.svg",
    "tray-icon.svg",
)


def assets_dir() -> Path:
    base = getattr(sys, "_MEIPASS", None)
    if base:
        cand = Path(base) / "assets"
        if cand.is_dir():
            return cand
    env = os.environ.get("FLET_ASSETS_DIR")
    if env:
        cand = Path(env)
        if cand.is_dir():
            return cand
    here = Path(__file__).resolve()
    for parent in (here.parent.parent.parent, *here.parents):
        cand = parent / "assets"
        if cand.is_dir():
            return cand
    return Path(__file__).resolve().parent.parent.parent / "assets"


def asset_path(name: str) -> Path:
    return assets_dir() / name


def window_icon_path() -> str | None:
    """Best window/exe icon for the current platform, if bundled."""
    preferred = "icon.ico" if sys.platform == "win32" else "icon.png"
    for name in (preferred, "icon.png", "icon.ico"):
        cand = asset_path(name)
        if cand.is_file():
            return str(cand)
    return None


def tray_icon_path() -> str | None:
    """High-contrast tray glyph (never the full-color logo)."""
    for name in ("tray-icon.png", "tray-icon.ico"):
        cand = asset_path(name)
        if cand.is_file():
            return str(cand)
    return None
