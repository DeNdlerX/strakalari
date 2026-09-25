"""Single instance: a second launch shows the first window, never duplicates."""

import socket
import threading

from strakalari.flet_ui.single_instance import (
    HOST,
    SingleInstance,
    ensure_single_primary,
)


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_for(event: threading.Event, timeout: float = 5.0) -> bool:
    return event.wait(timeout=timeout)


class TestSingleInstance:
    def test_first_acquire_wins(self):
        port = _free_port()
        first, second = SingleInstance(port), SingleInstance(port)
        try:
            assert first.acquire() is True
            assert first.is_primary is True
            assert second.acquire() is False
        finally:
            first.close()
            second.close()

    def test_show_fires_callback(self):
        port = _free_port()
        fired = threading.Event()
        primary = SingleInstance(port, on_show=fired.set)
        try:
            assert primary.acquire() is True
            assert SingleInstance(port).signal(kind="show") is True
            assert _wait_for(fired)
        finally:
            primary.close()

    def test_ping_acknowledges_without_firing(self):
        port = _free_port()
        fired = threading.Event()
        primary = SingleInstance(port, on_show=fired.set)
        try:
            assert primary.acquire() is True
            assert SingleInstance(port).signal(kind="ping") is True
            assert fired.wait(timeout=0.3) is False
        finally:
            primary.close()

    def test_signal_without_primary_fails(self):
        assert SingleInstance(_free_port()).signal(kind="show") is False

    def test_bad_kind_raises(self):
        try:
            SingleInstance(_free_port()).signal(kind="bogus")
        except ValueError:
            pass
        else:
            raise AssertionError("expected ValueError")

    def test_garbage_gets_no_reply_and_no_callback(self):
        port = _free_port()
        fired = threading.Event()
        primary = SingleInstance(port, on_show=fired.set)
        try:
            assert primary.acquire() is True
            with socket.create_connection((HOST, port), timeout=2) as conn:
                conn.settimeout(2)
                conn.sendall(b"not-strakalari\n")
                assert conn.recv(32) == b""
            assert fired.wait(timeout=0.3) is False
        finally:
            primary.close()

    def test_show_before_callback_is_delivered_late(self):
        # A show arriving between acquire() and UI-ready must not be lost
        # (main() attaches the callback after run() claims the port).
        port = _free_port()
        fired = threading.Event()
        primary = SingleInstance(port)
        try:
            assert primary.acquire() is True
            assert SingleInstance(port).signal(kind="show") is True
            primary.on_show = fired.set
            assert _wait_for(fired)
        finally:
            primary.close()

    def test_close_releases_port(self):
        port = _free_port()
        primary = SingleInstance(port)
        assert primary.acquire() is True
        primary.close()
        again = SingleInstance(port)
        try:
            assert again.acquire() is True
        finally:
            again.close()


class TestEnsureSinglePrimary:
    def test_secondary_show(self, capsys):
        port = _free_port()
        fired = threading.Event()
        status, guard = ensure_single_primary(port, mode="show")
        assert status == "primary"
        assert guard is not None
        try:
            guard.on_show = fired.set
            status2, guard2 = ensure_single_primary(port, mode="show")
            assert (status2, guard2) == ("secondary", None)
            assert _wait_for(fired)
        finally:
            guard.close()

    def test_secondary_ping_stays_silent(self):
        port = _free_port()
        fired = threading.Event()
        status, guard = ensure_single_primary(port, mode="show")
        assert status == "primary"
        try:
            guard.on_show = fired.set
            status2, guard2 = ensure_single_primary(port, mode="ping")
            assert (status2, guard2) == ("secondary", None)
            assert fired.wait(timeout=0.3) is False
        finally:
            guard.close()

    def test_squatted_port_still_starts(self, capsys):
        # An unrelated process on the port must not prevent startup.
        port = _free_port()
        squatter = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        squatter.bind((HOST, port))
        squatter.listen(1)
        try:
            status, guard = ensure_single_primary(port, mode="show", timeout=0.2)
            assert (status, guard) == ("solo", None)
            assert "Warning" in capsys.readouterr().out
        finally:
            squatter.close()

    def test_bad_mode_raises(self):
        try:
            ensure_single_primary(_free_port(), mode="bogus")
        except ValueError:
            pass
        else:
            raise AssertionError("expected ValueError")


