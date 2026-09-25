"""Close-to-tray: X hides the window, real quit is tray-menu Quit."""

import os
import types


class _FakeWindow:
    def __init__(self):
        self.prevent_close = False
        self.on_event = None
        self.visible = True
        self.skip_task_bar = False
        self.focused = False
        self.minimized = False
        self.destroyed = False
        self.closed = False
        self.updated = 0

    def update(self):
        self.updated += 1

    def to_front(self):
        pass

    def destroy(self):
        self.destroyed = True

    def close(self):
        self.closed = True


class _FakePage:
    def __init__(self):
        self.window = _FakeWindow()
        self.on_close = None
        self.updated = 0
        self.threaded = []

    def update(self):
        self.updated += 1

    def run_thread(self, fn, *args):
        # Mimics ft.Page.run_thread: runs with page context attached.
        self.threaded.append(getattr(fn, "__name__", "?"))
        fn(*args)


class _FakeState:
    def __init__(self, minimize=True):
        self._minimize = minimize
        self.refreshed = 0

    def get(self, key, default=None):
        if key == "minimize_to_tray":
            return self._minimize
        return default

    def start_refresh(self, scope="all"):
        self.refreshed += 1
        return True


class _FakeRunner:
    def __init__(self):
        self.stops = 0

    def stop(self):
        self.stops += 1


def _close_event_data():
    return types.SimpleNamespace(data="close", type=None)


def _close_event_type():
    return types.SimpleNamespace(data=None, type=types.SimpleNamespace(value="close"))


def _other_event():
    return types.SimpleNamespace(data="focus", type=types.SimpleNamespace(value="focus"))


class TestIsCloseEvent:
    def test_data_close(self):
        from strakalari.flet_ui.app import _is_window_close_event

        assert _is_window_close_event(_close_event_data()) is True

    def test_type_close(self):
        from strakalari.flet_ui.app import _is_window_close_event

        assert _is_window_close_event(_close_event_type()) is True

    def test_other_is_not_close(self):
        from strakalari.flet_ui.app import _is_window_close_event

        assert _is_window_close_event(_other_event()) is False


