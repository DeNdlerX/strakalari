"""Customizable desktop notifications (tray-hidden friendly).

Each event type can be toggled in settings under the ``notifications`` config
key, e.g. ``{"excuse_sent": true, "refresh_failed": true}``. Unknown keys
default to ON so new event types are visible until the user opts out.

Backends (first working one wins, stdlib only — no extra dependencies,
so frozen builds on all three OSes just work):

- Windows: native WinRT toast (``ToastNotificationManager``) via a hidden
  ``powershell -File`` script written as UTF-8 with BOM. This shows a real
  Action-Center toast. ``plyer`` is NOT used here on purpose: it drives the
  legacy ``Shell_NotifyIcon`` balloon tip, which Windows 10/11 silently
  drops for temp hidden tray icons — and its fire-and-forget thread makes
  the failure invisible. (Passing the script via ``-Command`` would also
  mangle Czech diacritics; ``-File`` + BOM keeps them intact.)
- macOS: ``osascript`` (always present), then ``plyer`` (needs ``pyobjus``,
  usually absent).
- Linux: ``notify-send`` (checked exit code), then ``plyer``
  (xdg-portal / D-Bus path).

Sending never raises, so background jobs stay alive — but unlike before,
the return value is honest: True only when a backend accepted the toast.
(Unknown event names raise ``ValueError``: that is a programmer error,
not a runtime failure.)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import Any

try:
    from plyer import notification as _plyer_notification
except Exception:  # plyer not installed (dev venv / minimal build)
    _plyer_notification = None

APP_NAME = "Strakaláři"

#: WinRT toast identity. Must stay plain ASCII — the toast API does not
#: accept diacritics here (the visible title still uses APP_NAME above).
APP_ID = "Strakalari"


EVENT_TYPES: tuple[str, ...] = (
    "excuse_sent",
    "excuse_needs_confirm",
    "refresh_done",
    "refresh_failed",
    "lunch_ordered",
    "lunch_skipped",
    "planner_suggestion",
    "automation_failed",
)

DEFAULTS: dict[str, bool] = {event: True for event in EVENT_TYPES}


def is_enabled(prefs: dict | None, event: str) -> bool:
    """True unless the user explicitly disabled ``event``."""
    if not isinstance(prefs, dict):
        return True
    if event not in prefs:
        return True
    return bool(prefs[event])


def _ps_single_quote(text: str) -> str:
    """Escape ``text`` for a PowerShell single-quoted literal ($ and ` stay literal)."""
    return text.replace("'", "''")


def _cdata(text: str) -> str:
    """Wrap ``text`` as XML CDATA (toast title/body)."""
    return "<![CDATA[" + text.replace("]]>", "]] >") + "]]>"


def _toast_ps_script(title: str, message: str, tag: str) -> str:
    """Build the PowerShell script showing one WinRT toast."""
    xml = (
        '<toast duration="short">'
        "<visual><binding template=\"ToastGeneric\">"
        "<text id=\"1\">" + _cdata(title) + "</text>"
        "<text id=\"2\">" + _cdata(message) + "</text>"
        "</binding></visual>"
        "<audio silent=\"true\"/>"
        "</toast>"
    )
    return (
        "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, "
        "ContentType=WindowsRuntime] | Out-Null\n"
        "[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, "
        "ContentType=WindowsRuntime] | Out-Null\n"
        "$xml = '" + _ps_single_quote(xml) + "'\n"
        "$doc = New-Object Windows.Data.Xml.Dom.XmlDocument\n"
        "$doc.LoadXml($xml)\n"
        "$toast = [Windows.UI.Notifications.ToastNotification]::new($doc)\n"
        "$toast.Tag = '" + _ps_single_quote(tag) + "'\n"
        "$toast.Group = '" + _ps_single_quote(APP_ID) + "'\n"
        "$notifier = [Windows.UI.Notifications.ToastNotificationManager]"
        "::CreateToastNotifier('" + _ps_single_quote(APP_ID) + "')\n"
        "$notifier.Show($toast)\n"
    )


def _send_windows(title: str, message: str, tag: str) -> bool:
    """Native WinRT toast via hidden powershell. True only on exit code 0."""
    exe = shutil.which("powershell.exe") or shutil.which("pwsh.exe") or shutil.which("pwsh")
    if exe is None:
        return False
    import os
    import tempfile

    # UTF-8 with BOM: without it PowerShell 5.1 reads -File scripts in the
    # system codepage and Czech diacritics come out mangled.
    fd, path = tempfile.mkstemp(suffix=".ps1", prefix="strakalari-toast-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8-sig") as handle:
            handle.write(_toast_ps_script(title, message, tag))
        try:
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        except AttributeError:
            # Non-Windows (tests / dry runs): no window flags available.
            startupinfo = None
        proc = subprocess.run(
            [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            startupinfo=startupinfo,
            timeout=30,
        )
        return proc.returncode == 0
    except Exception:
        return False
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _send_macos(title: str, message: str) -> bool:
    """macOS Notification Center via osascript (no dependencies)."""
    exe = shutil.which("osascript")
    if exe is None:
        return False

    def _escape(text: str) -> str:
        return text.replace("\\", "\\\\").replace('"', '\\"')

    script = (
        'display notification "' + _escape(message) + '"'
        ' with title "' + _escape(title) + '"'
        ' subtitle "' + _escape(APP_NAME) + '"'
    )
    try:
        proc = subprocess.run(
            [exe, "-e", script],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        return proc.returncode == 0
    except Exception:
        return False


def _send_linux(title: str, message: str) -> bool:
    """Linux desktop notification via notify-send (checked exit code)."""
    exe = shutil.which("notify-send")
    if exe is None:
        return False
    try:
        proc = subprocess.run(
            [exe, "-a", APP_NAME, title, message, "-t", "8000"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        return proc.returncode == 0
    except Exception:
        return False


def _send_plyer(title: str, message: str) -> bool:
    """Legacy plyer fallback (Linux D-Bus/portals, old Windows balloon)."""
    if _plyer_notification is None:
        return False
    try:
        _plyer_notification.notify(
            title=title,
            message=message,
            app_name=APP_NAME,
            timeout=8,
        )
        return True
    except Exception as exc:  # noqa: BLE001 - notification must never crash jobs
        print(f"[{title}] {message} (notification backend failed: {exc})")
        return False


def _send(title: str, message: str, tag: str = "") -> bool:
    platform = sys.platform
    try:
        if platform == "win32":
            if _send_windows(title, message, tag):
                return True
        elif platform == "darwin":
            if _send_macos(title, message):
                return True
        else:
            if _send_linux(title, message):
                return True
    except Exception:  # noqa: BLE001 - notification must never crash jobs
        pass
    # Cross-platform last resort before giving up (never raises).
    if _send_plyer(title, message):
        return True
    # No toast backend worked — plain stdout fallback, no scary suffix.
    print(f"[{title}] {message}")
    return False


def notify(event: str, message: str, prefs: dict[str, Any] | None = None) -> bool:
    """Sends ``message`` for ``event`` when enabled. Returns sent-or-not.

    Raises ``ValueError`` for unknown events; the actual send never raises.
    """
    if event not in EVENT_TYPES:
        raise ValueError(f"Unknown notification event: {event!r}")
    if not is_enabled(prefs, event):
        return False
    return _send(APP_NAME, message, tag=event)
