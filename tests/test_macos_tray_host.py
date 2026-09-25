"""macOS: the tray process hosts the window (Cocoa needs the main thread).

Regression: the window process ran pystray's NSApp loop on a side thread
and the app went "Not Responding" as soon as the window was shown. Now
every macOS launch runs the tray, which opens the window as a child,
closes it cleanly on Quit and follows it when close-to-tray is off.
"""

import socket
import sys
import threading

from strakalari.flet_ui.single_instance import HOST, SingleInstance


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


# -- routing ----------------------------------------------------------------------

def _patch_launch(monkeypatch, platform, argv=("strakalari",)):
    import strakalari.flet_ui.app as app_mod
    import strakalari.flet_ui.single_instance as si_mod
    import strakalari.flet_ui.tray as tray_mod

    calls = []
    monkeypatch.setattr(sys, "platform", platform)
    monkeypatch.setattr(sys, "argv", list(argv))
    monkeypatch.setattr(tray_mod, "run", lambda: calls.append("tray"))
    monkeypatch.setattr(app_mod.ft, "app", lambda *a, **k: calls.append("window"))
    monkeypatch.setattr(si_mod, "ensure_single_primary",
                        lambda *a, **k: ("solo", None))
    monkeypatch.setattr(si_mod, "kill_orphaned_flet_views", lambda: False)
    monkeypatch.setattr(si_mod, "kill_orphaned_headless_browsers", lambda: 0)
    return app_mod, calls


def test_macos_launch_runs_the_tray(monkeypatch):
    monkeypatch.delenv("STRAKALARI_TRAY_CHILD", raising=False)
    app_mod, calls = _patch_launch(monkeypatch, "darwin")
    app_mod.run()
    assert calls == ["tray"]


def test_macos_tray_child_opens_the_window(monkeypatch):
    monkeypatch.setenv("STRAKALARI_TRAY_CHILD", "1")
    app_mod, calls = _patch_launch(monkeypatch, "darwin")
    app_mod.run()
    assert calls == ["window"]


def test_windows_launch_opens_the_window(monkeypatch):
    monkeypatch.delenv("STRAKALARI_TRAY_CHILD", raising=False)
    app_mod, calls = _patch_launch(monkeypatch, "win32")
    app_mod.run()
    assert calls == ["window"]


def test_helpers_are_noops_off_macos(monkeypatch):
    from strakalari.flet_ui import macos

    monkeypatch.setattr(sys, "platform", "win32")
    assert macos.embedded_tray_supported() is True
    assert macos.tray_hosts_window() is False
    assert macos.install_reopen_handler(lambda: None) is None
    macos.use_accessory_policy()
    ran = []
    macos.call_on_main_thread(lambda: ran.append(1))
    assert ran == [1]


# -- quit signal --------------------------------------------------------------------

class TestQuitSignal:
    def test_quit_fires_handler(self):
        port = _free_port()
        fired = threading.Event()
        primary = SingleInstance(port, on_quit=fired.set)
        try:
            assert primary.acquire() is True
            assert SingleInstance(port).signal(kind="quit") is True
            assert fired.wait(timeout=5)
        finally:
            primary.close()

    def test_quit_without_handler_is_not_acknowledged(self):
        # The tray must know nobody closed the window, and kill instead.
        port = _free_port()
        shown = threading.Event()
        primary = SingleInstance(port, on_show=shown.set)
        try:
            assert primary.acquire() is True
            assert SingleInstance(port).signal(kind="quit") is False
            assert shown.wait(timeout=0.3) is False
        finally:
            primary.close()


class _FakeWindow:
    def __init__(self):
        self.prevent_close = True
        self.destroyed = False

    def destroy(self):
        self.destroyed = True


class _FakePage:
    def __init__(self):
        self.window = _FakeWindow()
        self.on_close = None

    def run_thread(self, fn, *args):
        fn(*args)


def test_tray_child_closes_its_window_on_quit(monkeypatch):
    import strakalari.flet_ui.app as app_mod
    import strakalari.flet_ui.single_instance as si_mod

    port = _free_port()
    monkeypatch.setattr(si_mod, "UI_PORT", port)
    monkeypatch.setenv("STRAKALARI_TRAY_CHILD", "1")
    page = _FakePage()
    try:
        app_mod._setup_single_instance(page)
        assert SingleInstance(port).signal(kind="quit") is True
        for _ in range(50):
            if page.window.destroyed:
                break
            threading.Event().wait(0.1)
        assert page.window.destroyed is True
        assert page.window.prevent_close is False
    finally:
        app_mod._release_instance_guards()


