// Desktop OS credential store: Windows Credential Manager, macOS
// Keychain, Linux Secret Service.
//
// Implements core's `KeyStore` interface so `secret_store` reads the
// *same* `Strakalari` entries Python's `keyring` wrote: installing the
// Flutter build over a Python build keeps passwords with no migration
// step. The store entry name is core's
// `entryName(dataDir)` == `fernet-key:<first 16 hex of
// sha256(normcase(abspath(dataDir)))>`; the key itself is the ASCII
// Fernet token.
//
// Layout per backend (mirrors the keyring backends in
// `.venv/Lib/site-packages/keyring/backends/`, no keyring dependency):
// * Windows (`Windows.py`): `WinVaultKeyring` ported line by line in
//   `win_credentials.dart` (service target, compound `<user>@<service>`
//   re-save on collisions, delete only where `UserName` matches).
// * macOS (`macOS/__init__.py`): generic-password item, service
//   `Strakalari` (`kSecService`), account = entry (`kSecAccount`).
//   Reached through the `security` CLI (same Keychain, same item),
//   so no Swift channel is needed.
// * Linux (`SecretService.py` / `libsecret.py`): default collection,
//   attributes `{service, username, application: 'Python keyring
//   library'}`, label `Password for '<user>' on '<service>'`.
//   Reached through `secret-tool` (same Secret Service DB, same
//   attributes).
//
// Failure contract (matches core `secret_store`):
// * Backend absent (`security`/`secret-tool` missing, Win32 call
//   unavailable) → throw [KeyStoreMissing]: the file fallback applies.
// * Backend refused (locked collection, denied Keychain access, the
//   store API failed) → throw [KeyStoreUnavailable]: the key must NOT
//   be regenerated, so the wizard asks for the passwords again (the
//   documented fallback), exactly like Python.
//
// macOS/Linux parts are written but UNVERIFIED (no Mac/Linux run here).
import 'dart:io';

import 'package:strakalari_core/strakalari_core.dart';

import 'win_credentials.dart';

/// Linux Secret Service application attribute keyring always sets.
const String _linuxApplication = 'Python keyring library';

/// Label keyring gives the Secret Service item.
String _linuxLabel(String service, String username) =>
    "Password for '$username' on '$service'";

/// The desktop OS credential store, reading Python keyring's entries.
class DesktopKeyStore implements KeyStore {
  /// When false, CLI backends are treated as absent (tests).
  final bool allowCliBackends;

  /// The Credential Manager calls (a fake table in tests).
  final WinCredApi? windowsApi;

  const DesktopKeyStore({this.allowCliBackends = true, this.windowsApi});

  /// Windows when [windowsApi] is given (tests) or the host is Windows.
  bool get _isWindows => windowsApi != null || Platform.isWindows;

  WinCredApi get _win => windowsApi ?? Win32CredApi();

  @override
  String? getPassword(String service, String account) {
    if (_isWindows) return _getWindows(_win, service, account);
    if (Platform.isMacOS) return _getMacos(service, account, allowCli: allowCliBackends);
    if (Platform.isLinux) return _getLinux(service, account, allowCli: allowCliBackends);
    throw KeyStoreMissing('No credential store backend on this OS.');
  }

  @override
  void setPassword(String service, String account, String password) {
    if (_isWindows) {
      _setWindows(_win, service, account, password);
      return;
    }
    if (Platform.isMacOS) {
      _setMacos(service, account, password, allowCli: allowCliBackends);
      return;
    }
    if (Platform.isLinux) {
      _setLinux(service, account, password, allowCli: allowCliBackends);
      return;
    }
    throw KeyStoreMissing('No credential store backend on this OS.');
  }

  @override
  void deletePassword(String service, String account) {
    if (_isWindows) {
      _deleteWindows(_win, service, account);
      return;
    }
    if (Platform.isMacOS) {
      _deleteMacos(service, account, allowCli: allowCliBackends);
      return;
    }
    if (Platform.isLinux) {
      _deleteLinux(service, account, allowCli: allowCliBackends);
      return;
    }
    throw KeyStoreMissing('No credential store backend on this OS.');
  }
}

// -- Windows -------------------------------------------------------------
// keyring's `WinVaultKeyring`, ported in `win_credentials.dart`.

String? _getWindows(WinCredApi api, String service, String account) {
  try {
    return WinVaultKeyring(api).getPassword(service, account);
  } catch (e) {
    // Any refusal (not "not found", which is null) must never lead to a
    // new key: core turns this into KeyStoreUnavailable.
    throw KeyStoreUnavailable('Credential Manager did not answer ($e).');
  }
}

void _setWindows(WinCredApi api, String service, String account, String password) {
  try {
    WinVaultKeyring(api).setPassword(service, account, password);
  } catch (e) {
    throw KeyStoreUnavailable('Credential Manager refused the write ($e).');
  }
}

void _deleteWindows(WinCredApi api, String service, String account) {
  try {
    // False (nothing held this entry) is keyring's PasswordDeleteError,
    // which `forget_key` treats as nothing left behind: silent.
    WinVaultKeyring(api).deletePassword(service, account);
  } catch (e) {
    throw KeyStoreUnavailable('Credential Manager did not delete the key ($e).');
  }
}

// -- macOS ---------------------------------------------------------------
// UNVERIFIED: same Keychain item keyring uses, via the `security` CLI.

