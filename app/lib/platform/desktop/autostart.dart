// Autostart on system boot: registry login item / .desktop / MSIX.
//
// Port of `strakalari/core/autostart.py`. The launch command, the
// storage location and the legacy-shortcut adoption are identical so
// the in-app toggle, the installer and an over-installed Python build
// always agree:
//
// * Windows (classic install): `HKCU\...\Run` value `Strakalari` =
//   `"<exe>" --minimized`. An older installer's `{userstartup}`
//   shortcut still counts as enabled and is adopted (deleted) on the
//   next toggle — otherwise the app would launch twice.
// * macOS: `~/Library/LaunchAgents/cz.strakalari.app.plist`
//   (label `cz.strakalari.app`, same as the Python `.app` bundle and
//   the Python plist, so old and new installs interoperate).
// * Linux: `~/.config/autostart/strakalari.desktop`
//   (same file name and `Exec` quoting as Python).
// * Store MSIX: startup is owned by Windows (the `StartupTask` in
//   `msix/AppxManifest.xml`, toggled in Settings > Apps > Startup).
//   The HKCU Run value has no effect there, so both functions refuse
//   and the in-app toggle must stay hidden (matches Python's
//   `_store_managed` gate via core `isStorePackage()`).
//
// The app itself always starts with `--minimized` from login; the
// window then stays hidden in the tray (see `tray.dart`).
//
// Differences from Python: the registry/file writes use `dart:io`
// plus `package:win32` (registry) instead of `winreg`; `getLaunchCommand`
// resolves the exe from `Platform.resolvedExecutable` (the release
// build) instead of `sys.executable`. macOS/Linux parts are written
// but UNVERIFIED (no Mac/Linux run here yet).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:strakalari_core/strakalari_core.dart';
import 'package:win32/win32.dart';

/// The HKCU Run key, as `winreg` sees it (a fake in tests).
abstract interface class RunKeyRegistry {
  /// `QueryValueEx(key, name)`; null when the value is missing
  /// (`FileNotFoundError`). Throws [RunKeyUnavailable] when the key cannot
  /// be opened (`OpenKey` raised).
  String? query(String name);

  /// `SetValueEx(key, name, 0, REG_SZ, value)`; throws on failure.
  void set(String name, String value);

  /// `DeleteValue(key, name)`; a missing value is not an error.
  void delete(String name);
}

/// `winreg.OpenKey` failed (the key could not be opened).
class RunKeyUnavailable implements Exception {
  final String message;
  const RunKeyUnavailable(this.message);
  @override
  String toString() => message;
}

/// Test seams (Python's tests patch `sys.platform`, `winreg`, `HOME`,
/// `sys.executable`): `'win32'`, `'darwin'` or `'linux'`.
@visibleForTesting
String? autostartPlatformOverride;
@visibleForTesting
RunKeyRegistry? autostartRegistryOverride;
@visibleForTesting
Map<String, String>? autostartEnvOverride;
@visibleForTesting
String? autostartExecutableOverride;

String get _platform =>
    autostartPlatformOverride ??
    (Platform.isWindows ? 'win32' : (Platform.isMacOS ? 'darwin' : 'linux'));
Map<String, String> get _env => autostartEnvOverride ?? Platform.environment;
String get _executable => autostartExecutableOverride ?? Platform.resolvedExecutable;
RunKeyRegistry get _registry => autostartRegistryOverride ?? const _Win32RunKey();

/// Value / file / plist name (matches Python `APP_NAME`).
const String autostartAppName = 'Strakalari';

/// macOS launch-agent label (matches Python and the shipped `.app`).
const String macosLaunchLabel = 'cz.strakalari.app';

/// Quoted launch command for startup execution (matches Python's
/// `get_launch_command`: double-quoted paths with spaces; single
/// quotes are NOT used because desktop-file parsers ignore them).
String getLaunchCommand({bool minimized = true, String? executablePath}) {
  final exe = executablePath ?? _executable;
  final args = <String>[exe];
  if (minimized) args.add('--minimized');
  return args
      .map((a) => ((a.contains(' ') || a.contains('\t')) &&
              !(a.startsWith('"') && a.endsWith('"')))
          ? '"$a"'
          : a)
      .join(' ');
}

