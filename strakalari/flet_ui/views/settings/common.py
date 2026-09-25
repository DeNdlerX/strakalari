"""Settings: section ids, navigation groups and shared field helpers."""

from __future__ import annotations

import flet as ft

from ... import components as C
from ...overlays import snack
from ...state import AppState
from ...strings import S


SECTIONS: tuple[tuple[str, str], ...] = (
    ("accounts", "sec_accounts"),
    ("limits", "sec_limits"),
    ("calendar", "sec_calendar"),
    ("templates", "sec_templates"),
    ("rules", "sec_rules"),
    ("browser", "sec_browser"),
    ("appearance", "sec_appearance"),
    ("ai", "sec_ai"),
    ("advanced", "sec_advanced"),
    ("notifications", "sec_notifications"),
    ("diagnostics", "sec_diagnostics"),
)

#: Sidebar grouping (group caption -> sections) and one icon per section.
NAV_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("sec_group_school", ("accounts", "limits", "calendar")),
    ("sec_group_automation", ("rules", "templates", "ai", "browser")),
    ("sec_group_app", ("appearance", "notifications")),
    ("sec_group_advanced", ("advanced", "diagnostics")),
)
SECTION_ICONS: dict[str, str] = {
    "accounts": ft.Icons.PERSON_OUTLINE,
    "limits": ft.Icons.PERCENT,
    "calendar": ft.Icons.CALENDAR_MONTH_OUTLINED,
    "templates": ft.Icons.DESCRIPTION_OUTLINED,
    "rules": ft.Icons.BOLT_OUTLINED,
    "browser": ft.Icons.WEB_OUTLINED,
    "appearance": ft.Icons.PALETTE_OUTLINED,
    "ai": ft.Icons.AUTO_AWESOME_OUTLINED,
    "advanced": ft.Icons.TUNE,
    "notifications": ft.Icons.NOTIFICATIONS_OUTLINED,
    "diagnostics": ft.Icons.BUG_REPORT_OUTLINED,
}


def _browser_available() -> bool:
    """True when the automation Chromium is installed (login tests need it)."""
    try:
        from strakalari.core.browser import is_browser_installed

        return bool(is_browser_installed())
    except Exception:
        return False


def _save_feedback(state: AppState, page: ft.Page, updates: dict) -> bool:
    """Saves and toasts saved/save_failed honestly. Returns success."""
    try:
        ok = bool(state.save(updates))
    except Exception:
        ok = False
    try:
        snack(page, S("saved") if ok else S("save_failed"))
    except Exception:
        pass
    return ok


def _save_quiet(state: AppState, page: ft.Page, updates: dict) -> bool:
    """Autosave: silent on success, toasts only on failure.

    Never re-renders: the edited control already shows the new value, and
    a rebuild would swap every control under the click that caused the
    blur (lost clicks, lost focus, a visible jump).
    """
    save = getattr(state, "save_quiet", None) or state.save
    try:
        ok = bool(save(updates))
    except Exception:
        ok = False
    if not ok:
        try:
            snack(page, S("save_failed"))
        except Exception:
            pass
    return ok


def _same(a, b) -> bool:
    """True when a stored config value already equals the new one."""
    if a == b:
        return True
    try:
        return float(a) == float(b)
    except (TypeError, ValueError):
        return str(a if a is not None else "") == str(b if b is not None else "")


def _show_value(control, value) -> None:
    """Puts the normalized saved value back into the edited field."""
    try:
        text = "" if value is None else str(value)
        if control is not None and getattr(control, "value", None) != text:
            control.value = text
            control.update()
    except Exception:
        pass


def _tpl_editor(state: AppState, page: ft.Page, key: str, title_key: str) -> ft.Control:
    values = state.get(key, [])
    if not isinstance(values, list):
        values = []
    values = [str(v) for v in values]
    column = ft.Column(
        spacing=6, tight=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )

    def _commit() -> None:
        cleaned = [str(v) for v in values if str(v or "").strip()]
        if cleaned == [str(v) for v in (state.get(key, []) or [])]:
            return  # focus moved without an edit: nothing to save
        _save_quiet(state, page, {key: cleaned})

    def _rebuild():
        column.controls.clear()
        for idx, text in enumerate(list(values)):
            def _on_type(e, i=idx):
                values[i] = e.control.value or ""

            def _on_done(e, i=idx):
                values[i] = e.control.value or ""
                _commit()

            box = C.labeled_field(
                state.tok, f"{S(title_key)} {idx + 1}", value=str(text), multiline=True,
                on_change=_on_type, on_blur=_on_done, on_submit=_on_done,
            )

            def _delete(e, i=idx):
                values.pop(i)
                _commit()
                _rebuild()
                try:
                    page.update()
                except Exception:
                    pass

            column.controls.append(
                ft.Row([ft.Container(box, expand=True),
                        ft.IconButton(ft.Icons.DELETE_OUTLINE, tooltip=S("delete"),
                                      on_click=_delete)],
                       vertical_alignment=ft.CrossAxisAlignment.START)
            )

    _rebuild()

    def _add(e):
        values.append("")
        _rebuild()
        try:
            page.update()
        except Exception:
            pass

    return C.form_card(
        C.txt(S(title_key), state.tok, bold=True), column,
        ft.Row(
            [
                ft.TextButton(f"+ {S('add')}", on_click=_add),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        tok=state.tok,
    )


def _test_result(state: AppState, service: str) -> ft.Control | None:
    tok = state.tok
    if state.testing == service:
        return C.txt(S("testing"), tok, size=tok.fs_small, muted=True)
    last = state.last_test
    if last.get("service") != service or not last.get("at"):
        return None
    color = tok.green if last.get("ok") else tok.red
    prefix = S("connection_ok") if last.get("ok") else S("connection_failed")
    return C.txt(f"{prefix} ({last.get('at')}): {last.get('message', '')}",
                 tok, size=tok.fs_small, color=color)