class _FakeWindow:
    def __init__(self):
        self.minimized = True
        self.visible = False
        self.skip_task_bar = True
        self.focused = False
        self.fronted = False
        self.updated = 0

    def update(self):
        self.updated += 1

    def to_front(self):
        self.fronted = True


class _FakePage:
    def __init__(self):
        self.window = _FakeWindow()
        self.on_close = None
        self.updated = 0
        self.threaded = []

    def update(self):
        self.updated += 1

    def run_thread(self, fn, *args):
        self.threaded.append(getattr(fn, "__name__", "?"))
        fn(*args)


class TestShowWindow:
    def test_show_page_window_restores(self):
        from strakalari.flet_ui.app import _show_page_window

        page = _FakePage()
        _show_page_window(page)
        assert page.window.minimized is False
        assert page.window.visible is True
        assert page.window.skip_task_bar is False
        assert page.window.focused is True
        assert page.window.fronted is True
        assert page.updated >= 1

    def test_is_tray_child(self, monkeypatch):
        from strakalari.flet_ui.app import _is_tray_child

        monkeypatch.setenv("STRAKALARI_TRAY_CHILD", "1")
        assert _is_tray_child() is True
        monkeypatch.setenv("STRAKALARI_TRAY_CHILD", "0")
        assert _is_tray_child() is False
        monkeypatch.delenv("STRAKALARI_TRAY_CHILD", raising=False)
        assert _is_tray_child() is False


class TestTrayWiring:
    def test_open_ui_marks_tray_child(self, monkeypatch):
        import types

        import strakalari.flet_ui.tray as tray_mod

        seen = {}

        class FakePopen:
            def __init__(self, cmd, **kw):
                seen["env"] = kw.get("env")

            def poll(self):
                return None

        monkeypatch.setattr(
            tray_mod, "subprocess",
            types.SimpleNamespace(Popen=FakePopen, DEVNULL=None),
        )
        app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        app._ui_process = None
        app.open_ui()
        assert app._ui_process is not None
        assert seen["env"]["STRAKALARI_NO_TRAY"] == "1"
        assert seen["env"]["STRAKALARI_TRAY_CHILD"] == "1"

    def test_ensure_visible_spawns_when_child_dead(self, monkeypatch):
        import strakalari.flet_ui.tray as tray_mod

        app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        app._ui_process = None
        called = []
        monkeypatch.setattr(app, "open_ui", lambda: called.append(1))
        app._ensure_ui_visible()
        assert called == [1]

    def test_ensure_visible_forwards_to_live_child(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod
        import strakalari.flet_ui.tray as tray_mod

        port = _free_port()
        fired = threading.Event()
        listener = si_mod.SingleInstance(port, on_show=fired.set)
        assert listener.acquire() is True
        monkeypatch.setattr(si_mod, "UI_PORT", port)
        try:
            app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)

            class LiveProc:
                def poll(self):
                    return None

            app._ui_process = LiveProc()
            app._ensure_ui_visible()
            assert _wait_for(fired)
        finally:
            listener.close()


def test_only_playwright_browsers_count_as_ours(monkeypatch):
    from strakalari.flet_ui.single_instance import _is_playwright_browser

    monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
    ours = (r'"C:\Users\x\AppData\Local\ms-playwright\chromium-1\chrome.exe" '
            r'--headless --user-data-dir=C:\Temp\playwright_chromiumdev_profile-ab')
    other = r'"C:\Tools\puppeteer\chrome.exe" --headless --user-data-dir=C:\Temp\x'
    assert _is_playwright_browser(ours)
    assert not _is_playwright_browser(other)