/// Legacy Startup-folder shortcut older installers created.
///
/// The app reads the HKCU Run value, so the shortcut still counts as
/// enabled (and is adopted on the next toggle).
String startupShortcutPath() {
  final env = _env;
  final appData = (env['APPDATA']?.isNotEmpty ?? false)
      ? env['APPDATA']!
      : (env['USERPROFILE'] ?? env['HOME'] ?? '');
  return '$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$autostartAppName.lnk';
}

/// True inside the Store MSIX package, where startup is owned by
/// Windows (the `StartupTask`), not by the HKCU Run value.
bool autostartManagedByStore() {
  try {
    return isStorePackage();
  } catch (_) {
    return false;
  }
}

/// True when autostart on system boot is enabled.
bool isAutostartEnabled() {
  if (autostartManagedByStore()) return false;
  if (_platform == 'win32') return _isEnabledWindows();
  if (_platform == 'darwin') {
    return File(_macosPlistPath()).existsSync();
  }
  return File(_linuxDesktopPath()).existsSync();
}

/// Enables or disables autostart on system boot.
bool setAutostart(bool enabled, {bool minimized = true}) {
  if (autostartManagedByStore()) return false;
  if (_platform == 'win32') return _setWindows(enabled, minimized: minimized);
  if (_platform == 'darwin') return _setMacos(enabled, minimized: minimized);
  return _setLinux(enabled, minimized: minimized);
}

// -- Windows -------------------------------------------------------------

bool _isEnabledWindows() {
  try {
    if (_registry.query(autostartAppName) != null) return true;
  } on RunKeyUnavailable {
    // Falls through to the shortcut, like a failed `OpenKey`.
  } catch (_) {
    return false; // any other query error
  }
  // No Run value — an older installer may have left a Startup-folder
  // shortcut behind, which launches the app too.
  try {
    return File(startupShortcutPath()).existsSync();
  } catch (_) {
    return false;
  }
}

bool _setWindows(bool enabled, {required bool minimized}) {
  try {
    if (enabled) {
      _registry.set(autostartAppName, getLaunchCommand(minimized: minimized));
    } else {
      _registry.delete(autostartAppName); // missing is fine
    }
    // Adopt the legacy installer shortcut: from now on the Run value
    // above is the single source of truth, so the shortcut must go —
    // otherwise the app would launch twice (or keep launching after
    // the user switched autostart off).
    _removeLegacyShortcut();
    return true;
  } catch (e) {
    // ignore: avoid_print
    print('Warning: Could not update Windows startup registry: $e');
    return false;
  }
}

/// The real HKCU Run key through `package:win32`.
class _Win32RunKey implements RunKeyRegistry {
  const _Win32RunKey();

  @override
  String? query(String name) {
    final key = _openRunKey(writable: false);
    try {
      return _queryRunValue(key, name);
    } finally {
      RegCloseKey(key);
    }
  }

  @override
  void set(String name, String value) {
    final key = _openRunKey(writable: true);
    try {
      if (!_writeRunValue(key, name, value)) {
        throw const RunKeyUnavailable('RegSetValueEx failed');
      }
    } finally {
      RegCloseKey(key);
    }
  }

  @override
  void delete(String name) {
    final key = _openRunKey(writable: true);
    try {
      using((Arena arena) {
        // Missing value is fine (already disabled).
        RegDeleteValue(key, name.toNativeUtf16(allocator: arena));
      });
    } finally {
      RegCloseKey(key);
    }
  }
}

int _openRunKey({required bool writable}) {
  return using((Arena arena) {
    final subkey = r'Software\Microsoft\Windows\CurrentVersion\Run'
        .toNativeUtf16(allocator: arena);
    final out = arena<IntPtr>();
    final access = writable ? KEY_SET_VALUE : KEY_READ;
    final rc = RegOpenKeyEx(HKEY_CURRENT_USER, subkey, 0, access, out);
    if (rc != 0) throw RunKeyUnavailable('RegOpenKeyEx failed (Win32 error $rc)');
    return out.value;
  });
}

