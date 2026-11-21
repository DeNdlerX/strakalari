// How the app is packaged: Microsoft Store (MSIX) or the phone app.
//
// Port of strakalari/core/packaging.py. Behaviour differences are decided
// at runtime via package identity, NOT via a separate build flavour.
//
// Environment access goes through [getenv] so tests can override it with
// [setEnvironmentOverride] (Dart exposes the process environment read-only;
// Python tests use monkeypatch for the same cases).
import 'dart:io';

import 'package:path/path.dart' as p;

/// Test/app override for environment lookup. Null = real process environment.
Map<String, String>? _environmentOverride;

/// Overrides process-environment lookup (tests, and the app before
/// platform channels resolve on Android). Null restores the real one.
void setEnvironmentOverride(Map<String, String>? env) {
  _environmentOverride = env;
}

/// Process environment value, honouring [setEnvironmentOverride].
String? getenv(String name) =>
    (_environmentOverride ?? Platform.environment)[name];

/// Non-empty environment value, honouring the override (mirrors `or`).
String? getenvNonEmpty(String name) {
  final value = getenv(name);
  return (value == null || value.isEmpty) ? null : value;
}

/// `'android'` / `'ios'` inside the phone app, else null.
///
/// The Flet host sets `FLET_PLATFORM`; Dart also reports the OS itself.
String? mobilePlatform() {
  for (final value in [getenv('FLET_PLATFORM'), _hostPlatformName()]) {
    final v = (value ?? '').trim().toLowerCase();
    if (v == 'android' || v == 'ios') return v;
  }
  return null;
}

String _hostPlatformName() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return '';
}

/// True inside the Android / iOS app: no tray, autostart or self-update
/// there, and the data dir is the app's private storage.
bool isMobile() => mobilePlatform() != null;

/// Build-stamped phone distribution channel (`'play'` for Google Play).
/// Null in the repo — mirrors the missing `_distribution.py`.
String? androidDistributionChannel;

/// `'play'` / `'app_store'` when the phone app came from a store (which
/// then owns updates), null for the GitHub APK and off the phone.
String? mobileStore() {
  final platform = mobilePlatform();
  if (platform == 'ios') return 'app_store';
  if (platform != 'android') return null;
  return androidDistributionChannel == 'play' ? 'play' : null;
}

/// Probe the app registers at startup (Win32 package identity). Null =
/// unpackaged (dev runs, classic installs), which is the safe default.
bool Function()? _storePackageProbe;

/// Registers the MSIX package-identity probe (app startup, Windows).
void setStorePackageProbe(bool Function()? probe) {
  _storePackageProbe = probe;
}

/// True when the frozen app runs inside the Store MSIX package.
///
/// Dev runs never count (mirrors the `sys.frozen` gate).
bool isStorePackage() => _storePackageProbe?.call() ?? false;

/// Where the classic Inno install keeps user data, if it exists.
String? legacyDesktopDataDir() {
  if (!Platform.isWindows) return null;
  final base = getenvNonEmpty('LOCALAPPDATA') ?? getenvNonEmpty('APPDATA');
  if (base == null) return null;
  final legacy = p.join(base, 'Programs', 'Strakalari');
  return (File(p.join(legacy, 'config.json')).existsSync() ||
          File(p.join(legacy, 'accounts.json')).existsSync())
      ? legacy
      : null;
}
