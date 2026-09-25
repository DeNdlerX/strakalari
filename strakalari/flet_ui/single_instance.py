"""Cross-platform single-instance guard with "show window" signalling.

A second launch must not open a duplicate window: it wakes the running
instance over a localhost TCP socket and exits, and the running instance
restores its window (un-hide + un-minimize + focus).

Why TCP loopback instead of a lock file: a file can only *block* the
second process, it cannot tell the first one to show its window — and a
crashed process leaves a stale lock behind, while the OS always reclaims
a dead process's bound port. Loopback traffic needs no firewall exception
and behaves identically on Windows, Linux and macOS (stdlib only).
"""

from __future__ import annotations

import re
import socket
import sys
import threading
import time

HOST = "127.0.0.1"
# Source runs (run.bat / python main.py) use their own port pair: the
# installed build autostarts into the tray and holds the release ports,
# so sharing them would make every dev launch just show the installed
# app's window and exit.
_PORT_BASE = 48231 if getattr(sys, "frozen", False) else 48241
#: Port owned by the first main process (standalone UI or tray background).
MAIN_PORT = _PORT_BASE
#: Port owned by a Flet UI child spawned by the tray process, so the tray
#: parent can forward "show" requests to the process that owns the page.
UI_PORT = _PORT_BASE + 1

_MAGIC_SHOW = b"STRAKALARI-SHOW-v1\n"
_MAGIC_PING = b"STRAKALARI-PING-v1\n"  # acknowledged, but shows nothing
#: Tray -> its UI child: close the window cleanly. Acknowledged only when
#: an on_quit handler is set, so the sender knows to fall back to a kill.
_MAGIC_QUIT = b"STRAKALARI-QUIT-v1\n"
_REPLY_OK = b"STRAKALARI-OK-v1\n"

_IO_TIMEOUT_S = 2.0
_ACCEPT_TIMEOUT_S = 0.5
_SIGNAL_ATTEMPTS = 3
_SIGNAL_RETRY_PAUSE_S = 0.2


