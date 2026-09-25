"""Nastavení — one category at a time (side navigation).

Every section autosaves (no Save buttons): toggles and dropdowns save
on change, text fields save on blur/Enter. Typing never triggers a
re-render — half-written values sit in ``state.drafts`` until commit.

One module per group of sections (mixins of :class:`SettingsView`):
``accounts``, ``school_calendar``, ``automation``, ``app_prefs``;
``common`` holds the section ids and shared field helpers.
"""

from .common import NAV_GROUPS, SECTION_ICONS, SECTIONS
from .view import SettingsView, build

__all__ = ["NAV_GROUPS", "SECTION_ICONS", "SECTIONS", "SettingsView", "build"]
