// OS credential-store KeyStore (phase-5 stub).
//
// Port target: the `KeyStore` interface in `core/platform/keystore.dart`
// (backed by Python `keyring`: Windows Credential Manager, macOS
// Keychain, Linux Secret Service / libsecret, Android Keystore).
// Phase 7 implements the real backends (`win32` `CredRead`/`CredWrite`
// on Windows, a small Swift channel on macOS, libsecret on Linux —
// reading the *same* `Strakalari` service entries Python's keyring
// wrote, so installing over the Python build keeps passwords; if a
// read fails the wizard asks for passwords again, the documented
// fallback). Until then this in-memory stub keeps the shell and the
// secret-store seams compiling and testable.
import 'package:strakalari_core/strakalari_core.dart';

/// In-memory [KeyStore] stand-in. Throws [KeyStoreUnavailable] never —
/// it stores, but nothing survives a restart (phase 7 persists).
class MemoryKeyStore implements KeyStore {
  final Map<String, String> _vault = {};

  String _slot(String service, String account) => '$service\x00$account';

  @override
  String? getPassword(String service, String account) =>
      _vault[_slot(service, account)];

  @override
  void setPassword(String service, String account, String password) {
    _vault[_slot(service, account)] = password;
  }

  @override
  void deletePassword(String service, String account) {
    _vault.remove(_slot(service, account));
  }
}
