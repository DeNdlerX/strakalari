// Where the Fernet key that encrypts stored passwords lives.
//
// Port of strakalari/core/secret_store.py. Preferred: the OS credential
// store via [keyStoreBackend]. Fallback: `secret.key` in the data dir.
// The store entry is bound to the data dir path, so separate installs
// keep separate keys. Android keeps the key wrapped by the Keystore.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../platform/android_bridge.dart';
import '../platform/keystore.dart';
import '../platform/packaging.dart';
import 'fernet.dart';
import 'helpers.dart';

/// Credential-store service name.
const String serviceName = 'Strakalari';

/// Key file name (fallback when no usable credential store exists).
const String keyFile = 'secret.key';

/// The key, encrypted by the Android Keystore (base64 text).
const String wrappedFile = 'secret.key.wrapped';

/// In-process cache: one key per data dir.
final Map<String, Uint8List> _cache = {};

/// True when the `STRAKALARI_NO_KEYRING` escape hatch is active.
bool get _noKeyring {
  final value = (getenv('STRAKALARI_NO_KEYRING') ?? '').trim();
  return value.isNotEmpty && value != '0';
}

/// Test-only opt-in to the `secret.key` file fallback when
/// [keyStoreBackend] is null and `STRAKALARI_NO_KEYRING` is not set.
///
/// Desktop entry points must register a [KeyStore] or set
/// `STRAKALARI_NO_KEYRING=1`; forgetting to do so throws
/// [KeyStoreUnavailable] instead of silently creating a `secret.key` that
/// would later shadow the OS credential store.
bool allowMissingKeyStoreForTesting = false;

KeyStore? _desktopBackend() {
  if (_noKeyring || allowMissingKeyStoreForTesting) return null;
  final backend = keyStoreBackend;
  if (backend != null) return backend;
  if (isMobile()) return null;
  throw const KeyStoreUnavailable(
    'No OS credential store backend registered '
    '(set keyStoreBackend or STRAKALARI_NO_KEYRING=1).',
  );
}

/// Store entry bound to the data dir path.
///
/// Mirrors `secret_store._entry_name`: `normcase(abspath(data_dir))`.
/// [windows] overrides the host OS for cross-platform parity tests on
/// already-absolute paths.
String entryName(String dataDir, {bool? windows}) {
  var path = windows == null
      ? p.normalize(p.absolute(dataDir))
      : (windows ? p.windows : p.posix).normalize(dataDir);
  if (windows ?? Platform.isWindows) path = path.toLowerCase();
  final digest = sha256.convert(utf8.encode(path)).toString();
  return 'fernet-key:${digest.substring(0, 16)}';
}

/// The Fernet key for [dataDir] (created on first use).
Uint8List getKey(String dataDir) {
  final cached = _cache[dataDir];
  if (cached != null && cached.isNotEmpty) return cached;
  // The tray and the window may both start on a fresh install:
  // without the lock each could create (and store) its own key.
  final lock = InterProcessLock(p.join(dataDir, '$keyFile.lock'));
  final locked = lock.acquire(timeoutS: 10);
  try {
    final key = _loadOrCreate(dataDir);
    _cache[dataDir] = key;
    return key;
  } finally {
    if (locked) lock.release();
  }
}

/// The Keystore backend inside the Android app, else null.
AndroidKeystoreBridge? _androidKeystore() {
  if (_noKeyring) return null;
  final bridge = androidKeystoreBridge;
  return (bridge != null && bridge.available) ? bridge : null;
}

