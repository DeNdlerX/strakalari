"""Settings: section ids, navigation groups and shared field helpers."""

from __future__ import annotations

import flet as ft

from strakalari.core.helpers import template_name, template_text

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
    """Editor of one template list: a short name + the excuse text each.

    The name is what the excuse pickers show; unnamed templates are saved
    as plain strings (the format older versions read), named ones as
    ``{"name", "text"}``.
    """
    stored = state.get(key, [])
    if not isinstance(stored, list):
        stored = []
    values = [{"name": template_name(v), "text": template_text(v)} for v in stored]
    column = ft.Column(
        spacing=6, tight=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )

    def _commit() -> None:
        cleaned = [({"name": v["name"].strip(), "text": v["text"]} if v["name"].strip()
                    else v["text"])
                   for v in values if str(v["text"] or "").strip()]
        if cleaned == list(state.get(key, []) or []):
            return  # focus moved without an edit: nothing to save
        _save_quiet(state, page, {key: cleaned})

    def _rebuild():
        column.controls.clear()
        for idx, entry in enumerate(list(values)):
            def _typed(field: str, i: int = idx):
                def _on_type(e):
                    values[i][field] = e.control.value or ""
                return _on_type

            def _done(field: str, i: int = idx):
                def _on_done(e):
                    values[i][field] = e.control.value or ""
                    _commit()
                return _on_done

            name_box = C.labeled_field(
                state.tok, f"{S('tpl_name')} {idx + 1}", value=entry["name"],
                hint=S("tpl_name_hint"),
                on_change=_typed("name"), on_blur=_done("name"), on_submit=_done("name"),
            )
            text_box = C.labeled_field(
                state.tok, S("tpl_text"), value=entry["text"], multiline=True,
                on_change=_typed("text"), on_blur=_done("text"), on_submit=_done("text"),
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
                ft.Row([ft.Column([name_box, text_box], spacing=6, tight=True, expand=True,
                                  horizontal_alignment=ft.CrossAxisAlignment.STRETCH),
                        ft.IconButton(ft.Icons.DELETE_OUTLINE, tooltip=S("delete"),
                                      on_click=_delete)],
                       vertical_alignment=ft.CrossAxisAlignment.START)
            )

    _rebuild()

    def _add(e):
        values.append({"name": "", "text": ""})
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
