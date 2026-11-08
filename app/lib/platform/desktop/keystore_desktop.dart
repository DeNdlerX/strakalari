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
// * Windows (`Windows.py`): `CredRead(TargetName=service)` first, and
//   when the stored `UserName` differs, the compound name
//   `<username>@<service>`. Blobs decode UTF-16 first, then UTF-8
//   (`DecodingCredential.value`); writes are UTF-16LE. `UserName` is
//   the entry name, persist is `CRED_PERSIST_ENTERPRISE`.
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
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:strakalari_core/strakalari_core.dart';
import 'package:win32/win32.dart';

/// Linux Secret Service application attribute keyring always sets.
const String _linuxApplication = 'Python keyring library';

/// Label keyring gives the Secret Service item.
String _linuxLabel(String service, String username) =>
    "Password for '$username' on '$service'";

/// Compound Windows target keyring falls back to on collisions.
String _compoundTarget(String username, String service) => '$username@$service';

/// The desktop OS credential store, reading Python keyring's entries.
class DesktopKeyStore implements KeyStore {
  /// When false, CLI backends are treated as absent (tests).
  final bool allowCliBackends;

  const DesktopKeyStore({this.allowCliBackends = true});

  @override
  String? getPassword(String service, String account) {
    if (Platform.isWindows) return _getWindows(service, account);
    if (Platform.isMacOS) return _getMacos(service, account, allowCli: allowCliBackends);
    if (Platform.isLinux) return _getLinux(service, account, allowCli: allowCliBackends);
    throw KeyStoreMissing('No credential store backend on this OS.');
  }

  @override
  void setPassword(String service, String account, String password) {
    if (Platform.isWindows) {
      _setWindows(service, account, password);
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
    if (Platform.isWindows) {
      _deleteWindows(service, account);
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

String? _readCredentialBlob(Pointer<CREDENTIAL> cred) {
  final size = cred.ref.CredentialBlobSize;
  if (size == 0) return null;
  final bytes = cred.ref.CredentialBlob.asTypedList(size);
  // `DecodingCredential.value`: UTF-16 first, then UTF-8.
  try {
    final units = Uint16List.sublistView(bytes, 0, size & ~1);
    var text = String.fromCharCodes(units);
    // Strip one trailing NUL the API may include.
    if (text.endsWith('\x00')) {
      text = text.substring(0, text.length - 1);
    }
    // A lone-surrogate failure means "not UTF-16": fall through.
    if (!_hasLoneSurrogates(text)) return text;
  } catch (_) {}
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

bool _hasLoneSurrogates(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdfff) {
      final high = unit <= 0xdbff;
      final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : -1;
      if (high && next >= 0xdc00 && next <= 0xdfff) {
        i++;
        continue;
      }
      return true;
    }
  }
  return false;
}

String? _credReadTarget(String target) {
  return using((Arena arena) {
    final name = target.toNativeUtf16(allocator: arena);
    final out = arena<Pointer<CREDENTIAL>>();
    final ok = CredRead(name, CRED_TYPE_GENERIC, 0, out);
    if (ok == 0) return null;
    try {
      final cred = out.value;
      final user = cred.ref.UserName.toDartString();
      final value = _readCredentialBlob(cred);
      if (value == null) return null;
      return '$user\x00$value';
    } finally {
      CredFree(out.value);
    }
  });
}

String? _getWindows(String service, String account) {
  try {
    final direct = _credReadTarget(service);
    if (direct != null) {
      final sep = direct.indexOf('\x00');
      final user = direct.substring(0, sep);
      final value = direct.substring(sep + 1);
      // First attempt under the service name — unless it belongs to
      // a different user, in which case the compound name holds ours.
      if (user.isEmpty || user == account) return value;
    }
    final compound = _credReadTarget(_compoundTarget(account, service));
    if (compound == null) {
      // Distinguish "no entry" (missing → file fallback) from
      // "the store refused" (unavailable → wizard re-prompt).
      final error = GetLastError();
      if (error != 0 && error != 1168 /* ERROR_NOT_FOUND */) {
        throw KeyStoreUnavailable(
          'Credential Manager did not answer (Win32 error $error).',
        );
      }
      return null;
    }
    return compound.substring(compound.indexOf('\x00') + 1);
  } on KeyStoreMissing {
    rethrow;
  } on KeyStoreUnavailable {
    rethrow;
  } catch (e) {
    throw KeyStoreUnavailable('Credential Manager did not answer ($e).');
  }
}

void _setWindows(String service, String account, String password) {
  try {
    final ok = using((Arena arena) {
      final blob = password.codeUnits;
      final blobPtr = arena<Uint16>(blob.length);
      blobPtr.asTypedList(blob.length).setAll(0, blob);
      final cred = arena<CREDENTIAL>();
      cred.ref.Type = CRED_TYPE_GENERIC;
      cred.ref.TargetName = service.toNativeUtf16(allocator: arena);
      cred.ref.Comment = nullptr.cast();
      cred.ref.CredentialBlobSize = blob.length * 2;
      cred.ref.CredentialBlob = blobPtr.cast();
      cred.ref.Persist = CRED_PERSIST_ENTERPRISE;
      cred.ref.AttributeCount = 0;
      cred.ref.Attributes = nullptr.cast();
      cred.ref.TargetAlias = nullptr.cast();
      cred.ref.UserName = account.toNativeUtf16(allocator: arena);
      return CredWrite(cred, 0) != 0;
    });
    if (!ok) {
      throw KeyStoreUnavailable(
        'Credential Manager refused the write (Win32 error ${GetLastError()}).',
      );
    }
    // Read back: only a round trip counts (mirrors `_to_store`).
    if (_getWindows(service, account) != password) {
      throw KeyStoreUnavailable(
        'Credential Manager did not return the stored key.',
      );
    }
  } on KeyStoreUnavailable {
    rethrow;
  } catch (e) {
    throw KeyStoreUnavailable('Credential Manager did not answer ($e).');
  }
}

void _deleteWindows(String service, String account) {
  try {
    using((Arena arena) {
      CredDelete(
        service.toNativeUtf16(allocator: arena),
        CRED_TYPE_GENERIC,
        0,
      );
      CredDelete(
        _compoundTarget(account, service).toNativeUtf16(allocator: arena),
        CRED_TYPE_GENERIC,
        0,
      );
    });
  } catch (_) {
    // Missing entries are silent (matches `delete_password`).
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
