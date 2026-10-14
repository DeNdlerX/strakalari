"""Více — the phone menu: the screens that don't fit the bottom bar."""

from __future__ import annotations

import flet as ft

from .. import components as C
from ..state import AppState
from ..strings import S

#: (route, icon, label key): the side rail's other destinations, same icons.
ENTRIES = (
    ("absences", ft.Icons.EVENT_BUSY_OUTLINED, "nav_absences"),
    ("planner", ft.Icons.EVENT_NOTE_OUTLINED, "nav_planner"),
    ("activity", ft.Icons.HISTORY_OUTLINED, "nav_activity"),
    ("settings", ft.Icons.SETTINGS_OUTLINED, "nav_settings"),
)


def _open(state: AppState, route: str) -> None:
    if route == "settings":
        state.settings_open = False  # From the menu, Settings opens on its list.
    state.go(route)


def build(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    tiles: list[ft.Control] = []
    for route, icon, label in ENTRIES:
        tiles.append(ft.ListTile(
            leading=ft.Icon(icon, color=tok.accent),
            title=C.txt(S(label), tok, size=tok.fs_section),
            trailing=ft.Icon(ft.Icons.CHEVRON_RIGHT, color=tok.faint),
            bgcolor=tok.card,
            shape=ft.RoundedRectangleBorder(radius=tok.radius_md),
            on_click=lambda e, r=route: _open(state, r),
        ))
    return C.scrollable(state, "more", [C.title(S("nav_more"), tok), *tiles],
                        spacing=tok.gap // 2 + 2, expand=True)
