// Android Keystore bridge (implemented by the app's MethodChannel).
//
// Port of the `core.android` half of strakalari/core/secret_store.py.
// Null (desktop, tests) means "no Keystore": the plain file fallback.
import 'dart:typed_data';

/// Wraps/unwraps the Fernet key with a hardware-backed Android Keystore key.
abstract interface class AndroidKeystoreBridge {
  /// True when the Keystore backend answers.
  bool get available;

  /// Encrypts [key] with the Keystore key.
  Uint8List wrap(Uint8List key);

  /// Decrypts a blob [wrap] produced.
  Uint8List unwrap(Uint8List blob);
}

/// The bridge the app registers at startup (null off Android).
AndroidKeystoreBridge? androidKeystoreBridge;
