"""System-tray runner: icon, periodic jobs, notifications, UI launcher.

Runs in the tray (hidden, as requested). The Flet window is a subprocess
launched from the tray menu, so closing the window never kills background
automation. The scheduler keeps refreshing on ``check_interval_minutes``.

Used for --minimized (autostart) everywhere, and for every launch on
macOS, where only this process can host the icon (see macos.py).
"""

from __future__ import annotations

import subprocess
import sys
import threading
from datetime import date

from strakalari.core import notify as notify_core
from strakalari.core.config import ConfigManager
from strakalari.core.scheduler import JobResult, PeriodicRunner

#: Single-instance guard, held for the whole process lifetime (dropping
#: the last reference closes the listener socket and would let a
#: duplicate tray start).
_primary_guard = None


def _icon_image():
    # Prefer the bundled high-contrast tray glyph — the full-color logo
    # turns to mud at 16x16 and vanishes on a light taskbar. The drawn
    # "S" below is only a last-resort fallback (e.g. assets missing).
    try:
        from .assets import tray_icon_path

        path = tray_icon_path()
        if path:
            from PIL import Image

            img = Image.open(path)
            if img.mode != "RGBA":
                img = img.convert("RGBA")
            return img.resize((64, 64))
    except Exception:
        pass
    try:
        from PIL import Image, ImageDraw

        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw.rounded_rectangle([8, 8, 56, 56], radius=14, fill=(122, 165, 248, 255))
        draw.text((22, 16), "S", fill=(15, 17, 21, 255))
        return img
    except Exception:
        return None


def _apply_language(config_data: dict | None) -> None:
    """Uses the configured UI language in this process (menu, toasts, errors).

    The window process sets it in AppState; the tray is a separate
    process and would otherwise always speak Czech. Never raises.
    """
    try:
        from strakalari.core.i18n import set_language

        set_language(str((config_data or {}).get("language", "cs") or "cs"))
    except Exception:
        pass


