// Windows Credential Manager the way Python's `keyring` uses it.
//
// Line-by-line port of `WinVaultKeyring` (`keyring/backends/Windows.py`):
// passwords live under the service name (`Strakalari`) unless another
// entry already sits there under a different user name; `set_password`
// then first re-saves that entry as `<its user>@Strakalari` and only then
// writes the new one. Reads try the service name and fall back to the
// compound name; deletes remove only targets whose `UserName` is the
// entry. One Windows user normally has several data folders (installer,
// Store package, portable copy, source run), each with its own entry, so
// skipping any of these steps destroys another folder's key (C-B2).
//
// The Win32 calls sit behind [WinCredApi] so a fake credential table can
// test the logic; [Win32CredApi] is the real one.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart'
    show CREDENTIAL, CRED_PERSIST_ENTERPRISE, CRED_TYPE_GENERIC;

/// `ERROR_NOT_FOUND`: the only CredRead/CredDelete error keyring ignores.
const int errorNotFound = 1168;

/// keyring's `Comment` on every credential it writes.
const String keyringComment = 'Stored using python-keyring';

/// One generic credential (the fields keyring reads).
class WinCredential {
  final String userName;
  final Uint8List blob;
  const WinCredential(this.userName, this.blob);
}

/// A failed Win32 credential call (`pywintypes.error`).
class WinCredError implements Exception {
  final int code;
  final String function;
  const WinCredError(this.code, this.function);

  @override
  String toString() => 'WinCredError: $function failed (Win32 error $code)';
}

/// The three Credential Manager calls keyring makes.
abstract interface class WinCredApi {
  /// `CredRead`; null only for `ERROR_NOT_FOUND`, every other failure
  /// throws [WinCredError].
  WinCredential? read(String target);

  /// `CredWrite` of a generic credential (`CRED_PERSIST_ENTERPRISE`).
  void write(String target, String userName, Uint8List blob, String comment);

  /// `CredDelete`; throws [WinCredError] on any failure (including
  /// `ERROR_NOT_FOUND`, which the caller filters like keyring does).
  void delete(String target);
}

String compoundName(String username, String service) => '$username@$service';

/// `DecodingCredential.value`: UTF-16 first, then UTF-8 (both strict).
String decodeCredentialBlob(Uint8List blob) {
  try {
    return _decodeUtf16(blob);
  } on FormatException {
    return utf8.decode(blob); // throws FormatException like UnicodeDecodeError
  }
}

/// Python's `bytes.decode('utf-16')`: an optional BOM picks the byte
/// order (default little endian), odd lengths and lone surrogates fail.
String _decodeUtf16(Uint8List bytes) {
  var start = 0;
  var bigEndian = false;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      start = 2;
    } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      start = 2;
      bigEndian = true;
    }
  }
  if ((bytes.length - start).isOdd) {
    throw const FormatException('truncated UTF-16 data');
  }
  final units = <int>[];
  for (var i = start; i < bytes.length; i += 2) {
    units.add(bigEndian ? (bytes[i] << 8) | bytes[i + 1] : bytes[i] | (bytes[i + 1] << 8));
  }
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xd800 && u <= 0xdbff) {
      if (i + 1 < units.length && units[i + 1] >= 0xdc00 && units[i + 1] <= 0xdfff) {
        i++;
        continue;
      }
      throw const FormatException('illegal UTF-16 surrogate');
    }
    if (u >= 0xdc00 && u <= 0xdfff) {
      throw const FormatException('illegal UTF-16 surrogate');
    }
  }
  return String.fromCharCodes(units);
}

/// keyring writes `CredentialBlob=password` (a str): UTF-16LE, no BOM.
Uint8List encodeCredentialBlob(String text) {
  final out = Uint8List(text.length * 2);
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    out[2 * i] = unit & 0xff;
    out[2 * i + 1] = unit >> 8;
  }
  return out;
}

/// `WinVaultKeyring` on top of [api].
class WinVaultKeyring {
  final WinCredApi api;
  const WinVaultKeyring(this.api);

  /// `get_password`.
  String? getPassword(String service, String username) {
    final res = _resolveCredential(service, username);
    return res == null ? null : decodeCredentialBlob(res.blob);
  }

  /// `_resolve_credential`.
  WinCredential? _resolveCredential(String service, String username) {
    // First attempt to get the password under the service name.
    var res = api.read(service);
    if (res == null || (username.isNotEmpty && res.userName != username)) {
      // It wasn't found, so attempt to get it with the compound name.
      res = api.read(compoundName(username, service));
    }
    return res;
  }

  /// `set_password`.
  void setPassword(String service, String username, String password) {
    final existing = api.read(service);
    if (existing != null) {
      // Re-save the existing password using a compound target.
      final existingUsername = existing.userName;
      _setPassword(compoundName(existingUsername, service), existingUsername,
          decodeCredentialBlob(existing.blob));
    }
    _setPassword(service, username, password);
  }

