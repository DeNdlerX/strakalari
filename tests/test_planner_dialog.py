"""Absence-planner dialogs: cancel must close, template pick must stick.

Uses a FakePage with faithful ``ft.Page`` dialog semantics: ``pop_dialog``
returns None (no exception) when no dialog is open, otherwise closes the
topmost open dialog. Regression cover for: cancel leaving the modal open
(``close_dialog`` skipped ``page.update()`` after a "successful" pop) and
template selection not updating the preview.
"""

from datetime import datetime
from types import SimpleNamespace

import flet as ft

from strakalari.flet_ui.overlays import close_dialog
from strakalari.flet_ui.views import planner as P


TPL_A = "Template A line1\nA-second-line"
TPL_B = "Template B line1\nB-second-line"


class FakeTok:
    fs_small = 12
    fs_body = 14
    muted = "#888"
    text = "#000"
    faint = "#aaa"
    card = "#fff"
    border = "#ccc"
    surface = "#eee"
    accent = "#00f"
    accent_text = "#fff"
    overlay = "#ddd"
    yellow = "#aa0"
    red = "#f00"
    green = "#0a0"
    gap = 8
    pad = 12
    radius_md = 8
    radius_sm = 4
    fs_tiny = 10
    fs_title = 18
    fs_section = 16


class FakeState:
    tok = FakeTok()

    def __init__(self):
        self.planned = []

    def get(self, key, default=None):
        return {
            "long_absence_excuses": [TPL_A, TPL_B],
            "short_absence_excuses": [],
            "late_income_excuses": [],
            "your_signature": "",
        }.get(key, default)

    def strava_enabled(self):
        return False

    def timetable(self):
        return {}

    def subject_states(self):
        return [], []

    def plan_skip(self, day_iso, template, cancel_lunch=False):
        self.planned.append((day_iso, template, cancel_lunch))
        return True

    def plan_custom_skip(self, *args, **kwargs):
        self.planned.append((args, kwargs))
        return True


class FakePage:
    """Faithful dialog-stack semantics: pop returns None when empty."""

    def __init__(self):
        self._dialogs = []
        self.overlay = []
        self.page_updates = 0

    def show_dialog(self, dlg):
        self._dialogs.append(dlg)
        dlg.open = True

    def pop_dialog(self):
        for dlg in reversed(self._dialogs):
            if dlg.open:
                dlg.open = False
                try:
                    dlg.update()
                except Exception:
                    pass
                return dlg
        return None

    def update(self):
        self.page_updates += 1


def _click(control):
    control.on_click(SimpleNamespace())


def _select(dropdown, value=None, data=None):
    if value is not None:
        dropdown.value = value
        control = dropdown
    else:
        control = SimpleNamespace(value=None)
    dropdown.on_select(SimpleNamespace(control=control, data=data))


def test_close_dialog_pop_none_still_repaints():
    page = FakePage()
    dlg = ft.AlertDialog(title=ft.Text("x"))
    dlg.open = True  # open but unknown to the stack (stale/edge state)
    close_dialog(page, dlg)
    assert dlg.open is False
    assert page.page_updates >= 1


def test_plan_dialog_cancel_closes_and_repaints():
    page = FakePage()
    P._plan_dialog(FakeState(), page, "2026-09-22", "Po 22.09.2026")
    dlg = page._dialogs[-1]
    assert dlg.open is True
    updates_before = page.page_updates
    _click(dlg.actions[0])  # Zrušit
    assert dlg.open is False
    assert page.page_updates > updates_before


def test_plan_dialog_template_select_updates_preview():
    page = FakePage()
    P._plan_dialog(FakeState(), page, "2026-09-22", "Po 22.09.2026")
    dlg = page._dialogs[-1]
    dropdown, preview = dlg.content.controls[0], dlg.content.controls[1]
    assert preview.value == TPL_A
    _select(dropdown, value="1")
    assert preview.value == TPL_B


def test_plan_dialog_template_select_data_fallback():
    page = FakePage()
    P._plan_dialog(FakeState(), page, "2026-09-22", "Po 22.09.2026")
    dlg = page._dialogs[-1]
    dropdown, preview = dlg.content.controls[0], dlg.content.controls[1]
    _select(dropdown, data="1")  # control carries no value, key in payload
    assert preview.value == TPL_B


def test_plan_dialog_confirm_uses_picked_template():
    state = FakeState()
    page = FakePage()
    P._plan_dialog(state, page, "2026-09-22", "Po 22.09.2026")
    dlg = page._dialogs[-1]
    dropdown = dlg.content.controls[0]
    _select(dropdown, value="1")
    _click(dlg.actions[1])  # Potvrdit
    assert dlg.open is False
    assert state.planned and state.planned[0][1] == TPL_B


def test_custom_dialog_template_select_and_cancel():
    state = FakeState()
    page = FakePage()
    P._custom_plan_dialog(state, page, datetime(2026, 9, 21, 10, 0))
    dlg = page._dialogs[-1]
    dropdown, preview = dlg.content.controls[4], dlg.content.controls[5]
    assert preview.value == TPL_A
    _select(dropdown, data="1")
    assert preview.value == TPL_B
    updates_before = page.page_updates
    _click(dlg.actions[0])  # Zrušit
    assert dlg.open is False
    assert page.page_updates > updates_before
