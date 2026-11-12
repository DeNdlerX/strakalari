// Is this the Store (MSIX) build? Port of `_has_package_identity` and
// the `sys.frozen` gate of `is_store_package` (core/packaging.py).
//
// Core decides the Store behaviour (data folder, no GitHub update check,
// no Run-key autostart) through `isStorePackage()`, whose probe the app
// registers at start-up ([registerStorePackageProbe]).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// `APPMODEL_ERROR_NO_PACKAGE`: the process has no package identity.
const int appModelErrorNoPackage = 15700;

typedef _GetCurrentPackageFullNameC = Int32 Function(Pointer<Uint32>, Pointer<Utf16>);
typedef _GetCurrentPackageFullNameDart = int Function(Pointer<Uint32>, Pointer<Utf16>);

/// `GetCurrentPackageFullName(&length, NULL)`'s return code: packaged →
/// ERROR_INSUFFICIENT_BUFFER (122), unpackaged → 15700.
int _currentPackageFullNameRc() {
  final fn = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<_GetCurrentPackageFullNameC, _GetCurrentPackageFullNameDart>(
          'GetCurrentPackageFullName');
  return using((Arena arena) {
    final length = arena<Uint32>()..value = 0;
    return fn(length, nullptr);
  });
}

/// `_has_package_identity`: true when the process runs with a package
/// identity (MSIX). Never throws. [rc] is a test seam.
bool hasPackageIdentity({int Function()? rc, bool? windows}) {
  if (!(windows ?? Platform.isWindows)) return false;
  try {
    return (rc ?? _currentPackageFullNameRc)() != appModelErrorNoPackage;
  } catch (_) {
    return false;
  }
}

/// `is_store_package`: frozen (a release build) and packaged, cached.
/// Dev runs never count, like Python's `sys.frozen` gate.
bool Function() storePackageProbe({bool release = kReleaseMode, bool Function()? identity}) {
  bool? cached;
  return () => cached ??= release && (identity ?? hasPackageIdentity)();
}

/// Registers the probe with core (call before the data dir is resolved).
void registerStorePackageProbe() => setStorePackageProbe(storePackageProbe());
