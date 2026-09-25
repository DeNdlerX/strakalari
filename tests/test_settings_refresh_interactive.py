"""Settings stay interactive while the refresh worker runs.

Regression: background worker ticks (~1 Hz) used to share the same emit
channel as user actions, and the settings fast-path in render skipped
*every* rebuild during a refresh — including user-initiated ones. Section
switches, toggles and saves looked dead (content never rebuilt).

Worker ticks now travel on a progress channel (topbar-only repaint on
settings); user actions still go through the full render.
"""

import pytest

import strakalari.flet_ui.state as state_mod
from strakalari.flet_ui.app import Shell


class FakePage:
    """Minimal page double: records paints, never touches a window."""

    def __init__(self):
        self.controls = []
        self.overlay = []
        self.bgcolor = None
        self.theme_mode = None
        self.updates = 0

    def add(self, *controls):
        self.controls.extend(controls)

    def update(self):
        self.updates += 1


@pytest.fixture()
def state(monkeypatch):
    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = state_mod.AppState()
    app_state.wizard_dismissed = True
    return app_state


@pytest.fixture()
def shell(state):
    page = FakePage()
    sh = Shell(page, state)
    sh.route = "settings"
    sh.render()
    assert sh._last_built_route == "settings"
    return sh


def _spy_inner(shell, monkeypatch) -> list:
    """Counts full renders (identity checks lie: Flet skips equal trees)."""
    inner_calls: list = []
    orig_inner = shell._render_inner

    def _spy() -> None:
        inner_calls.append(1)
        orig_inner()

    monkeypatch.setattr(shell, "_render_inner", _spy)
    return inner_calls


def test_worker_tick_does_not_rebuild_settings(shell, state, monkeypatch):
    """A background progress tick repaints the topbar, keeps content."""
    state.refresh_running = True
    inner_calls = _spy_inner(shell, monkeypatch)
    before = shell.content.content
    updates = shell.page.updates
    state._last_log_emit = 0.0
    state._worker_log("stahuji data z Bakalářů…")
    assert shell.page.updates > updates  # topbar repaint reached the page
    assert inner_calls == []  # no full rebuild: inputs keep focus
    assert shell.content.content is before  # settings inputs untouched


def test_user_nav_rebuilds_settings_during_refresh(shell, state, monkeypatch):
    """Clicking a settings section while refreshing switches content."""
    state.refresh_running = True
    inner_calls = _spy_inner(shell, monkeypatch)
    before = shell.content.content
    state.set_settings_section("limits")
    assert state.settings_section == "limits"
    assert inner_calls == [1]  # user action fully rebuilt
    assert shell.content.content is not before  # new section visible


def test_progress_tick_off_settings_falls_back_to_full_render(shell, state, monkeypatch):
    """On other routes a tick still live-updates the whole view."""
    shell.route = "today"
    shell.render()
    state.refresh_running = True
    # Two identical empty "today" trees compare equal, so Flet skips the
    # store — count full renders instead of comparing control identity.
    inner_calls: list = []
    orig_inner = shell._render_inner

    def _spy_inner() -> None:
        inner_calls.append(1)
        orig_inner()

    monkeypatch.setattr(shell, "_render_inner", _spy_inner)
    state._emit_progress()
    assert len(inner_calls) == 1
