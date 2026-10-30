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

#: Sections with nothing to set in the phone app on that platform. Android
#: has its own background running (in "browser") and notifications; iOS
#: has neither yet.
HIDDEN_SECTIONS = {"ios": frozenset({"browser", "notifications"})}
#: Sections only the Android app has (the wake-up alarm rings on the phone).
ANDROID_SECTIONS = frozenset({"alarm"})


def _sections_here() -> set[str]:
    from strakalari.core.packaging import mobile_platform

    platform = mobile_platform() or ""
    ids = {s for s, _ in SECTIONS} - HIDDEN_SECTIONS.get(platform, frozenset())
    return ids if platform == "android" else ids - ANDROID_SECTIONS


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
        here = _sections_here()
        labels = {s: k for s, k in SECTIONS if s in here}
        vpad = 14 if C.narrow(state) else 8  # finger-sized rows on a phone
        items: list[ft.Control] = []
        for group_key, section_ids in NAV_GROUPS:
            if items:
                items.append(ft.Container(height=8))
            items.append(ft.Container(C.section_header(S(group_key), tok),
                                      padding=ft.Padding(left=10, top=0, right=0, bottom=2)))
            for section_id in section_ids:
                if section_id not in labels:
                    continue
                # Phone: the list stands alone, nothing is "open" beside it.
                active = state.settings_section == section_id and not C.narrow(state)
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
                    padding=ft.Padding(left=10, top=vpad, right=10, bottom=vpad),
                    on_click=lambda e, s=section_id: state.set_settings_section(s),
                    tooltip=S(labels[section_id]),
                ))
        return ft.Column(items, spacing=2, tight=True,
                         horizontal_alignment=ft.CrossAxisAlignment.STRETCH)

    def build(self) -> ft.Control:
        state, tok = self.state, self.state.tok
        T.offer(state, "settings")
        section = state.settings_section
        if section not in _sections_here():
            section = "accounts"
        builder = {
            "accounts": self._accounts,
            "limits": self._limits,
            "calendar": self._calendar,
            "alarm": self._wakeup,
            "templates": self._templates,
            "rules": self._automation,
            "browser": self._browser,
            "appearance": self._appearance,
            "ai": self._ai,
            "advanced": self._advanced,
            "notifications": self._notifications,
            "diagnostics": self._diagnostics,
        }[section]
        if C.narrow(state):
            return self._build_narrow(section, builder)
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

    def _build_narrow(self, section: str, builder) -> ft.Control:
        """Phone: the section list, or one open section with a back arrow."""
        state, tok = self.state, self.state.tok
        if not state.settings_open:
            return C.scrollable(
                state, "settings:nav",
                [C.header_row(tok, S("settings_title")), self._nav(), C.bottom_spacer(tok)],
                spacing=tok.gap, expand=True,
            )
        label = next((S(k) for sid, k in SECTIONS if sid == section), "")
        head = ft.Row(
            [
                ft.IconButton(ft.Icons.ARROW_BACK, tooltip=S("settings_title"),
                              on_click=lambda e: state.close_settings_section()),
                ft.Container(C.title(label, tok), expand=True),
            ],
            spacing=4,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
        return C.scrollable(
            state, f"settings:{section}",
            [head, *builder(), C.bottom_spacer(tok)],
            spacing=tok.gap, expand=True,
        )


def build(state: AppState, page: ft.Page) -> ft.Control:
    return SettingsView(state, page).build()