class SingleInstance:
    """Owns (primary) or probes (secondary) one loopback port.

    Primary: :meth:`acquire` binds the port and serves show requests on a
    daemon thread until :meth:`close`. Secondary: :meth:`signal` asks the
    primary to show itself (``kind="show"``), just checks it is alive
    (``kind="ping"``) or asks it to close its window (``kind="quit"``,
    served by ``on_quit``); a ``True`` return means the primary acknowledged,
    so the secondary should exit. The handshake rejects unrelated port
    squatters: they never send :data:`_REPLY_OK`, so :meth:`signal`
    returns ``False`` for them.
    """

    def __init__(self, port: int = MAIN_PORT, on_show=None, on_quit=None) -> None:
        self._port = port
        self._on_show = on_show
        self.on_quit = on_quit
        self._pending = 0
        self._guard = threading.Lock()
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self.is_primary = False

    @property
    def port(self) -> int:
        return self._port

    @property
    def bound_port(self) -> int | None:
        """Actually bound port (handy with ``port=0`` in tests)."""
        sock = self._sock
        if sock is None:
            return None
        try:
            return int(sock.getsockname()[1])
        except OSError:
            return None

    @property
    def on_show(self):
        return self._on_show

    @on_show.setter
    def on_show(self, fn) -> None:
        fire = False
        with self._guard:
            self._on_show = fn
            if fn is not None and self._pending:
                self._pending = 0
                fire = True
        if fire:
            # A show arrived before the UI was ready to receive it (a
            # fresh window is already visible, so firing now is harmless).
            try:
                fn()
            except Exception:
                pass

    def acquire(self) -> bool:
        """Binds the port and starts the listener. True when primary."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            # Linux/macOS: allow quick rebinding over TIME_WAIT leftovers
            # from earlier signal connections. Windows: SO_REUSEADDR would
            # let a *second* process bind the same port, defeating the
            # guard — request exclusive use instead.
            if sys.platform == "win32":
                exclusive = getattr(socket, "SO_EXCLUSIVEADDRUSE", None)
                if exclusive is not None:
                    try:
                        sock.setsockopt(socket.SOL_SOCKET, exclusive, 1)
                    except OSError:
                        pass
            else:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((HOST, self._port))
            sock.listen(4)
            sock.settimeout(_ACCEPT_TIMEOUT_S)
        except OSError:
            try:
                sock.close()
            except OSError:
                pass
            self.is_primary = False
            return False
        self._sock = sock
        self.is_primary = True
        self._thread = threading.Thread(
            target=self._serve,
            daemon=True,
            name=f"strakalari-single-{self._port}",
        )
        self._thread.start()
        return True

    def signal(self, kind: str = "show", timeout: float = _IO_TIMEOUT_S) -> bool:
        """Asks the primary to show itself. True when it acknowledged."""
        if kind == "show":
            magic = _MAGIC_SHOW
        elif kind == "ping":
            magic = _MAGIC_PING
        elif kind == "quit":
            magic = _MAGIC_QUIT
        else:
            raise ValueError(f"unknown signal kind: {kind!r}")
        try:
            with socket.create_connection((HOST, self._port), timeout=timeout) as conn:
                conn.settimeout(timeout)
                conn.sendall(magic)
                data = b""
                while len(data) < len(_REPLY_OK):
                    chunk = conn.recv(len(_REPLY_OK) - len(data))
                    if not chunk:
                        break
                    data += chunk
                return data == _REPLY_OK
        except OSError:
            return False

    def close(self) -> None:
        """Stops the listener and frees the port. Safe to call anytime."""
        self._stop.set()
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
        self.is_primary = False

    # -- internals ------------------------------------------------------

    def _serve(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                conn, _addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                self._handle(conn)
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(_IO_TIMEOUT_S)
            data = b""
            # Both magic lines end with \n; read one line at most.
            while len(data) < 64 and not data.endswith(b"\n"):
                chunk = conn.recv(64 - len(data))
                if not chunk:
                    break
                data += chunk
            if data not in (_MAGIC_SHOW, _MAGIC_PING, _MAGIC_QUIT):
                return  # unrelated prober or version mismatch: stay silent
            on_quit = self.on_quit
            if data == _MAGIC_QUIT and on_quit is None:
                return  # nothing here can close the window: sender kills instead
            conn.sendall(_REPLY_OK)
        except OSError:
            return
        if data == _MAGIC_PING:
            return
        if data == _MAGIC_QUIT:
            try:
                on_quit()
            except Exception:
                pass
            return
        fire = False
        with self._guard:
            if self._on_show is not None:
                fire = True
            else:
                self._pending += 1
        if fire:
            try:
                self._on_show()
            except Exception:
                pass


def ensure_single_primary(
    port: int = MAIN_PORT,
    mode: str = "show",
    timeout: float = _IO_TIMEOUT_S,
) -> tuple[str, SingleInstance | None]:
    """Tries to become the primary instance on ``port``.

    ``mode="show"`` (normal launch) tells a live primary to restore its
    window; ``mode="ping"`` (--minimized launch) only checks one is alive
    so autostart never pops a window. Returns ``("primary", guard)`` (the
    caller must hold the guard for the process lifetime), ``("secondary",
    None)`` (a live instance acknowledged — exit), or ``("solo", None)``
    (the port is squatted by a non-Strakalari process — proceed without
    protection rather than refusing to start). Only a bad ``mode`` raises.
    """
    if mode not in ("show", "ping"):
        raise ValueError(f"unknown mode: {mode!r}")
    guard = SingleInstance(port)
    if guard.acquire():
        return ("primary", guard)
    if mode == "show":
        print("Strakaláři is already running; showing the open window.")
    probe = SingleInstance(port)
    signalled = False
    for _ in range(_SIGNAL_ATTEMPTS):
        if probe.signal(kind=mode, timeout=timeout):
            signalled = True
            break
        time.sleep(_SIGNAL_RETRY_PAUSE_S)
    if signalled:
        return ("secondary", None)
    # Nobody answered: the previous owner is dying, or an unrelated
    # process squats the port (handshake mismatch). Retry once in case
    # the port just freed up.
    retry = SingleInstance(port)
    if retry.acquire():
        return ("primary", retry)
    print(
        f"Warning: single-instance port {port} is held by an unknown "
        "process; continuing without duplicate protection."
    )
    return ("solo", None)


def terminate_process_tree(proc, timeout: float = 5.0) -> bool:
    """Stops a spawned UI child including its own subprocesses.

    The Flet window runs as a grandchild of the UI child process, so a
    plain ``terminate()`` would orphan it (and any in-flight browser
    workers). On Windows ``taskkill /T`` takes the whole tree while the
    parent is still alive; elsewhere terminate/kill plus a reaping wait
    is all there is. Returns True when the process is gone. Never raises.
    """
    import subprocess

    try:
        if proc.poll() is not None:
            return True
    except Exception:
        return False
    if sys.platform == "win32":
        try:
            subprocess.run(
                ["taskkill.exe", "/PID", str(proc.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except Exception:
            pass
    try:
        if proc.poll() is None:
            proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=timeout)
        return True
    except Exception:
        pass
    try:
        proc.kill()
    except Exception:
        return False
    try:
        proc.wait(timeout=timeout)
    except Exception:
        pass
    try:
        return proc.poll() is not None
    except Exception:
        return False


def _list_processes_win32() -> list:
    """Snapshot of live processes as ``(pid, ppid, exe_basename)``.

    stdlib-only (PowerShell CIM query, an OS component that is always
    present on Windows 10/11): no new dependencies, no console flash
    (``CREATE_NO_WINDOW``). Returns [] on any failure — callers treat
    that as \"unknown, sweep nothing\" rather than guessing.
    """
    import csv
    import subprocess

    try:
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-Command",
             "Get-CimInstance Win32_Process"
             " | Select-Object ProcessId, ParentProcessId, Name"
             " | ConvertTo-Csv -NoTypeInformation"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            text=True,
        )
    except Exception:
        return []
    try:
        if completed.returncode != 0 or not completed.stdout:
            return []
        procs: list = []
        for row in csv.DictReader(completed.stdout.splitlines()):
            try:
                procs.append((
                    int(row["ProcessId"]),
                    int(row["ParentProcessId"]),
                    str(row["Name"] or ""),
                ))
            except (KeyError, TypeError, ValueError):
                continue
        return procs
    except Exception:
        return []


def _list_processes_with_cmdline_win32() -> list:
    """Snapshot of live processes as ``(pid, ppid, exe_basename, cmdline)``.

    Same stdlib-only PowerShell CIM mechanism as
    :func:`_list_processes_win32`, plus the command line (needed to tell
    our headless Chromium orphans apart from the user's own browser).
    Returns [] on any failure — callers sweep nothing rather than
    guessing.
    """
    import csv
    import subprocess

    try:
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-Command",
             "Get-CimInstance Win32_Process"
             " | Select-Object ProcessId, ParentProcessId, Name, CommandLine"
             " | ConvertTo-Csv -NoTypeInformation"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            text=True,
        )
    except Exception:
        return []
    try:
        if completed.returncode != 0 or not completed.stdout:
            return []
        procs: list = []
        for row in csv.DictReader(completed.stdout.splitlines()):
            try:
                procs.append((
                    int(row["ProcessId"]),
                    int(row["ParentProcessId"]),
                    str(row["Name"] or ""),
                    str(row["CommandLine"] or ""),
                ))
            except (KeyError, TypeError, ValueError):
                continue
        return procs
    except Exception:
        return []


_CHROME_EXE_NAMES = frozenset({
    "chrome.exe", "chromium.exe", "headless_shell.exe",
})


def _is_playwright_browser(cmdline: str | None) -> bool:
    """True when a browser command line belongs to a Playwright launch."""
    import os

    low = str(cmdline or "").lower()
    markers = ["playwright_chromiumdev_profile", "ms-playwright"]
    custom = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "").strip()
    if custom and custom != "0":
        markers.append(os.path.normcase(os.path.normpath(custom)).lower())
    return any(m in low for m in markers)


def kill_orphaned_headless_browsers() -> int:
    """Kills headless Chromium processes whose parent process is dead.

    Playwright browsers are closed gracefully on a clean exit — but a
    killed or crashed app (Task Manager End Task, crash, power loss)
    never runs teardown, leaving headless ``chrome.exe`` trees behind
    that accumulate across restarts (38 observed after one incident).
    Only processes whose parent PID is absent from the live snapshot,
    that are headless, AND that carry a Playwright marker (its temp
    profile dir or the ms-playwright / bundled browsers location) are
    touched — so neither the user's own Chrome nor another tool's
    headless browser is ever killed. Returns the number of processes
    signalled. Never raises.
    """
    import subprocess

    if sys.platform != "win32":
        return 0
    try:
        procs = _list_processes_with_cmdline_win32()
    except Exception:
        return 0
    if not procs:
        return 0
    live = {pid for pid, _, _, _ in procs}
    orphans = sorted({
        pid for pid, ppid, exe, cmd in procs
        if ppid not in live
        and exe.lower() in _CHROME_EXE_NAMES
        and ("--headless" in (cmd or "").lower()
             or exe.lower() == "headless_shell.exe")
        and _is_playwright_browser(cmd)
    })
    if not orphans:
        return 0
    killed = 0
    for pid in orphans:
        try:
            completed = subprocess.run(
                ["taskkill.exe", "/F", "/T", "/PID", str(pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if completed.returncode == 0:
                killed += 1
        except Exception:
            continue
    return killed


#: Files only Strakaláři's assets dir holds (the Flet client gets that dir
#: as its last argument): tells our windows apart from other Flet apps'.
_OUR_ASSET_MARKERS = ("tray-icon.svg", "tray-icon.png")


def _is_our_flet_view(cmdline: str | None) -> bool:
    """True when a ``flet.exe`` command line belongs to a Strakaláři window.

    Flet starts its client as ``flet.exe <page url> <pid file> <assets
    dir>``. Ours passes our assets dir: a path naming the app, the assets
    dir of this build, or a dir holding our tray icon. Anything we cannot
    attribute (another vendor's app, a deleted temp dir) is left alone.
    """
    import os

    text = str(cmdline or "")
    low = text.lower()
    if "strakalari" in low or "strakaláři" in low:
        return True
    try:
        from .assets import assets_dir

        mine = os.path.normcase(os.path.normpath(str(assets_dir())))
        if mine and mine in os.path.normcase(text):
            return True
    except Exception:
        pass
    for token in re.findall(r'"([^"]+)"|(\S+)', text):
        path = (token[0] or token[1]).strip()
        try:
            if path and os.path.isdir(path) and all(
                    os.path.isfile(os.path.join(path, m)) for m in _OUR_ASSET_MARKERS):
                return True
        except (OSError, ValueError):
            continue
    return False


def kill_orphaned_flet_views() -> bool:
    """Kills Strakaláři's ``flet.exe`` windows whose parent process is dead.

    The Flet window client (Task Manager description \"Flet description\")
    is a child of our Python process. Any kill that takes the parent
    without its tree (plain ``taskkill /IM`` without ``/T``, Details-tab
    End Task, crash) leaves the window behind with no server — a dead
    ghost the user can only remove by hand. Only orphans (parent PID
    absent from the live snapshot) that are provably ours (see
    :func:`_is_our_flet_view`) are touched, so neither a live window nor
    another Flet app's window is ever killed. Never raises; True when at
    least one orphan was reaped.
    """
    import subprocess

    if sys.platform != "win32":
        return False
    try:
        procs = _list_processes_with_cmdline_win32()
    except Exception:
        return False
    if not procs:
        return False
    live = {pid for pid, _, _, _ in procs}
    orphans = sorted({
        pid for pid, ppid, exe, cmd in procs
        if exe.lower() == "flet.exe" and ppid not in live and _is_our_flet_view(cmd)
    })
    if not orphans:
        return False
    killed = False
    for pid in orphans:
        try:
            completed = subprocess.run(
                ["taskkill.exe", "/F", "/T", "/PID", str(pid)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if completed.returncode == 0:
                killed = True
        except Exception:
            continue
    return killed
