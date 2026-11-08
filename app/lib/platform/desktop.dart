// Desktop platform: tray, window, autostart, single instance (stubs).
//
// Port targets: `flet_ui/tray.py`, `flet_ui/macos.py`,
// `flet_ui/single_instance.py` and `core/autostart.py`. Phase 7 fills
// in the real behavior (one process — the window hides to the tray;
// single instance keeps the existing loopback-TCP design; autostart
// launches with `--minimized`; MSIX StartupTask identity). Until then
// these seams compile, are callable from the shell, and record calls
// for tests.
import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// App identity shared with the Python packaging (unchanged so the
/// Flutter build installs as an update).
const String appWindowTitle = 'Strakaláři';

/// Hides the window to the tray instead of exiting (when enabled).
/// Phase 7 wires `windowManager.setPreventClose` + the close callback.
class DesktopWindow {
  bool hideToTrayEnabled = false;
  bool _ready = false;

  Future<void> ensureInitialized() async {
    if (_ready) return;
    try {
      await windowManager.ensureInitialized();
      _ready = true;
    } catch (_) {
      // Window hooks are optional (tests, unsupported platforms).
    }
  }

  Future<void> show() async {
    try {
      await windowManager.show();
    } catch (_) {
      // No window to show.
    }
  }

  Future<void> hide() async {
    try {
      await windowManager.hide();
    } catch (_) {
      // No window to hide.
    }
  }
}

/// System-tray icon + menu (phase-7 behavior: show/hide, refresh,
///
/// pause toggle, quit). Until then [setup] is safe to call anywhere.
class DesktopTray {
  bool _ready = false;

  Future<void> setup({
    required Future<void> Function() onShow,
    required Future<void> Function() onQuit,
  }) async {
    if (_ready) return;
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip(appWindowTitle);
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show', onClick: (_) => onShow()),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit', onClick: (_) => onQuit()),
      ]));
      _ready = true;
    } catch (_) {
      // Tray is optional (tests, unsupported platforms).
    }
  }

  Future<void> popUp() async {
    try {
      await trayManager.popUpContextMenu();
    } catch (_) {
      // No tray to pop up.
    }
  }

  Future<void> destroy() async {
    try {
      await trayManager.destroy();
    } catch (_) {
      // Already gone.
    }
    _ready = false;
  }
}

/// Launch-at-login (registry entry / login item / .desktop file / MSIX
/// StartupTask in phase 7). Until then the preference round-trips.
class DesktopAutostart {
  bool _enabled = false;

  Future<bool> isEnabled() async {
    try {
      return await LaunchAtStartup.instance.isEnabled();
    } catch (_) {
      return _enabled;
    }
  }

  Future<bool> setEnabled(bool enabled, {String appPath = ''}) async {
    try {
      LaunchAtStartup.instance.setup(
        appName: appWindowTitle,
        appPath: appPath.isEmpty ? Platform.resolvedExecutable : appPath,
        args: ['--minimized'],
      );
      final ok = enabled
          ? await LaunchAtStartup.instance.enable()
          : await LaunchAtStartup.instance.disable();
      if (ok) _enabled = enabled;
      return ok;
    } catch (_) {
      _enabled = enabled;
      return false;
    }
  }
}

/// Single-instance guard (phase 7: the existing loopback-TCP design, so
/// a second launch forwards to the running window instead of starting
/// a second refresh pipeline).
class SingleInstanceGuard {
  bool _held = false;

  /// True when this process owns the instance.
  Future<bool> acquire() async {
    _held = true;
    return true;
  }

  Future<void> release() async {
    _held = false;
  }

  bool get held => _held;
}