/// Android: unwrap `secret.key.wrapped`, or create / migrate it.
Uint8List _androidLoadOrCreate(
    String dataDir, Uint8List? fileKey, AndroidKeystoreBridge android) {
  final path = p.join(dataDir, keyFile);
  final wrappedPath = p.join(dataDir, wrappedFile);
  final wrapped = _readFile(wrappedPath);
  if (wrapped != null) {
    Uint8List? key;
    try {
      key = android.unwrap(base64.decode(ascii.decode(wrapped)));
    } catch (e) {
      print('Warning: could not unlock $wrappedFile '
          '(${e.runtimeType}: $e); stored passwords must be entered again.');
      quarantineCorruptFile(wrappedPath);
      key = null;
    }
    if (key != null && Fernet.isValidKeyBytes(key)) {
      if (fileKey != null && !_bytesEqual(fileKey, key)) {
        // As with the keyring: the file encrypted what is in
        // config.json now. Never guess, keep using it.
        print('Warning: $keyFile differs from $wrappedFile; using the file.');
        return fileKey;
      }
      if (fileKey != null) _removeFile(path); // Leftover of a migration.
      return key;
    }
  }
  final key = fileKey ?? Fernet.generateKey();
  try {
    final blob = android.wrap(key);
    if (!_bytesEqual(android.unwrap(blob), key)) {
      throw const FormatException('the wrapped key does not read back');
    }
    _writeFile(wrappedPath, ascii.encode(base64.encode(blob)));
  } catch (e) {
    print('Warning: Android Keystore unavailable '
        '(${e.runtimeType}: $e); keeping $keyFile.');
    if (fileKey == null) _writeFile(path, key);
    return key;
  }
  if (fileKey != null) _removeFile(path);
  print('Info: password key ${fileKey != null ? 'moved into' : 'created in'} '
      'the Android Keystore.');
  return key;
}

Uint8List _loadOrCreate(String dataDir) {
  final path = p.join(dataDir, keyFile);
  Uint8List? fileKey = _readFile(path);
  if (fileKey != null && !Fernet.isValidKeyBytes(fileKey)) {
    // Empty/corrupt (crash during write): keep the bytes for debugging.
    quarantineCorruptFile(path);
    fileKey = null;
  }
  final android = _androidKeystore();
  if (android != null) return _androidLoadOrCreate(dataDir, fileKey, android);
  final backend = _desktopBackend();
  if (backend == null) {
    if (fileKey == null) {
      fileKey = Fernet.generateKey();
      _writeFile(path, fileKey);
    }
    return fileKey;
  }
  final name = entryName(dataDir);
  Uint8List? stored;
  try {
    stored = _fromStore(backend, name);
  } on KeyStoreUnavailable {
    if (fileKey != null) return fileKey; // Not migrated yet: file is truth.
    rethrow;
  }
  if (stored != null && Fernet.isValidKeyBytes(stored)) {
    if (fileKey != null) {
      if (!_bytesEqual(fileKey, stored)) {
        // Two different keys: the file one encrypted whatever is in
        // config.json now (e.g. restored from a backup). Never guess —
        // keep using the file, leave the store alone.
        print('Warning: $keyFile differs from the key in the OS credential '
            'store; using the file.');
        return fileKey;
      }
      _removeFile(path); // Leftover of an interrupted migration.
    }
    return stored;
  }
  final key = fileKey ?? Fernet.generateKey();
  if (_toStore(backend, name, key)) {
    if (fileKey != null) _removeFile(path);
    return key;
  }
  if (fileKey == null) _writeFile(path, key);
  return key;
}

Uint8List? _readFile(String path) {
  try {
    final key = File(path).readAsBytesSync();
    final trimmed = _trimAscii(key);
    return trimmed.isEmpty ? null : Uint8List.fromList(trimmed);
  } on FileSystemException {
    return null;
  }
}

List<int> _trimAscii(Uint8List bytes) {
  var start = 0;
  var end = bytes.length;
  while (start < end && bytes[start] <= 32) {
    start++;
  }
  while (end > start && bytes[end - 1] <= 32) {
    end--;
  }
  return bytes.sublist(start, end);
}

void _writeFile(String path, Uint8List key) {
  final tmpPath = '$path.tmp-$pid';
  try {
    File(tmpPath).writeAsBytesSync(key, flush: true);
    // `os.replace`: never deletes the target first.
    File(tmpPath).renameSync(path);
  } finally {
    try {
      if (File(tmpPath).existsSync()) File(tmpPath).deleteSync();
    } on FileSystemException {
      // Nothing to clean.
    }
  }
  _restrictPermissions(path);
}

