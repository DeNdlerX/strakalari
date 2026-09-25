"""macOS process model: the tray hosts the window.

Cocoa's event loop must run on the main thread. A Flet window process
owns its main thread (asyncio), so on macOS it can never host the tray
icon: pystray's NSApp.run() on a side thread left the app "Not
Responding" (beachball) as soon as the window was shown. Instead every
normal launch runs the tray (pystray on the main thread, see tray.py),
and the window is its child process, as with the Windows autostart path.

Everything here is a no-op off macOS and never raises: AppKit (PyObjC,
pulled in by pystray) may be missing in a broken bundle, and the tray
must still start.
"""

from __future__ import annotations

import sys


def embedded_tray_supported() -> bool:
    """True where the window process can host its own tray icon."""
    return sys.platform != "darwin"


def tray_hosts_window() -> bool:
    """True where a normal launch runs the tray, which opens the window."""
    return sys.platform == "darwin"


def use_accessory_policy() -> None:
    """Menu-bar app: no Dock icon or app menu for the tray process.

    The bundle already says so (LSUIElement); this covers source runs,
    where the Python interpreter would otherwise show up in the Dock.
    """
    if sys.platform != "darwin":
        return
    try:
        import AppKit

        AppKit.NSApplication.sharedApplication().setActivationPolicy_(
            AppKit.NSApplicationActivationPolicyAccessory)
    except Exception:
        pass


_delegate_class = None


def install_reopen_handler(on_reopen):
    """Relaunching the running app (Finder, Launchpad, Spotlight) calls ``on_reopen``.

    LaunchServices never starts a second copy of a running .app, so the
    single-instance port never sees that launch: the running copy gets a
    reopen event instead, ignored without an app delegate. Returns the
    delegate, which the caller must keep alive (NSApp holds it weakly),
    or None.
    """
    global _delegate_class

    if sys.platform != "darwin":
        return None
    try:
        import AppKit
        from Foundation import NSObject

        if _delegate_class is None:
            class StrakalariAppDelegate(NSObject):
                def applicationShouldHandleReopen_hasVisibleWindows_(self, app, has_windows):
                    callback = getattr(self, "on_reopen", None)
                    if callback is not None:
                        try:
                            callback()
                        except Exception:
                            pass
                    return True

            _delegate_class = StrakalariAppDelegate
        delegate = _delegate_class.alloc().init()
        delegate.on_reopen = on_reopen
        AppKit.NSApplication.sharedApplication().setDelegate_(delegate)
        return delegate
    except Exception:
        return None


def call_on_main_thread(fn) -> None:
    """Runs ``fn`` on the Cocoa main thread (AppKit is not thread-safe).

    Off macOS, or without PyObjC, ``fn`` runs right here.
    """
    if sys.platform == "darwin":
        try:
            from PyObjCTools import AppHelper

            AppHelper.callAfter(fn)
            return
        except Exception:
            pass
    fn()