  void _setPassword(String target, String username, String password) {
    api.write(target, username, encodeCredentialBlob(password), keyringComment);
  }

  /// `delete_password`. Returns false where keyring raises
  /// `PasswordDeleteError` (no target held this entry).
  bool deletePassword(String service, String username) {
    final compound = compoundName(username, service);
    var deleted = false;
    for (final target in [service, compound]) {
      final existing = api.read(target);
      if (existing != null && existing.userName == username) {
        deleted = true;
        _deletePassword(target);
      }
    }
    return deleted;
  }

  void _deletePassword(String target) {
    try {
      api.delete(target);
    } on WinCredError catch (e) {
      if (e.code == errorNotFound) return; // not found
      rethrow;
    }
  }
}

// -- the real Win32 calls ----------------------------------------------------

typedef _CredReadC = Int32 Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Pointer<CREDENTIAL>>);
typedef _CredReadDart = int Function(
    Pointer<Utf16>, int, int, Pointer<Pointer<CREDENTIAL>>);
typedef _CredWriteC = Int32 Function(Pointer<CREDENTIAL>, Uint32);
typedef _CredWriteDart = int Function(Pointer<CREDENTIAL>, int);
typedef _CredDeleteC = Int32 Function(Pointer<Utf16>, Uint32, Uint32);
typedef _CredDeleteDart = int Function(Pointer<Utf16>, int, int);
typedef _CredFreeC = Void Function(Pointer<Void>);
typedef _CredFreeDart = void Function(Pointer<Void>);
typedef _GetLastErrorC = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// Credential Manager through FFI. Every call and the `GetLastError`
/// right after it are leaf calls, so the Dart VM cannot run anything in
/// between that would overwrite the thread's last-error value.
class Win32CredApi implements WinCredApi {
  Win32CredApi();

  static final DynamicLibrary _advapi = DynamicLibrary.open('advapi32.dll');
  static final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');
  static final _credRead =
      _advapi.lookupFunction<_CredReadC, _CredReadDart>('CredReadW', isLeaf: true);
  static final _credWrite =
      _advapi.lookupFunction<_CredWriteC, _CredWriteDart>('CredWriteW', isLeaf: true);
  static final _credDelete =
      _advapi.lookupFunction<_CredDeleteC, _CredDeleteDart>('CredDeleteW', isLeaf: true);
  static final _credFree =
      _advapi.lookupFunction<_CredFreeC, _CredFreeDart>('CredFree', isLeaf: true);
  static final _getLastError =
      _kernel.lookupFunction<_GetLastErrorC, _GetLastErrorDart>('GetLastError', isLeaf: true);

  @override
  WinCredential? read(String target) {
    return using((Arena arena) {
      final name = target.toNativeUtf16(allocator: arena);
      final out = arena<Pointer<CREDENTIAL>>();
      // Resolved before the call: a lazy lookup loads kernel32 after the
      // failure and clears the error.
      final lastError = _getLastError;
      if (_credRead(name, CRED_TYPE_GENERIC, 0, out) == 0) {
        final error = lastError();
        if (error == errorNotFound) return null;
        throw WinCredError(error, 'CredRead');
      }
      final cred = out.value;
      try {
        final userPtr = cred.ref.UserName;
        final user = userPtr == nullptr ? '' : userPtr.toDartString();
        final size = cred.ref.CredentialBlobSize;
        final blob = size == 0
            ? Uint8List(0)
            : Uint8List.fromList(cred.ref.CredentialBlob.asTypedList(size));
        return WinCredential(user, blob);
      } finally {
        _credFree(cred.cast());
      }
    });
  }

  @override
  void write(String target, String userName, Uint8List blob, String comment) {
    using((Arena arena) {
      final blobPtr = arena<Uint8>(blob.isEmpty ? 1 : blob.length);
      blobPtr.asTypedList(blob.length).setAll(0, blob);
      final cred = arena<CREDENTIAL>(); // zero-filled (calloc)
      cred.ref.Type = CRED_TYPE_GENERIC;
      cred.ref.TargetName = target.toNativeUtf16(allocator: arena);
      cred.ref.Comment = comment.toNativeUtf16(allocator: arena);
      cred.ref.CredentialBlobSize = blob.length;
      cred.ref.CredentialBlob = blobPtr;
      cred.ref.Persist = CRED_PERSIST_ENTERPRISE;
      cred.ref.UserName = userName.toNativeUtf16(allocator: arena);
      final lastError = _getLastError;
      if (_credWrite(cred, 0) == 0) {
        throw WinCredError(lastError(), 'CredWrite');
      }
    });
  }

  @override
  void delete(String target) {
    using((Arena arena) {
      final name = target.toNativeUtf16(allocator: arena);
      final lastError = _getLastError;
      if (_credDelete(name, CRED_TYPE_GENERIC, 0) == 0) {
        throw WinCredError(lastError(), 'CredDelete');
      }
    });
  }
}