String? _getMacos(String service, String account, {required bool allowCli}) {
  final exe = _which('security');
  if (exe == null || !allowCli) {
    throw KeyStoreMissing('The `security` CLI is not available.');
  }
  try {
    final result = Process.runSync(
      exe,
      ['find-generic-password', '-s', service, '-a', account, '-w'],
    );
    if (result.exitCode == 0) {
      return (result.stdout as String).trimRight();
    }
    if (result.exitCode == 44 /* not found */) return null;
    throw KeyStoreUnavailable(
      'Keychain refused access (security exit ${result.exitCode}).',
    );
  } catch (e) {
    if (e is KeyStoreMissing || e is KeyStoreUnavailable) rethrow;
    throw KeyStoreUnavailable('Keychain did not answer ($e).');
  }
}

void _setMacos(String service, String account, String password,
    {required bool allowCli}) {
  final exe = _which('security');
  if (exe == null || !allowCli) {
    throw KeyStoreMissing('The `security` CLI is not available.');
  }
  try {
    // `-U` updates an existing item (mirrors `set_password` overwrite).
    final result = Process.runSync(
      exe,
      ['add-generic-password', '-U', '-s', service, '-a', account, '-w', password],
    );
    if (result.exitCode != 0) {
      throw KeyStoreUnavailable(
        'Keychain refused the write (security exit ${result.exitCode}).',
      );
    }
    if (_getMacos(service, account, allowCli: allowCli) != password) {
      throw KeyStoreUnavailable(
        'Keychain did not return the stored key.',
      );
    }
  } on KeyStoreMissing {
    rethrow;
  } on KeyStoreUnavailable {
    rethrow;
  } catch (e) {
    throw KeyStoreUnavailable('Keychain did not answer ($e).');
  }
}

void _deleteMacos(String service, String account, {required bool allowCli}) {
  final exe = _which('security');
  if (exe == null || !allowCli) return;
  try {
    Process.runSync(
      exe,
      ['delete-generic-password', '-s', service, '-a', account],
    );
  } catch (_) {}
}

// -- Linux ---------------------------------------------------------------
// UNVERIFIED: same Secret Service attributes keyring uses, via
// `secret-tool`. Absence of `secret-tool` (headless servers, minimal
// installs) → [KeyStoreMissing] → the `secret.key` file fallback.

String? _getLinux(String service, String account, {required bool allowCli}) {
  final exe = _which('secret-tool');
  if (exe == null || !allowCli) {
    throw KeyStoreMissing('No Secret Service client (`secret-tool`).');
  }
  try {
    final result = Process.runSync(exe, [
      'lookup',
      'service',
      service,
      'username',
      account,
      'application',
      _linuxApplication,
    ]);
    if (result.exitCode == 0) {
      final out = (result.stdout as String).trimRight();
      return out.isEmpty ? null : out;
    }
    if (result.exitCode == 1) return null; // No matching item.
    throw KeyStoreUnavailable(
      'Secret Service refused access (secret-tool exit ${result.exitCode}).',
    );
  } catch (e) {
    if (e is KeyStoreMissing || e is KeyStoreUnavailable) rethrow;
    throw KeyStoreUnavailable('Secret Service did not answer ($e).');
  }
}

void _setLinux(String service, String account, String password,
    {required bool allowCli}) {
  final exe = _which('secret-tool');
  if (exe == null || !allowCli) {
    throw KeyStoreMissing('No Secret Service client (`secret-tool`).');
  }
  try {
    // `secret-tool store` reads the secret from stdin only, and the
    // `KeyStore` interface is synchronous (`Process.runSync` takes no
    // stdin), so the password travels in a same-user-only environment
    // variable through a small `sh` pipe — never on the command line.
    final store = Process.runSync(
      'sh',
      [
        '-c',
        'printf "%s" "\$STRAKALARI_SECRET" | secret-tool store '
            '--label="\$STRAKALARI_LABEL" service "\$STRAKALARI_SERVICE" '
            'username "\$STRAKALARI_USER" application "\$STRAKALARI_APP"',
      ],
      environment: {
        'STRAKALARI_SECRET': password,
        'STRAKALARI_LABEL': _linuxLabel(service, account),
        'STRAKALARI_SERVICE': service,
        'STRAKALARI_USER': account,
        'STRAKALARI_APP': _linuxApplication,
      },
    );
    if (store.exitCode != 0) {
      throw KeyStoreUnavailable(
        'Secret Service refused the write (secret-tool exit ${store.exitCode}).',
      );
    }
    if (_getLinux(service, account, allowCli: allowCli) != password) {
      throw KeyStoreUnavailable(
        'Secret Service did not return the stored key.',
      );
    }
  } on KeyStoreMissing {
    rethrow;
  } on KeyStoreUnavailable {
    rethrow;
  } catch (e) {
    throw KeyStoreUnavailable('Secret Service did not answer ($e).');
  }
}

void _deleteLinux(String service, String account, {required bool allowCli}) {
  final exe = _which('secret-tool');
  if (exe == null || !allowCli) return;
  try {
    Process.runSync(exe, [
      'clear',
      'service',
      service,
      'username',
      account,
      'application',
      _linuxApplication,
    ]);
  } catch (_) {}
}

// -- helpers ---------------------------------------------------------------

String? _which(String exe) {
  final pathSep = Platform.isWindows ? ';' : ':';
  final path = Platform.environment['PATH'] ?? '';
  final names =
      Platform.isWindows ? <String>[exe, '$exe.exe'] : <String>[exe];
  for (final dir in path.split(pathSep)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final candidate =
          '$dir${Platform.pathSeparator}$name';
      try {
        if (File(candidate).existsSync()) return candidate;
      } catch (_) {}
    }
  }
  return null;
}
