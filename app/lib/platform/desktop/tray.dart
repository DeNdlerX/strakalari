// Desktop tray + window (one process).
//
// Port of `strakalari/flet_ui/tray.py` and `flet_ui/macos.py` to the
// Flutter one-process model (PLAN §3.2/§3.4):
// * Python runs TWO processes (tray parent + Flet window child), so
//   closing the window never kills automation. Flutter runs ONE: the
//   window hides to the tray (where the user enabled
//   `minimize_to_tray`), and the scheduler lives in the same isolate.
//   Closing the window therefore only hides it; real quit is the tray
//   menu's Quit (or the window close with the toggle off).
// * Autostart launches with `--minimized`: the window starts hidden
//   and only the tray + scheduler run.
// * On macOS the tray can never live in the window process (Cocoa's
//   event loop must run on the main thread — see `macos.py`), so the
//   Flutter window must always hide to the tray there; `hideToTray`
//   defaults to true on macOS regardless of the setting. (The
//   accessory-policy part — no Dock icon — is runner config,
//   `LSUIElement`; see the phase-7 docs note.)
// * The schedule is core's `PeriodicRunner`, built by
//   `platform/scheduler_jobs.dart` (`_register_jobs`), not by this file.
//
// This file owns the window/tray mechanics only. Calling
// [DesktopTrayController.initialize] is safe anywhere (tests,
// unsupported platforms): every OS call is guarded.
import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Window title / tray tooltip. Must match the shell's title and the
/// phase-5 stub's `appWindowTitle` (`platform/desktop.dart`).
const String desktopWindowTitle = 'Strakaláři';

/// True where the window process can host its own tray icon
/// (mirrors `macos.embedded_tray_supported`).
bool get embeddedTraySupported => !Platform.isMacOS;

/// True where a normal launch runs the tray, which opens the window
/// (mirrors `macos.tray_hosts_window`). On macOS the window must
/// always hide to the tray instead of quitting.
bool get trayHostsWindow => Platform.isMacOS;

/// Tray-menu labels. Defaults cover cs (the app default) and en; the
/// app passes localized strings from its ARB bundle when available.
class TrayStrings {
  const TrayStrings({
    required this.open,
    required this.refreshNow,
    required this.pause,
    required this.resume,
    required this.quit,
  });

  final String open;
  final String refreshNow;
  final String pause;
  final String resume;
  final String quit;

  static TrayStrings forLanguage(String language) {
    if (language.toLowerCase().startsWith('en')) {
      return const TrayStrings(
        open: 'Open Strakaláři',
        refreshNow: 'Refresh now',
        pause: 'Pause automation',
        resume: 'Resume automation',
        quit: 'Quit',
      );
    }
    return const TrayStrings(
      open: 'Otevřít Strakaláře',
      refreshNow: 'Aktualizovat nyní',
      pause: 'Pozastavit automatiku',
      resume: 'Obnovit automatiku',
      quit: 'Ukončit',
    );
  }
}

/// Window + tray mechanic: hide-to-tray, tray menu, show/quit.
///
/// Distinct from the phase-5 stub (`platform/desktop.dart`): that one
/// records calls for tests, this one drives the real plugins.
class DesktopTrayController with WindowListener, TrayListener {
  DesktopTrayController({
    String? iconPath,
    TrayStrings? strings,
    this.onOpenWindow,
    this.onRefreshNow,
    this.onTogglePause,
    this.onQuit,
    this.isPaused,
    this.hideToTraySetting,
  })  : _iconPath = iconPath ?? 'assets/tray-icon.ico',
        _strings = strings ?? TrayStrings.forLanguage('cs');

  final String _iconPath;
  TrayStrings _strings;
  final Future<void> Function()? onOpenWindow;
  final Future<void> Function()? onRefreshNow;
  final Future<void> Function()? onTogglePause;
  final Future<void> Function()? onQuit;
  final bool Function()? isPaused;
  final bool Function()? hideToTraySetting;

  bool _ready = false;
  bool _quitting = false;

  /// Effective hide-to-tray: forced on macOS (the tray cannot live in
  /// the window process there), otherwise the user's setting.
  bool get hideToTray => trayHostsWindow || (hideToTraySetting?.call() ?? true);

  /// Prepares window + tray hooks. Safe to call anywhere.
  Future<void> initialize({required bool minimized}) async {
    if (_ready) return;
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      await trayManager.setIcon(_iconPath);
      await trayManager.setToolTip(desktopWindowTitle);
      trayManager.addListener(this);
      await _rebuildMenu();

      if (minimized) {
        await windowManager.hide();
      } else {
        await showWindow();
      }
      _ready = true;
    } catch (_) {
      // Window hooks are optional (tests, unsupported platforms).
    }
  }

  /// Shows and focuses the window (single-instance signal lands here).
  Future<void> showWindow() async {
    try {
      await onOpenWindow?.call();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  /// Rebuilds the tray menu (call after a language or pause change —
  /// mirrors pystray re-reading the labels on every open).
  Future<void> updateMenu({TrayStrings? strings}) async {
    if (strings != null) _strings = strings;
    await _rebuildMenu();
  }

  Future<void> _rebuildMenu() async {
    try {
      final paused = isPaused?.call() ?? false;
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(
          key: 'show',
          label: _strings.open,
          onClick: (_) => showWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'refresh',
          label: _strings.refreshNow,
          onClick: (_) async {
            try {
              await onRefreshNow?.call();
            } catch (_) {}
          },
        ),
        MenuItem.checkbox(
          key: 'pause',
          label: paused ? _strings.resume : _strings.pause,
          checked: paused,
          onClick: (_) async {
            try {
              await onTogglePause?.call();
            } catch (_) {}
            await _rebuildMenu();
          },
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: _strings.quit,
          onClick: (_) => quit(),
        ),
      ]));
    } catch (_) {}
  }

  /// Real quit from the tray menu (or window close with the toggle
  /// off): stops the loop via [onQuit], drops the icon, exits.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await onQuit?.call();
    } catch (_) {}
    try {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  // -- WindowListener ---------------------------------------------------

  @override
  Future<void> onWindowClose() async {
    if (_quitting || !hideToTray) {
      await quit();
      return;
    }
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  // -- TrayListener ------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_rebuildMenu());
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // Handled by each item's onClick above; kept for the interface.
  }
}