/// Best-effort `chmod 600` (mirrors the `os.chmod` try/except: Windows
/// ACLs make it unnecessary there, and the data dir is per user anyway).
void _restrictPermissions(String path) {
  if (Platform.isWindows) return;
  try {
    Process.runSync('chmod', ['600', path]);
  } catch (_) {
    // Best effort only.
  }
}

/// Deletes the key file after overwriting it (best effort).
void _removeFile(String path) {
  try {
    final size = File(path).lengthSync();
    final handle = File(path).openSync(mode: FileMode.write);
    try {
      handle.writeFromSync(List<int>.filled(size, 0));
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    // Fall through to deletion.
  }
  try {
    File(path).deleteSync();
  } on FileSystemException catch (e) {
    print('Warning: could not delete $path after moving the key to the '
        'credential store: $e');
  }
}

Uint8List? _fromStore(KeyStore backend, String name) {
  try {
    final value = backend.getPassword(serviceName, name);
    return value == null ? null : Uint8List.fromList(ascii.encode(value));
  } on KeyStoreMissing {
    return null;
  } catch (e) {
    throw KeyStoreUnavailable(
        'The OS credential store did not answer (${e.runtimeType}: $e).');
  }
}

/// Stores and reads [key] back. True only when the round trip holds.
bool _toStore(KeyStore backend, String name, Uint8List key) {
  try {
    backend.setPassword(serviceName, name, ascii.decode(key));
    return backend.getPassword(serviceName, name) == ascii.decode(key);
  } catch (e) {
    print('Warning: could not save the key to the OS credential store '
        '(${e.runtimeType}: $e); keeping $keyFile.');
    return false;
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Gives [newDir] the key of [oldDir] (the data dir moved).
///
/// Only for a [newDir] without its own config: whatever key it has is
/// replaced. The old entry stays (the old location may still be used).
/// True when done or when [oldDir] has no key at all. Never raises.
bool carryKey(String oldDir, String newDir) {
  final dest = p.join(newDir, keyFile);
  try {
    Uint8List? key = _readFile(p.join(oldDir, keyFile));
    final backend = _desktopBackend();
    if (!Fernet.isValidKeyBytes(key)) {
      key = backend == null ? null : _fromStore(backend, entryName(oldDir));
    }
    if (!Fernet.isValidKeyBytes(key)) return true; // Nothing was encrypted.
    if (backend != null && _toStore(backend, entryName(newDir), key!)) {
      if (File(dest).existsSync()) {
        _removeFile(dest); // A stale key would shadow the carried one.
      }
    } else {
      _writeFile(dest, key!);
    }
  } on KeyStoreUnavailable catch (e) {
    print('Warning: could not carry the password key to $newDir: $e');
    return false;
  } on FileSystemException catch (e) {
    // Python's `OSError`: the key file IO failed.
    print('Warning: could not carry the password key to $newDir: $e');
    return false;
  }
  _cache.remove(newDir);
  return true;
}

/// Deletes [dataDir]'s key from the OS credential store and disk.
///
/// Used by the uninstaller's "remove all user data". True when nothing
/// is left behind. Never raises.
bool forgetKey(String dataDir) {
  var ok = true;
  final backend = _desktopBackend();
  if (backend != null) {
    try {
      backend.deletePassword(serviceName, entryName(dataDir));
    } on KeyStoreMissing {
      // Missing entries are silent.
    } catch (_) {
      ok = false;
    }
  }
  for (final name in [keyFile, wrappedFile]) {
    final path = p.join(dataDir, name);
    if (File(path).existsSync()) {
      _removeFile(path);
      ok = ok && !File(path).existsSync();
    }
  }
  _cache.remove(dataDir);
  return ok;
}

/// `"keyring"`, `"keystore"` (Android) or `"file"` — where the key
/// currently lives (for diagnostics).
String storageLocation(String dataDir) {
  if (File(p.join(dataDir, keyFile)).existsSync()) return 'file';
  if (File(p.join(dataDir, wrappedFile)).existsSync()) return 'keystore';
  final backend = _desktopBackend();
  return backend != null ? 'keyring' : 'file';
}

/// Drops the in-process key cache (tests).
void clearKeyCache() {
  _cache.clear();
}
