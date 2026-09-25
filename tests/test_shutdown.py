"""Shutdown paths must leave no processes behind.

Covers the two related reports: tray Quit leaving Strakalari processes
running, and the installer failing with "unable to close applications".

* ``_invoke_window``: Flet made ``window.destroy``/``close``/``to_front``
  coroutines — a bare call silently no-ops, so Quit stopped the tray icon
  while the window and its process stayed alive.
* ``terminate_process_tree`` / ``kill_orphaned_flet_views``: the UI child is a
  whole tree (Flet window grandchild, browser workers); the tracked child is
  taken down by PID at quit, and detached flet.exe ghosts (dead parent) are
  reaped by image name. Same-image sweeps are forbidden: a PyInstaller
  onefile app is two same-named processes (bootloader parent + payload
  child), so taskkill /IM <own-name> from the child matches the parent and
  /T kills the child itself (instant silent exit 1 at startup).
"""

import asyncio
import subprocess
import sys
import threading
from pathlib import Path


# -- _invoke_window ----------------------------------------------------------

class _SyncWindow:
    def __init__(self):
        self.destroyed = False
        self.fronted = False

    def destroy(self):
        self.destroyed = True

    def to_front(self):
        self.fronted = True


class _SyncPage:
    def __init__(self):
        self.window = _SyncWindow()


class _AsyncWindow:
    def __init__(self):
        self.destroyed = False
        self.closed = False

    async def destroy(self):
        self.destroyed = True

    async def close(self):
        self.closed = True


class _AsyncPage:
    def __init__(self, loop):
        self.window = _AsyncWindow()
        self._loop = loop

    @property
    def loop(self):
        return self._loop


def _pump_loop():
    """Runs a fresh event loop on a daemon thread; returns (loop, stop)."""
    loop = asyncio.new_event_loop()
    ready = threading.Event()

    def _run():
        asyncio.set_event_loop(loop)
        ready.set()
        loop.run_forever()

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()
    assert ready.wait(timeout=5)

    def _stop():
        loop.call_soon_threadsafe(loop.stop)
        thread.join(timeout=5)

    return loop, _stop


def _wait_for(predicate, timeout=5.0):
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class TestInvokeWindow:
    def test_sync_method_called_directly(self):
        from strakalari.flet_ui.app import _invoke_window

        page = _SyncPage()
        assert _invoke_window(page, "destroy") is True
        assert page.window.destroyed is True
        assert _invoke_window(page, "to_front") is True
        assert page.window.fronted is True

    def test_async_method_driven_on_page_loop(self):
        from strakalari.flet_ui.app import _invoke_window

        loop, stop = _pump_loop()
        try:
            page = _AsyncPage(loop)
            assert _invoke_window(page, "destroy") is True
            assert _wait_for(lambda: page.window.destroyed) is True
        finally:
            stop()

    def test_missing_or_broken_method_is_false(self):
        from strakalari.flet_ui.app import _invoke_window

        assert _invoke_window(_SyncPage(), "nope") is False

        class _Broken:
            window = None

        assert _invoke_window(_Broken(), "destroy") is False

    def test_async_without_loop_is_false(self):
        from strakalari.flet_ui.app import _invoke_window

        class _NoLoop:
            window = _AsyncWindow()

        assert _invoke_window(_NoLoop(), "destroy") is False


# -- terminate_process_tree / no same-image sweep ------------------------------

class _FakeProc:
    """Popen stand-in: dies on terminate() unless told otherwise."""

    def __init__(self, pid=4242, exit_after_terminate=True):
        self.pid = pid
        self.calls: list = []
        self._alive = True
        self._exit_after_terminate = exit_after_terminate

    def poll(self):
        self.calls.append("poll")
        return None if self._alive else 0

    def terminate(self):
        self.calls.append("terminate")
        if self._exit_after_terminate:
            self._alive = False

    def kill(self):
        self.calls.append("kill")
        self._alive = False

    def wait(self, timeout=None):
        self.calls.append("wait")
        if self._alive:
            raise subprocess.TimeoutExpired(self.pid, timeout)
        return 0


