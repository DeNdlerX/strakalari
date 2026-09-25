"""The settings screen: one category at a time with side navigation."""

from __future__ import annotations

import flet as ft

from ... import components as C
from ... import tutorial as T
from ...overlays import snack
from ...state import AppState
from ...strings import S
from ...theme import tint
from .accounts import AccountsMixin
from .app_prefs import AppPrefsMixin
from .automation import AutomationMixin
from .common import (
    NAV_GROUPS, SECTION_ICONS, SECTIONS, _save_quiet, _same, _show_value,
)
from .school_calendar import SchoolCalendarMixin


class SettingsView(AccountsMixin, SchoolCalendarMixin, AutomationMixin, AppPrefsMixin):
    def __init__(self, state: AppState, page: ft.Page) -> None:
        self.state = state
        self.page = page

    # -- field helpers (draft-backed, no re-render while typing) -----------
    def _v(self, key: str, fallback: str = "") -> str:
        return self.state.draft(key, fallback)

    def _bind(self, key: str):
        return lambda e, k=key: self.state.set_draft(k, e.control.value or "")

    def _text(self, label: str, key: str, fallback: str = "",
              password: bool = False, multiline: bool = False,
              hint: str = "") -> ft.Control:
        return C.labeled_field(
            self.state.tok, label, value=self._v(key, fallback),
            password=password, multiline=multiline, hint=hint,
            on_change=self._bind(key),
        )

    def _auto(self, label: str, dkey: str, ckey: str, fallback: str = "",
              password: bool = False, multiline: bool = False,
              hint: str = "", parse=None) -> ft.Control:
        """Autosaving text field: typing fills drafts, blur/Enter saves."""
        state, page = self.state, self.page

        def _commit(e):
            try:
                val = e.control.value if e.control is not None else state.draft(dkey, fallback)
            except Exception:
                val = state.draft(dkey, fallback)
            val = "" if val is None else str(val)
            if password and not val.strip():
                return  # blank keeps the stored secret
            if parse is not None:
                try:
                    new_val = parse(val)
                except ValueError as exc:
                    snack(page, str(exc) or S("save_failed"))
                    return
            else:
                new_val = val
            if not password and _same(state.get(ckey), new_val):
                state.drafts.pop(dkey, None)
                _show_value(e.control, new_val)
                return  # focus moved without an edit: nothing to save
            if not _save_quiet(state, page, {ckey: new_val}):
                return
            if password:
                try:
                    e.control.hint_text = S("password_saved_hint")
                    e.control.update()
                except Exception:
                    pass
            else:
                state.drafts.pop(dkey, None)
                _show_value(e.control, new_val)

        return C.labeled_field(
            self.state.tok, label, value=self._v(dkey, fallback),
            password=password, multiline=multiline, hint=hint,
            on_change=self._bind(dkey),
            on_blur=_commit, on_submit=_commit,
        )

    def _nav(self) -> ft.Control:
        """Grouped list nav (icon + label) instead of a stack of pills."""
        state, tok = self.state, self.state.tok
        labels = dict(SECTIONS)
        items: list[ft.Control] = []
        for group_key, section_ids in NAV_GROUPS:
            if items:
                items.append(ft.Container(height=8))
            items.append(ft.Container(C.section_header(S(group_key), tok),
                                      padding=ft.Padding(left=10, top=0, right=0, bottom=2)))
            for section_id in section_ids:
                if section_id not in labels:
                    continue
                active = state.settings_section == section_id
                color = tok.accent if active else tok.muted
                items.append(ft.Container(
                    content=ft.Row(
                        [
                            ft.Icon(SECTION_ICONS.get(section_id, ft.Icons.CIRCLE_OUTLINED),
                                    size=18, color=color),
                            ft.Text(S(labels[section_id]), size=tok.fs_body,
                                    color=tok.text if active else tok.muted,
                                    weight=ft.FontWeight.W_600 if active
                                    else ft.FontWeight.NORMAL,
                                    max_lines=1, overflow=ft.TextOverflow.ELLIPSIS,
                                    expand=True),
                        ],
                        spacing=10,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    bgcolor=tint(tok.accent, 0.16) if active else None,
                    border_radius=tok.radius_sm,
                    padding=ft.Padding(left=10, top=8, right=10, bottom=8),
                    on_click=lambda e, s=section_id: state.set_settings_section(s),
                    tooltip=S(labels[section_id]),
                ))
        return ft.Column(items, spacing=2, tight=True,
                         horizontal_alignment=ft.CrossAxisAlignment.STRETCH)

    def build(self) -> ft.Control:
        state, tok = self.state, self.state.tok
        T.offer(state, "settings")
        section = state.settings_section
        if section not in {s for s, _ in SECTIONS}:
            section = "accounts"
        builder = {
            "accounts": self._accounts,
            "limits": self._limits,
            "calendar": self._calendar,
            "templates": self._templates,
            "rules": self._automation,
            "browser": self._browser,
            "appearance": self._appearance,
            "ai": self._ai,
            "advanced": self._advanced,
            "notifications": self._notifications,
            "diagnostics": self._diagnostics,
        }[section]
        content = C.scrollable(
            state, f"settings:{section}",
            [C.header_row(tok, S(label_key))
             for sid, label_key in SECTIONS if sid == section]
            + builder(),
            spacing=tok.gap, expand=True,
        )
        return ft.Column(
            [C.header_row(tok, S("settings_title")),
             ft.Row(
                 [
                     ft.Container(self._nav(), width=210),
                     ft.VerticalDivider(width=1, color=tok.border),
                     ft.Container(content, expand=True),
                 ],
                 expand=True,
                 vertical_alignment=ft.CrossAxisAlignment.START,
             )],
            spacing=tok.gap,
            expand=True,
        )


def build(state: AppState, page: ft.Page) -> ft.Control:
    return SettingsView(state, page).build()
