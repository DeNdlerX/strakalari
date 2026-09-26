"""Every Settings section builds, and the risky handlers do what they say.

The sections are otherwise only exercised by hand: the automation rules
(Auto mode, pause) and the school calendar (days off drive the planner and
lunch cutoffs) deserve checks of their own.
"""

from __future__ import annotations

from datetime import date, timedelta
from types import SimpleNamespace

import pytest

from strakalari.flet_ui.strings import S


def _walk(control):
    yield control
    for attr in ("content", "controls"):
        value = getattr(control, attr, None)
        for child in (value if isinstance(value, list) else [value]):
            if child is not None and hasattr(child, "_i"):
                yield from _walk(child)


def _texts(control) -> list[str]:
    out = []
    for c in _walk(control):
        for attr in ("value", "text", "label"):
            v = getattr(c, attr, None)
            if isinstance(v, str):
                out.append(v)
    return out


def _section(state, section: str) -> list:
    from strakalari.flet_ui.views.settings import SettingsView

    state.settings_section = section
    view = SettingsView(state, None)
    method = {"calendar": view._calendar, "rules": view._automation,
              "browser": view._browser}[section]
    return method()


def _roots(controls: list):
    for c in controls:
        yield from _walk(c)


def _by_label(controls: list, label: str):
    """The control labelled ``label``: its own ``label``, or the field of a
    labelled-field column (``[caption Text, TextField]``)."""
    for c in _roots(controls):
        if getattr(c, "label", None) == label:
            return c
        kids = getattr(c, "controls", None)
        if (isinstance(kids, list) and len(kids) >= 2
                and getattr(kids[0], "value", None) == label):
            return kids[1]
    raise AssertionError(f"no control labelled {label!r}")


def _button(controls: list, text: str):
    for c in _roots(controls):
        if getattr(c, "on_click", None) is not None and text in _texts(c):
            return c
    raise AssertionError(f"no button {text!r}")


def _click(control):
    control.on_click(SimpleNamespace(control=control))


# -- every section, both languages ---------------------------------------------------

@pytest.mark.parametrize("language", ["cs", "en"])
def test_every_section_builds(app_state, language):
    from strakalari.core.i18n import get_language, set_language
    from strakalari.flet_ui.views import settings
    from strakalari.flet_ui.views.settings.common import SECTIONS

    before = get_language()
    set_language(language)
    try:
        app_state.save({"school_preset_id": "gekom_2026_2027",
                        "user_free_days": [{"date": "02.11.2026", "label": "Výlet"}],
                        "gemini_api_key": "x"})
        for section, _label in SECTIONS:
            app_state.settings_section = section
            assert settings.build(app_state, None) is not None, section
    finally:
        set_language(before)


# -- school calendar -------------------------------------------------------------------

class TestCalendar:
    def test_add_single_day(self, app_state):
        day = (date.today() + timedelta(days=30)).strftime("%d.%m.%Y")
        app_state.save({"school_preset_id": "custom"})
        app_state.set_draft("cal:add_date", day)
        app_state.set_draft("cal:add_label", "Výlet")
        _click(_button(_section(app_state, "calendar"), S("cal_add_single")))
        assert {"date": day, "label": "Výlet"} in app_state.get("user_free_days")
        assert app_state.draft("cal:add_date", "") == ""

    def test_invalid_date_saves_nothing(self, app_state):
        app_state.save({"school_preset_id": "custom", "user_free_days": []})
        app_state.set_draft("cal:add_date", "31.02.2026")
        _click(_button(_section(app_state, "calendar"), S("cal_add_single")))
        assert app_state.get("user_free_days") == []

    def test_add_range_then_delete_it(self, app_state):
        start = date.today() + timedelta(days=40)
        app_state.save({"school_preset_id": "custom", "user_free_days": []})
        app_state.set_draft("cal:from_", start.strftime("%d.%m.%Y"))
        app_state.set_draft("cal:to", (start + timedelta(days=2)).strftime("%d.%m.%Y"))
        app_state.set_draft("cal:range_label", "Prázdniny")
        _click(_button(_section(app_state, "calendar"), S("cal_add_range")))
        assert len(app_state.get("user_free_days")) == 3
        # The three days show as one grouped row with one delete button.
        _click(_button(_section(app_state, "calendar"), S("delete")))
        assert app_state.get("user_free_days") == []

    def test_reversed_range_is_rejected(self, app_state):
        app_state.save({"school_preset_id": "custom", "user_free_days": []})
        app_state.set_draft("cal:from_", "10.11.2026")
        app_state.set_draft("cal:to", "01.11.2026")
        _click(_button(_section(app_state, "calendar"), S("cal_add_range")))
        assert app_state.get("user_free_days") == []

    def test_closure_date_is_validated(self, app_state):
        field = _by_label(_section(app_state, "calendar"), S("cal_sem1"))
        field.value = "not a date"
        field.on_blur(SimpleNamespace(control=field))
        assert app_state.get("sem1_close", "") in ("", None)


