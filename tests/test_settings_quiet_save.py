"""Settings autosaves persist without re-rendering the whole screen.

A full re-render on a blur-save replaced every control under the click
that caused the blur: that click was lost (a second click was needed),
focus was lost and the page jumped.
"""
import threading
from types import SimpleNamespace


def _renders(state) -> list:
    calls: list = []
    state.listen(lambda: calls.append(1))
    return calls


def test_save_quiet_persists_without_render(app_state):
    renders = _renders(app_state)
    synced: list = []
    app_state.listen_config(lambda: synced.append(app_state.get("check_interval_minutes")))

    assert app_state.save_quiet({"check_interval_minutes": 15}) is True
    assert app_state.get("check_interval_minutes") == 15
    assert renders == []
    # Config listeners (e.g. the scheduler interval) still hear about it.
    assert synced == [15]
    # A plain save still re-renders.
    app_state.save({"check_interval_minutes": 20})
    assert renders == [1]


def test_save_quiet_does_not_mute_other_threads(app_state):
    renders = _renders(app_state)
    other_thread_emitted = threading.Event()

    def _slow_save(updates):
        # Another thread's emit lands while the UI thread is mid-save.
        t = threading.Thread(target=app_state._emit)
        t.start()
        t.join()
        other_thread_emitted.set()
        return True

    app_state.save = _slow_save
    app_state.save_quiet({"x": 1})
    assert other_thread_emitted.is_set()
    assert renders == [1]


def _field(view, *args, **kwargs):
    column = view._auto(*args, **kwargs)
    return column.controls[1]  # [caption, TextField]


def test_autosave_field_saves_quietly_and_skips_unchanged(app_state):
    from strakalari.flet_ui.views.settings import SettingsView

    app_state.save_quiet({"bakalari_url": "https://old.example"})
    renders = _renders(app_state)
    saves: list = []
    real = app_state.save_quiet
    app_state.save_quiet = lambda updates: saves.append(updates) or real(updates)
    view = SettingsView(app_state, None)
    box = _field(view, "URL", "acc:url", "bakalari_url", "https://old.example")

    # Focus moved through the field without an edit: no write at all.
    box.on_blur(SimpleNamespace(control=box))
    assert saves == []

    box.value = "https://new.example"
    box.on_blur(SimpleNamespace(control=box))
    assert saves == [{"bakalari_url": "https://new.example"}]
    assert app_state.get("bakalari_url") == "https://new.example"
    assert renders == []


def test_autosave_shows_normalized_value_in_place(app_state):
    from strakalari.flet_ui.views.settings import SettingsView

    view = SettingsView(app_state, None)
    box = _field(view, "Interval", "rule:interval", "check_interval_minutes", "60",
                 parse=lambda raw: max(1, int(float(raw.replace(",", ".")))))
    box.value = "0,4"
    box.on_blur(SimpleNamespace(control=box))
    assert app_state.get("check_interval_minutes") == 1
    # No re-render repaints it, so the field itself shows the stored value.
    assert box.value == "1"


def _text_fields(control) -> list:
    import flet as ft

    found = [control] if isinstance(control, ft.TextField) else []
    for attr in ("content", "controls"):
        child = getattr(control, attr, None)
        for c in (child if isinstance(child, list) else [child] if child else []):
            found += _text_fields(c)
    return found


def test_template_editor_saves_names(app_state):
    from strakalari.flet_ui.views.settings.common import _tpl_editor

    app_state.save_quiet({"short_absence_excuses": ["Text A", "Text B"]})
    card = _tpl_editor(app_state, None, "short_absence_excuses", "tpl_short")
    name_a, text_a, name_b, text_b = _text_fields(card)
    assert (name_a.value, text_a.value) == ("", "Text A")

    name_a.value = "  Rodina "
    name_a.on_blur(SimpleNamespace(control=name_a))
    # Named entries become dicts; unnamed ones stay plain strings.
    assert app_state.get("short_absence_excuses") == [
        {"name": "Rodina", "text": "Text A"}, "Text B"]

    name_a.value = ""
    name_a.on_blur(SimpleNamespace(control=name_a))
    assert app_state.get("short_absence_excuses") == ["Text A", "Text B"]