class _Completed:
    def __init__(self, returncode=0):
        self.returncode = returncode


def _set_platform(monkeypatch, name):
    monkeypatch.setattr(sys, "platform", name)


def _set_frozen(monkeypatch, frozen, exe="C:\\app\\Strakalari.exe"):
    if frozen:
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setattr(sys, "executable", exe, raising=False)
    else:
        monkeypatch.delattr(sys, "frozen", raising=False)


class TestTerminateProcessTree:
    def test_dead_proc_is_noop(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        ran = []
        monkeypatch.setattr(
            subprocess, "run",
            lambda *a, **k: ran.append(a) or _Completed(0),
        )
        proc = _FakeProc()
        proc._alive = False
        assert si_mod.terminate_process_tree(proc) is True
        assert ran == []
        assert "terminate" not in proc.calls

    def test_win32_tree_kills_first(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "win32")
        ran = []

        def fake_run(cmd, **kw):
            ran.append(cmd)
            return _Completed(0)

        monkeypatch.setattr(subprocess, "run", fake_run)
        proc = _FakeProc(pid=777)
        assert si_mod.terminate_process_tree(proc) is True
        assert ran and ran[0][:4] == ["taskkill.exe", "/PID", "777", "/T"]
        assert "/F" in ran[0]

    def test_posix_skips_taskkill(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "linux")

        def boom(*a, **k):
            raise AssertionError("taskkill must not run off Windows")

        monkeypatch.setattr(subprocess, "run", boom)
        proc = _FakeProc()
        assert si_mod.terminate_process_tree(proc) is True
        assert "terminate" in proc.calls

    def test_stubborn_proc_gets_killed_and_reaped(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "linux")
        monkeypatch.setattr(
            subprocess, "run",
            lambda *a, **k: (_ for _ in ()).throw(AssertionError("no taskkill")),
        )
        proc = _FakeProc(exit_after_terminate=False)
        assert si_mod.terminate_process_tree(proc) is True
        assert "terminate" in proc.calls
        assert "kill" in proc.calls
        assert proc.calls.count("wait") >= 2


class TestNoSameImageSweep:
    """Regression pin: a same-image sweep must never come back.

    A PyInstaller onefile app is two same-named processes (bootloader
    parent + payload child). taskkill /F /T /IM <own-name> issued from the
    child matches the parent, and /T takes the child down with it — the
    frozen app died ~2s after launch with a silent exit 1. Stale peers are
    stopped by the installer (a different process name); the app only ever
    targets PIDs it holds (terminate_process_tree) or a different image
    name whose parent is dead (kill_orphaned_flet_views).
    """

    def test_sweep_helper_is_gone(self):
        import strakalari.flet_ui.single_instance as si_mod

        assert not hasattr(si_mod, "kill_stray_instances")
        assert not hasattr(si_mod, "_frozen_exe_basename")

    def test_startup_and_quit_paths_never_sweep(self):
        import inspect

        import strakalari.flet_ui.app as app_mod
        import strakalari.flet_ui.tray as tray_mod

        for mod in (app_mod, tray_mod):
            assert "kill_stray_instances" not in inspect.getsource(mod)


# -- ensure_stdio ---------------------------------------------------------------

class TestEnsureStdio:
    """Windowed frozen apps start with sys.stdout/stderr None; uvicorn's
    logging calls .isatty() during server bootstrap and the app never
    listens. The guard must replace missing/broken streams and keep good
    ones (including pytest's capture objects)."""

    def test_none_streams_point_at_devnull(self, monkeypatch):
        import sys

        from strakalari.flet_ui.startup import ensure_stdio

        monkeypatch.setattr(sys, "stdout", None, raising=False)
        monkeypatch.setattr(sys, "stderr", None, raising=False)
        ensure_stdio()
        for stream in (sys.stdout, sys.stderr):
            # Whatever isatty() reports (Windows NUL claims True), the
            # uvicorn logging access pattern must work without raising.
            assert stream is not None
            stream.isatty()
            stream.write("swallowed\n")

    def test_windowed_warnings_land_in_console_log(self, monkeypatch):
        import sys

        from strakalari.core.helpers import _resolve_path
        from strakalari.flet_ui.startup import CONSOLE_LOG, ensure_stdio

        monkeypatch.setattr(sys, "stdout", None, raising=False)
        monkeypatch.setattr(sys, "stderr", None, raising=False)
        ensure_stdio()
        print("Warning: visible now")
        sys.stderr.write("Traceback: also here\n")
        with open(_resolve_path(CONSOLE_LOG), encoding="utf-8") as f:
            text = f.read()
        assert "Warning: visible now" in text and "Traceback: also here" in text
        sys.stdout.close()

    def test_broken_stream_replaced(self, monkeypatch):
        import sys

        from strakalari.flet_ui.startup import ensure_stdio

        monkeypatch.setattr(sys, "stdout", object(), raising=False)
        ensure_stdio()
        assert hasattr(sys.stdout, "write")
        sys.stdout.isatty()
        sys.stdout.write("swallowed\n")

    def test_healthy_streams_kept(self, monkeypatch):
        import io
        import sys

        from strakalari.flet_ui.startup import ensure_stdio

        out, err = io.StringIO(), io.StringIO()
        monkeypatch.setattr(sys, "stdout", out, raising=False)
        monkeypatch.setattr(sys, "stderr", err, raising=False)
        ensure_stdio()
        assert sys.stdout is out
        assert sys.stderr is err


# -- kill_orphaned_flet_views -------------------------------------------------

_OUR = r'"C:\flet\flet.exe" http://127.0.0.1:1 C:\Temp\pid "C:\Programs\Strakalari\assets"'
_OTHER = r'"C:\flet\flet.exe" http://127.0.0.1:2 C:\Temp\pid "C:\Other\assets"'

SNAP_MIXED = [
    (100, 1, "Strakalari.exe", ""),   # live parent
    (200, 100, "flet.exe", _OUR),     # live window (parent alive) — must survive
    (300, 9999, "flet.exe", _OUR),    # our orphan (parent gone) — must die
    (301, 9999, "FLET.EXE", _OUR),    # our orphan, case variant — must die
    (302, 9999, "flet.exe", _OTHER),  # another Flet app's orphan — must survive
    (400, 1, "notepad.exe", ""),      # unrelated — must survive
]


class TestKillOrphanedFletViews:
    def test_kills_only_our_dead_parent_flet(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "win32")
        monkeypatch.setattr(si_mod, "_list_processes_with_cmdline_win32", lambda: list(SNAP_MIXED))
        ran = []
        monkeypatch.setattr(
            subprocess, "run",
            lambda cmd, **kw: ran.append(cmd) or _Completed(0),
        )
        assert si_mod.kill_orphaned_flet_views() is True
        pids = sorted(cmd[cmd.index("/PID") + 1] for cmd in ran)
        assert pids == ["300", "301"]
        for cmd in ran:
            assert cmd[:4] == ["taskkill.exe", "/F", "/T", "/PID"]

    def test_no_orphans_no_kill(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "win32")
        snap = [(100, 1, "Strakalari.exe", ""), (200, 100, "flet.exe", _OUR)]
        monkeypatch.setattr(si_mod, "_list_processes_with_cmdline_win32", lambda: snap)

        def boom(*a, **k):
            raise AssertionError("nothing to kill, taskkill must not run")

        monkeypatch.setattr(subprocess, "run", boom)
        assert si_mod.kill_orphaned_flet_views() is False

    def test_empty_snapshot_kills_nothing(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "win32")
        monkeypatch.setattr(si_mod, "_list_processes_with_cmdline_win32", lambda: [])

        def boom(*a, **k):
            raise AssertionError("unknown state, must sweep nothing")

        monkeypatch.setattr(subprocess, "run", boom)
        assert si_mod.kill_orphaned_flet_views() is False

    def test_off_windows_never_sweeps(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "linux")

        def boom(*a, **k):
            raise AssertionError("sweep must not run off Windows")

        monkeypatch.setattr(subprocess, "run", boom)
        assert si_mod.kill_orphaned_flet_views() is False

    def test_failed_kill_is_false(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod

        _set_platform(monkeypatch, "win32")
        monkeypatch.setattr(si_mod, "_list_processes_with_cmdline_win32", lambda: list(SNAP_MIXED))
        monkeypatch.setattr(
            subprocess, "run", lambda *a, **k: _Completed(128)
        )
        assert si_mod.kill_orphaned_flet_views() is False


# -- TrayApp.quit --------------------------------------------------------------

class _FakeRunner:
    def __init__(self):
        self.stops = 0

    def stop(self):
        self.stops += 1


class _FakeIcon:
    def __init__(self):
        self.stopped = False

    def stop(self):
        self.stopped = True


class _FakeGuard:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class TestTrayQuit:
    def _make_app(self, tray_mod, proc):
        app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        app.runner = _FakeRunner()
        app._ui_process = proc
        app._icon = _FakeIcon()
        return app

    def test_quit_kills_tree_reaps_orphans_and_releases(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod
        import strakalari.flet_ui.tray as tray_mod

        seen = {}

        def fake_tree(proc, timeout=5.0):
            seen["tree"] = proc
            return True

        def fake_reap():
            seen["orphans"] = True
            return True

        monkeypatch.setattr(si_mod, "terminate_process_tree", fake_tree)
        monkeypatch.setattr(si_mod, "kill_orphaned_flet_views", fake_reap)
        guard = _FakeGuard()
        monkeypatch.setattr(tray_mod, "_primary_guard", guard)
        proc = _FakeProc()
        app = self._make_app(tray_mod, proc)

        app.quit("icon", "item")  # pystray calls actions as (icon, item)

        assert app.runner.stops == 1
        assert seen.get("tree") is proc
        assert seen.get("orphans") is True
        assert app._ui_process is None
        assert app._icon.stopped is True
        assert guard.closed is True
        assert tray_mod._primary_guard is None

    def test_quit_without_child_still_cleans_up(self, monkeypatch):
        import strakalari.flet_ui.single_instance as si_mod
        import strakalari.flet_ui.tray as tray_mod

        seen = {}
        monkeypatch.setattr(
            si_mod, "terminate_process_tree",
            lambda proc, timeout=5.0: seen.setdefault("tree", True) or True,
        )
        monkeypatch.setattr(
            si_mod, "kill_orphaned_flet_views",
            lambda: seen.setdefault("orphans", True) or True,
        )
        monkeypatch.setattr(tray_mod, "_primary_guard", None)
        app = self._make_app(tray_mod, None)

        app.quit()

        assert "tree" not in seen
        assert seen.get("orphans") is True
        assert app._icon.stopped is True

    def test_menu_handlers_take_icon_and_item(self, monkeypatch):
        import strakalari.flet_ui.tray as tray_mod

        app = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        app._ui_process = None

        opened = {}
        monkeypatch.setattr(
            tray_mod.TrayApp, "open_ui",
            lambda self, icon=None, item=None: opened.setdefault("ui", True),
        )
        refreshed = {}
        monkeypatch.setattr(
            tray_mod.TrayApp, "refresh_now",
            lambda self, icon=None, item=None: refreshed.setdefault("r", True),
        )
        app.open_ui("icon", "item")
        app.refresh_now("icon", "item")
        assert opened and refreshed


# -- installer ------------------------------------------------------------------

def test_installer_shuts_down_app_before_install():
    iss = (Path(__file__).parent.parent / "installer.iss").read_text(
        encoding="utf-8"
    )
    assert "function PrepareToInstall" in iss
    # /T takes the whole tree so the window client dies with its parent
    # instead of lingering.
    assert "/F /T /IM Strakalari.exe" in iss
    # No generic flet.exe sweep on purpose — that image name also matches
    # other vendors' Flet apps; only our own Strakalari.exe tree is stopped
    # (both install and uninstall paths).
    assert "/IM flet.exe" not in iss