class TrayApp:
    def __init__(self) -> None:
        self.config = ConfigManager()
        _apply_language(self.config.data)
        self.runner = PeriodicRunner(
            interval_minutes=float(self.config.get("check_interval_minutes", 60) or 60),
            on_result=self._on_result,
            # Anchor the first auto-run to the last successful refresh; with
            # no or an overdue cache (None) the tray refreshes on start.
            last_run=self._startup_seed(),
            # Settings are edited in the window (another process): follow
            # the saved interval instead of the one read at tray start.
            interval_provider=self._configured_interval,
        )
        self._config_mtime: float | None = self._config_file_mtime()
        self.runner.add_job("refresh", self._job_refresh)
        self._ui_process: subprocess.Popen | None = None
        self._icon = None
        #: This tray was started by a normal launch to host the window
        #: (macOS): the window's lifetime is the app's, see _follow_window.
        self._host_mode = False
        self._quitting = False
        self._reopen_delegate = None
        # Re-entrancy guard: the scheduler tick and manual/tray-click
        # refresh_now() can overlap (each spawns its own browser), so a
        # second refresh while one runs must skip instead of piling up.
        self._refresh_guard = threading.Lock()

    # -- jobs ------------------------------------------------------------
    @staticmethod
    def _startup_seed():
        """Last successful refresh time from disk (None = unknown).

        Never raises: without positive evidence of fresh data the tray
        keeps its old refresh-on-start behavior.
        """
        try:
            from strakalari.core.cache import load_data_cache, startup_seed

            return startup_seed(load_data_cache())
        except Exception:
            return None

    def _config_file_mtime(self) -> float | None:
        import os

        try:
            return os.path.getmtime(self.config.config_path)
        except (OSError, AttributeError):
            return None

    def _configured_interval(self) -> float | None:
        """Saved ``check_interval_minutes``, re-read only when config.json
        changed on disk. None = keep the current interval."""
        mtime = self._config_file_mtime()
        if mtime is None or mtime == getattr(self, "_config_mtime", None):
            return None
        self._config_mtime = mtime
        try:
            return float(ConfigManager().get("check_interval_minutes", 60) or 60)
        except (TypeError, ValueError):
            return None

    def _prefs(self) -> dict:
        try:
            prefs = ConfigManager().get("notifications", {})
            return prefs if isinstance(prefs, dict) else {}
        except Exception:
            return {}

    def _job_refresh(self) -> str:
        # One refresh at a time per tray process: overlapping runs each
        # open their own headless browser and fight over the cache.
        # getattr-guarded: tests may invoke the job on an uninitialized
        # instance, which simply runs unguarded like before.
        guard = getattr(self, "_refresh_guard", None)
        if guard is not None and not guard.acquire(blocking=False):
            return "skipped (a refresh is already running)"
        try:
            from strakalari.core.refresh import session_lock

            # The window is a separate process with its own refresh and
            # order buttons: skip while it holds the session.
            with session_lock() as held:
                if not held:
                    return "skipped (the window is refreshing or sending)"
                return self._job_refresh_inner()
        finally:
            if guard is not None:
                guard.release()

    def _job_refresh_inner(self) -> str:
        from strakalari.core.automation import Strakalari
        from strakalari.core.config import ConfigManager, has_valid_credentials
        from strakalari.core.refresh import run_refresh

        from .strings import S

        manager = ConfigManager()
        # The language may have been switched in the window since start.
        _apply_language(manager.data)
        if not any(has_valid_credentials(manager.data)):
            return "skipped (no credentials configured)"
        app = Strakalari(on_log=lambda m: None, start_browser=True)
        try:
            result = run_refresh(app, manager.data, scope="all")
        finally:
            try:
                app.close()
            except Exception:
                pass
        if result.used_gemini:
            manager.set_and_save("gemini_last_run", date.today().isoformat())
        prefs = self._prefs()
        if result.excuses_sent:
            notify_core.notify("excuse_sent", S("excuses_auto_sent"), prefs)
        if result.lunches_ordered:
            notify_core.notify("lunch_ordered", S("lunches_auto_ordered"), prefs)
        fetch_errors = [e for e in result.errors if e not in result.automation_errors]
        if fetch_errors:
            _phase, exc = fetch_errors[0]
            raise exc
        if result.automation_errors and result.only_low_balance:
            # Empty Strava account: remind once a day, not every run, and
            # do not count the run as failed (no 5-minute retry loop).
            from strakalari.core.refresh import claim_low_balance_notice

            _phase, exc = result.automation_errors[0]
            if claim_low_balance_notice():
                notify_core.notify("lunch_skipped", str(exc), prefs)
            return f"low balance: {len(result.unfunded_days)} lunch(es) not ordered"
        if result.automation_errors:
            # Its own notification (one toast, not also "refresh failed"):
            # data is fresh, but something was not sent or ordered.
            _phase, exc = result.automation_errors[0]
            notify_core.notify(
                "automation_failed",
                S("automation_failed_body").format(detail=str(exc).splitlines()[0][:200]),
                prefs)
            return f"automation failed: {str(exc).splitlines()[0][:120]}"
        count = result.subjects if result.bakalari_fetched else result.menu_days
        notify_core.notify("refresh_done", S("data_updated").format(count=count), prefs)
        done = [name for name, n in (("excuses", result.excuses_sent),
                                     ("meals", result.lunches_ordered)) if n]
        suffix = f" + {', '.join(done)}" if done else ""
        return f"{count} subjects{suffix}"

    def _on_result(self, result: JobResult) -> None:
        if not result.ok and not getattr(result, "reported", False):
            from .strings import S

            notify_core.notify("refresh_failed", S("job_failed").format(name=result.name), self._prefs())

    # -- UI process ---------------------------------------------------------
    def _ui_command(self) -> list[str]:
        # Frozen installers (PyInstaller) bundle main.py as the exe entry:
        # the bootloader ignores "-m" and would re-run main() with argv
        # ["-m", ...] straight into the CLI parser (exit 2, no window).
        # A bare exe launch opens the GUI, so frozen uses no extra args.
        if getattr(sys, "frozen", False):
            return [sys.executable]
        return [sys.executable, "-m", "strakalari.flet_ui"]

    def open_ui(self, icon=None, item=None) -> None:
        if self._ui_process is not None and self._ui_process.poll() is None:
            return
        try:
            import os

            # The child window is managed by the tray process already — it
            # must not spawn its own embedded tray icon (would double the
            # icons and schedulers). STRAKALARI_NO_TRAY makes the Flet UI
            # fall back to plain close-to-quit; closing it just exits the
            # child while this tray keeps running.
            # STRAKALARI_TRAY_CHILD additionally exempts the child from
            # the MAIN_PORT single-instance guard (the tray owns it) so
            # the child listens on UI_PORT for forwarded show requests.
            env = dict(os.environ)
            env["STRAKALARI_NO_TRAY"] = "1"
            env["STRAKALARI_TRAY_CHILD"] = "1"
            self._ui_process = subprocess.Popen(
                self._ui_command(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
        except Exception as exc:  # noqa: BLE001 - tray has no dialog; log it
            self._ui_process = None
            print(f"Warning: could not open Strakaláři window: {type(exc).__name__}: {exc}")
            return
        if getattr(self, "_host_mode", False):
            threading.Thread(target=self._follow_window, args=(self._ui_process,),
                             daemon=True, name="strakalari-follow-window").start()

    def _follow_window(self, proc) -> None:
        """Host mode: closing the window quits the app unless close-to-tray is on.

        With the toggle on (default) the tray stays in the menu bar and
        keeps refreshing, like the embedded tray on Windows.
        """
        try:
            proc.wait()
        except Exception:
            return
        if getattr(self, "_quitting", False) or self._ui_process is not proc:
            return  # tray Quit, or a newer window replaced this one
        try:
            close_to_tray = bool(ConfigManager().get("minimize_to_tray", True))
        except Exception:
            close_to_tray = True
        if close_to_tray:
            return
        from .macos import call_on_main_thread

        # quit() stops the pystray icon, which is Cocoa: main thread only.
        call_on_main_thread(self.quit)

    @staticmethod
    def _close_ui_gracefully(proc, timeout: float = 5.0) -> None:
        """Asks the UI child to close its window, then waits for it to exit.

        Needed on macOS: Flet opens the window through `open` (not our
        descendant) and ignores SIGTERM, so killing the child leaves a
        dead window behind. Callers still kill whatever did not exit.
        """
        try:
            if proc.poll() is not None:
                return
            from .single_instance import UI_PORT, SingleInstance

            if SingleInstance(UI_PORT).signal(kind="quit"):
                proc.wait(timeout=timeout)
        except Exception:
            pass

    @staticmethod
    def _is_paused(item=None) -> bool:
        from strakalari.core.refresh import automation_paused

        try:
            return automation_paused(ConfigManager().data)
        except Exception as exc:  # noqa: BLE001 - menu state only
            print(f"Warning: could not read the pause state: {exc}")
            return False

    def toggle_pause(self, icon=None, item=None) -> None:
        """Pauses / resumes every automatic send and order (tray menu)."""
        try:
            manager = ConfigManager()
            manager.set_and_save("automation_paused", not self._is_paused())
        except Exception as exc:  # noqa: BLE001 - tray has no dialog
            from .strings import S

            print(f"Warning: could not change the pause state: {exc}")
            notify_core.notify("refresh_failed", f"{S('save_failed')}: {exc}", self._prefs())

    def refresh_now(self, icon=None, item=None) -> None:
        threading.Thread(target=self.runner.run_now, daemon=True).start()

    def _ensure_ui_visible(self, icon=None, item=None) -> None:
        """Shows the window when a second launch signals this tray.

        Opens the UI, or forwards the request to the live child window —
        only the child owns its page, so only it can restore itself
        cross-platform. A child that never answers is left alone (never
        kill user state silently).
        """
        proc = self._ui_process
        if proc is None or proc.poll() is not None:
            self.open_ui()
            return
        try:
            from .single_instance import UI_PORT, SingleInstance

            if SingleInstance(UI_PORT).signal(kind="show"):
                return
        except Exception:
            pass
        print("Warning: UI process is running but did not respond; leaving it in place.")

    def quit(self, icon=None, item=None) -> None:
        """Exits the tray, leaving no Strakalari processes behind.

        Takes the menu callback args (pystray calls actions as
        ``(icon, item)``) so the bound method can be registered directly.
        The UI child is a whole tree (Flet window grandchild, browser
        workers) — plain terminate() would orphan those and keep ghost
        processes in Task Manager.
        """
        global _primary_guard

        self._quitting = True
        try:
            self.runner.stop()
        except Exception:
            pass
        # The UI is a child process tree — leaving any of it alive would
        # orphan a window (plus its own scheduler) after the tray is gone.
        proc, self._ui_process = self._ui_process, None
        if proc is not None:
            try:
                from .single_instance import terminate_process_tree

                if sys.platform == "darwin":
                    self._close_ui_gracefully(proc)
                terminate_process_tree(proc)
            except Exception:
                pass
        # Detached flet.exe ghosts (live parent long gone) hold no locks but
        # look like a failed quit — reap those by image name. Never sweep
        # our own image name here: onefile runs as two same-named processes
        # (bootloader parent + payload child), so that sweep kills us.
        try:
            from .single_instance import kill_orphaned_flet_views

            kill_orphaned_flet_views()
        except Exception:
            pass
        if self._icon is not None:
            try:
                self._icon.stop()
            except Exception:
                pass
        if _primary_guard is not None:
            try:
                _primary_guard.close()
            except Exception:
                pass
            _primary_guard = None

    # -- tray ------------------------------------------------------------------
    def run(self) -> None:
        from .startup import ensure_stdio

        ensure_stdio()

        global _primary_guard

        from .single_instance import MAIN_PORT, ensure_single_primary

        # A second launch shows the running window instead of starting a
        # duplicate tray (and its scheduler). --minimized only probes, so
        # autostart never pops a window over a running UI.
        minimized = "--minimized" in sys.argv[1:]
        status, guard = ensure_single_primary(
            MAIN_PORT, mode=("ping" if minimized else "show")
        )
        if status == "secondary":
            return
        if guard is not None:
            _primary_guard = guard  # held for the process lifetime
            guard.on_show = self._ensure_ui_visible
            # NOTE: never sweep same-named processes here (see app.run):
            # onefile's bootloader parent shares our image name, so that
            # sweep kills this process. Stale instances are stopped by the
            # installer (a different process name).
            # Orphaned viewers / headless browsers (no same-name risk)
            # from a killed run are reaped: their teardown never ran and
            # they would otherwise pile up across restarts.
            try:
                from .single_instance import (
                    kill_orphaned_flet_views,
                    kill_orphaned_headless_browsers,
                )

                kill_orphaned_flet_views()
                kill_orphaned_headless_browsers()
            except Exception:
                pass

        import pystray

        from .macos import install_reopen_handler, tray_hosts_window, use_accessory_policy
        from .strings import S

        # macOS: a menu-bar app, and relaunching it (Finder, Launchpad)
        # reaches us as a reopen event, not as a second process.
        use_accessory_policy()
        self._reopen_delegate = install_reopen_handler(self._ensure_ui_visible)
        self._host_mode = not minimized and tray_hosts_window()
        image = _icon_image()
        # pystray calls actions as (icon, item): the handlers take those
        # args, so the bound methods register directly.
        def _label(key: str):
            # Callable text: pystray re-reads it whenever the menu opens,
            # so a language switched in the window applies without restart.
            def _text(item=None) -> str:
                _apply_language(ConfigManager().data)
                return S(key)
            return _text

        menu = pystray.Menu(
            pystray.MenuItem(_label("tray_open"), self._ensure_ui_visible, default=True),
            pystray.MenuItem(_label("tray_refresh"), self.refresh_now),
            pystray.MenuItem(_label("tray_pause"), self.toggle_pause, checked=self._is_paused),
            pystray.MenuItem(_label("tray_quit"), self.quit),
        )
        self._icon = pystray.Icon("Strakalari", image, "Strakaláři", menu)
        self.runner.start()
        # Open the window on first start; afterwards the app lives in the tray.
        # Autostart passes --minimized: stay in the tray, never pop a window.
        if not minimized:
            self.open_ui()
        self._icon.run()


def run() -> None:
    TrayApp().run()


if __name__ == "__main__":
    run()
