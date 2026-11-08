// Pure-Dart core of Strakalari (must never import Flutter).
//
// Behavior parity with `strakalari/core` (Python). Modules are ported one by
// one; each port adds its export here and a `*_test.dart` counterpart under
// `test/`.
export 'src/platform/packaging.dart';
export 'src/platform/keystore.dart';
export 'src/platform/android_bridge.dart';
export 'src/storage/fernet.dart';
export 'src/storage/helpers.dart';
export 'src/storage/cache.dart';
export 'src/storage/config.dart';
export 'src/storage/secret_store.dart';
export 'src/models.dart';
export 'src/i18n.dart';