class TestSetup:
    def test_env_opt_out_quits(self, monkeypatch):
        from strakalari.flet_ui import app as app_mod

        monkeypatch.setenv("STRAKALARI_NO_TRAY", "1")
        page, state, runner = _FakePage(), _FakeState(), _FakeRunner()
        assert app_mod._setup_minimize_to_tray(page, state, runner) is None
        assert page.window.prevent_close is False
        page.on_close(None)
        assert runner.stops == 1

    def test_setting_is_read_at_every_close(self, monkeypatch):
        import threading

        from strakalari.flet_ui import app as app_mod

        # The Settings toggle applies without a restart: off -> X quits,
        # switched on later -> X hides (starting the icon then).
        monkeypatch.delenv("STRAKALARI_NO_TRAY", raising=False)
        monkeypatch.setattr(app_mod, "embedded_tray_supported", lambda: True)
        started = []

        class FakeIcon:
            def __init__(self, *a, **k):
                self.stopped = False

            def run(self):
                pass

            def stop(self):
                self.stopped = True

        class FakeThread:
            def __init__(self, target=None, daemon=None):
                self._target = target

            def start(self):
                started.append(self._target)

        fake_pystray = types.SimpleNamespace(
            Menu=lambda *items: list(items),
            MenuItem=lambda *a, **k: a, Icon=FakeIcon)
        monkeypatch.setitem(__import__("sys").modules, "pystray", fake_pystray)
        monkeypatch.setattr(app_mod, "_icon_image", lambda: object(), raising=False)
        monkeypatch.setattr(threading, "Thread", FakeThread)

        page, state, runner = _FakePage(), _FakeState(minimize=False), _FakeRunner()
        assert app_mod._setup_minimize_to_tray(page, state, runner) is not None
        assert page.window.prevent_close is True
        assert started == []  # off at start: no icon yet

        state._minimize = True
        page.window.on_event(_close_event_data())
        assert page.window.visible is False
        assert len(started) == 1  # icon started on the first hide
        assert runner.stops == 0

        page.window.visible = True
        state._minimize = False
        page.window.on_event(_close_event_data())
        assert runner.stops == 1
        assert page.window.destroyed is True

    def test_macos_has_no_embedded_tray(self, monkeypatch):
        import sys

        from strakalari.flet_ui import app as app_mod

        # pystray's Cocoa loop on a side thread froze the macOS app: the
        # window process must never create the icon there.
        monkeypatch.delenv("STRAKALARI_NO_TRAY", raising=False)
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.setitem(sys.modules, "pystray", None)  # import would fail
        page, state, runner = _FakePage(), _FakeState(), _FakeRunner()
        assert app_mod.embedded_tray_supported() is False
        assert app_mod._setup_minimize_to_tray(page, state, runner) is None
        assert page.window.prevent_close is False
        page.on_close(None)
        assert runner.stops == 1

    def test_close_hides_and_quit_destroys(self, monkeypatch):
        import strakalari.flet_ui.app as app_mod

        monkeypatch.delenv("STRAKALARI_NO_TRAY", raising=False)
        # Also runs on the macOS CI runner, which has no embedded tray.
        monkeypatch.setattr(app_mod, "embedded_tray_supported", lambda: True)

        created = {}

        class FakeMenuItem:
            def __init__(self, *a, **k):
                self.callback = a[1] if len(a) > 1 else None

        class FakeMenu(list):
            def __init__(self, *items):
                super().__init__(items)

        class FakeIcon:
            def __init__(self, *a, **k):
                created["menu"] = a[3]
                self.stopped = False

            def run(self):
                created["ran"] = True

            def stop(self):
                self.stopped = True

        fake_pystray = types.SimpleNamespace(
            Menu=FakeMenu, MenuItem=FakeMenuItem, Icon=FakeIcon
        )
        monkeypatch.setitem(__import__("sys").modules, "pystray", fake_pystray)
        monkeypatch.setattr(app_mod, "_icon_image", lambda: object(), raising=False)

        import threading

        class FakeThread:
            def __init__(self, target=None, daemon=None):
                self._target = target

            def start(self):
                # Don't run the icon loop; just record it started.
                created["thread"] = True

        monkeypatch.setattr(threading, "Thread", FakeThread)

        # app module does "import pystray" inside the function — sys.modules
        # entry above is what it resolves to.
        page, state, runner = _FakePage(), _FakeState(), _FakeRunner()
        icon = app_mod._setup_minimize_to_tray(page, state, runner)
        assert icon is not None
        assert page.window.prevent_close is True
        assert callable(page.window.on_event)

        # X hides instead of quitting.
        page.window.on_event(_close_event_data())
        assert page.window.visible is False
        assert page.window.skip_task_bar is True
        assert runner.stops == 0

        # Tray Open restores via the page thread (raw pystray threads
        # lack Flet's page context, so a direct update() would no-op).
        open_item = created["menu"][0]
        page.window.minimized = True  # as after [-]-to-taskbar
        open_item.callback(icon)
        assert "_show_window" in page.threaded
        assert page.window.minimized is False
        assert page.window.visible is True
        assert page.window.skip_task_bar is False

        # Tray Quit is the real close: stops scheduler + destroys window.
        quit_item = created["menu"][2]
        quit_item.callback(icon)
        assert runner.stops >= 1
        assert icon.stopped is True
        assert page.window.destroyed is True

    def test_tray_child_gets_no_tray_env(self, monkeypatch):
        import subprocess

        import strakalari.flet_ui.tray as tray_mod

        captured = {}

        class FakeProc:
            def poll(self):
                return None

        def fake_popen(cmd, **kw):
            captured["env"] = kw.get("env", {})
            return FakeProc()

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.delenv("STRAKALARI_NO_TRAY", raising=False)
        app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        app._ui_process = None
        app.open_ui()
        assert captured["env"].get("STRAKALARI_NO_TRAY") == "1"
        # Purge the stray env so it can't leak into other tests.
        os.environ.pop("STRAKALARI_NO_TRAY", None)
