// OS credential store abstraction for the password-encryption key.
//
// The app implements [KeyStore] per platform (Windows Credential Manager,
// macOS Keychain, libsecret on Linux, Android Keystore); tests and the
// Dart CLI use an in-memory fake. Port of the keyring half of
// strakalari/core/secret_store.py.

/// A single OS credential entry: get/set/delete one password.
abstract interface class KeyStore {
  /// Stored password, or null when the entry does not exist.
  ///
  /// Throws [KeyStoreMissing] when the backend itself is absent (mirrors
  /// keyring's NoKeyringError/InitError: fall back to the file), and
  /// [KeyStoreUnavailable] when the backend refused to answer.
  String? getPassword(String service, String account);

  /// Stores and reads the password back (mirrors `_to_store`).
  void setPassword(String service, String account, String password);

  /// Deletes the entry; missing entries are silent.
  void deletePassword(String service, String account);
}

/// The credential store exists but refused to answer (e.g. locked).
///
/// Raised instead of silently generating a new key, which would make
/// every stored password undecryptable once the store is back.
class KeyStoreUnavailable implements Exception {
  final String message;
  const KeyStoreUnavailable(this.message);

  @override
  String toString() => 'KeyStoreUnavailable: $message';
}

/// The credential backend itself is absent (mirrors NoKeyringError).
/// Callers fall back to the `secret.key` file.
class KeyStoreMissing implements Exception {
  final String message;
  const KeyStoreMissing([this.message = 'No credential store backend.']);

  @override
  String toString() => 'KeyStoreMissing: $message';
}

/// The backend the app registered at startup (null = none available).
KeyStore? keyStoreBackend;