# -- automation rules ------------------------------------------------------------------

class TestAutomationRules:
    def test_switching_to_auto_needs_confirmation(self, app_state, monkeypatch):
        import strakalari.flet_ui.safety as safety

        asked = {}
        monkeypatch.setattr(safety, "confirm_auto_mode",
                            lambda page, key, on_confirm, on_dry_run, on_cancel:
                            asked.update(key=key, ok=on_confirm, cancel=on_cancel))
        app_state.save({"excuse_mode": "confirm"})
        dd = _by_label(_section(app_state, "rules"), S("excuse_mode_label"))
        dd.value = "auto"
        dd.on_select(SimpleNamespace(control=dd))
        assert asked["key"] == "excuse_mode"
        assert app_state.get("excuse_mode") == "confirm"  # nothing saved yet
        asked["cancel"]()
        assert app_state.get("excuse_mode") == "confirm" and dd.value == "confirm"
        dd.value = "auto"
        dd.on_select(SimpleNamespace(control=dd))
        asked["ok"]()
        assert app_state.get("excuse_mode") == "auto"

    def test_other_modes_save_without_asking(self, app_state, monkeypatch):
        import strakalari.flet_ui.safety as safety

        monkeypatch.setattr(safety, "confirm_auto_mode",
                            lambda *a, **k: pytest.fail("must not ask"))
        dd = _by_label(_section(app_state, "rules"), S("order_mode_label"))
        dd.value = "dry_run"
        dd.on_select(SimpleNamespace(control=dd))
        assert app_state.get("strava_order_mode") == "dry_run"

    def test_pause_switch_pauses_automation(self, app_state):
        switch = _by_label(_section(app_state, "rules"), S("automation_pause"))
        switch.value = True
        switch.on_change(SimpleNamespace(control=switch))
        assert app_state.automation_paused() is True

    @pytest.mark.parametrize("raw,expected", [("0", 1), ("15", 15), ("2,7", 2)])
    def test_interval_is_clamped(self, app_state, raw, expected):
        field = _by_label(_section(app_state, "rules"), S("check_interval"))
        field.value = raw
        field.on_blur(SimpleNamespace(control=field))
        assert app_state.get("check_interval_minutes") == expected

    def test_invalid_cutoff_is_not_saved(self, app_state):
        app_state.save({"lunch_order_cutoff_time": "12:00"})
        field = _by_label(_section(app_state, "rules"), S("lunch_cutoff_label"))
        field.value = "25:99"
        field.on_blur(SimpleNamespace(control=field))
        assert app_state.get("lunch_order_cutoff_time") == "12:00"


# -- browser & background ----------------------------------------------------------------

def test_failed_autostart_reverts_the_switch(app_state, monkeypatch):
    import strakalari.core.autostart as autostart

    monkeypatch.setattr(autostart, "is_autostart_enabled", lambda: False)
    monkeypatch.setattr(autostart, "set_autostart", lambda wanted: False)
    switch = _by_label(_section(app_state, "browser"), S("autostart"))
    switch.value = True
    switch.update = lambda: None
    switch.on_change(SimpleNamespace(control=switch))
    assert switch.value is False