# -- tray host ------------------------------------------------------------------------

class _Proc:
    def __init__(self, alive=True):
        self.alive = alive
        self.waited = False

    def poll(self):
        return None if self.alive else 0

    def wait(self, timeout=None):
        self.waited = True
        self.alive = False
        return 0


class _Config:
    def __init__(self, close_to_tray):
        self._value = close_to_tray

    def __call__(self):
        return self

    def get(self, key, default=None):
        return self._value if key == "minimize_to_tray" else default


def _host(tray_mod, proc):
    app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
    app._ui_process = proc
    app._quitting = False
    app._host_mode = True
    return app


class TestFollowWindow:
    def _run(self, monkeypatch, close_to_tray, quitting=False, replaced=False):
        import strakalari.flet_ui.macos as macos_mod
        import strakalari.flet_ui.tray as tray_mod

        monkeypatch.setattr(tray_mod, "ConfigManager", _Config(close_to_tray))
        monkeypatch.setattr(macos_mod, "call_on_main_thread", lambda fn: fn())
        proc = _Proc()
        app = _host(tray_mod, _Proc() if replaced else proc)
        app._quitting = quitting
        quits = []
        monkeypatch.setattr(app, "quit", lambda *a: quits.append(1))
        app._follow_window(proc)
        return quits

    def test_closing_window_quits_when_close_to_tray_is_off(self, monkeypatch):
        assert self._run(monkeypatch, close_to_tray=False) == [1]

    def test_closing_window_keeps_tray_by_default(self, monkeypatch):
        assert self._run(monkeypatch, close_to_tray=True) == []

    def test_tray_quit_is_not_repeated(self, monkeypatch):
        assert self._run(monkeypatch, close_to_tray=False, quitting=True) == []

    def test_replaced_window_is_ignored(self, monkeypatch):
        assert self._run(monkeypatch, close_to_tray=False, replaced=True) == []

    def test_open_ui_follows_the_window_in_host_mode(self, monkeypatch):
        import types

        import strakalari.flet_ui.tray as tray_mod

        followed = threading.Event()
        monkeypatch.setattr(tray_mod, "subprocess",
                            types.SimpleNamespace(Popen=lambda *a, **k: _Proc(),
                                                  DEVNULL=None))
        monkeypatch.setattr(tray_mod.TrayApp, "_follow_window",
                            lambda self, proc: followed.set())
        app = _host(tray_mod, None)
        app.open_ui()
        assert followed.wait(timeout=5)


class TestMacQuit:
    def test_quit_closes_window_before_killing(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod
        import strakalari.flet_ui.tray as tray_mod

        order = []
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.setattr(tray_mod.TrayApp, "_close_ui_gracefully",
                            staticmethod(lambda proc: order.append("close")))
        monkeypatch.setattr(si_mod, "terminate_process_tree",
                            lambda proc, timeout=5.0: order.append("kill") or True)
        monkeypatch.setattr(si_mod, "kill_orphaned_flet_views", lambda: False)
        monkeypatch.setattr(tray_mod, "_primary_guard", None)
        app = _host(tray_mod, _Proc())
        app.runner = type("R", (), {"stop": lambda self: None})()
        app._icon = None
        app.quit()
        assert order == ["close", "kill"]
        assert app._quitting is True

    def test_graceful_close_waits_for_the_child(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod
        import strakalari.flet_ui.tray as tray_mod

        port = _free_port()
        monkeypatch.setattr(si_mod, "UI_PORT", port)
        asked = threading.Event()
        child = SingleInstance(port, on_quit=asked.set)
        assert child.acquire() is True
        proc = _Proc()
        try:
            tray_mod.TrayApp._close_ui_gracefully(proc)
        finally:
            child.close()
        assert asked.is_set()
        assert proc.waited is True

    def test_graceful_close_skips_a_dead_child(self):
        import strakalari.flet_ui.tray as tray_mod

        proc = _Proc(alive=False)
        tray_mod.TrayApp._close_ui_gracefully(proc)
        assert proc.waited is False