String? _queryRunValue(int key, String valueName) {
  return using((Arena arena) {
    final name = valueName.toNativeUtf16(allocator: arena);
    final type = arena<Uint32>();
    final size = arena<Uint32>()..value = 0;
    var rc = RegQueryValueEx(key, name, nullptr, type, nullptr, size);
    if (rc == 2 /* ERROR_FILE_NOT_FOUND */) return null;
    if (rc != 0) throw StateError('RegQueryValueEx failed (Win32 error $rc)');
    if (size.value == 0) return '';
    final data = arena<Uint8>(size.value);
    rc = RegQueryValueEx(key, name, nullptr, type, data, size);
    if (rc != 0) throw StateError('RegQueryValueEx failed (Win32 error $rc)');
    final units = size.value ~/ 2;
    // REG_SZ is UTF-16LE NUL-terminated; read the raw units
    // (`Pointer<Utf16>` has no `asTypedList`; the units are identical).
    final codeUnits = data.cast<Uint16>().asTypedList(units);
    var end = codeUnits.length;
    while (end > 0 && codeUnits[end - 1] == 0) {
      end--;
    }
    return String.fromCharCodes(codeUnits.sublist(0, end));
  });
}

bool _writeRunValue(int key, String valueName, String command) {
  return using((Arena arena) {
    final name = valueName.toNativeUtf16(allocator: arena);
    final withNull = [...command.codeUnits, 0];
    final data = arena<Uint16>(withNull.length);
    data.asTypedList(withNull.length).setAll(0, withNull);
    return RegSetValueEx(key, name, 0, REG_SZ, data.cast(), withNull.length * 2) == 0;
  });
}

void _removeLegacyShortcut() {
  try {
    final file = File(startupShortcutPath());
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

// -- macOS ---------------------------------------------------------------
// UNVERIFIED: written from `autostart.py`, never run on a Mac.

String _macosPlistPath() {
  final home = _env['HOME'] ?? '';
  return '$home/Library/LaunchAgents/$macosLaunchLabel.plist';
}

/// `xml.sax.saxutils.escape`: `&`, `<` and `>` only.
String _xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

bool _setMacos(bool enabled, {required bool minimized}) {
  final plist = File(_macosPlistPath());
  if (!enabled) {
    if (!plist.existsSync()) return true;
    try {
      plist.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
  final args = <String>[_executable];
  if (minimized) args.add('--minimized');
  final argsXml =
      args.map((a) => '<string>${_xmlEscape(a)}</string>').join('\n        ');
  final content = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$macosLaunchLabel</string>
    <key>ProgramArguments</key>
    <array>
        $argsXml
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
''';
  plist.parent.createSync(recursive: true); // os.makedirs, outside the try
  try {
    plist.writeAsStringSync(content);
    return true;
  } catch (e) {
    // ignore: avoid_print
    print('Warning: Could not create macOS launch agent: $e');
    return false;
  }
}

// -- Linux ---------------------------------------------------------------
// UNVERIFIED: written from `autostart.py`, never run on Linux.

String _linuxDesktopPath() {
  final home = _env['HOME'] ?? '';
  return '$home/.config/autostart/${autostartAppName.toLowerCase()}.desktop';
}

bool _setLinux(bool enabled, {required bool minimized}) {
  final desktop = File(_linuxDesktopPath());
  if (!enabled) {
    if (!desktop.existsSync()) return true;
    try {
      desktop.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
  final content = '''[Desktop Entry]
Type=Application
Version=1.0
Name=Strakaláři
Comment=Automated school absence excusing and food ordering
Exec=${getLaunchCommand(minimized: minimized)}
Terminal=false
Categories=Utility;Education;
''';
  desktop.parent.createSync(recursive: true); // os.makedirs, outside the try
  try {
    desktop.writeAsStringSync(content);
    return true;
  } catch (e) {
    // ignore: avoid_print
    print('Warning: Could not create Linux autostart desktop entry: $e');
    return false;
  }
}
