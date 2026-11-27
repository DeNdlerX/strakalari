// Android Keystore backend for the password-encryption key.
//
// The Keystore crypto itself runs in Java (`StrakalariChannel`: alias
// `strakalari-secret-key`, AES/GCM/NoPadding, 12-byte IV prefix — identical
// to `core/android.py`). The catch is that core's `AndroidKeystoreBridge`
// is synchronous (like pyjnius was) while a MethodChannel is async, so this
// layer warms keys via async MethodChannel calls and serves core from memory:
//
//   await warmAndroidKeystoreAll(rootDir, accountIds); // UI startup + headless
//   await ensureWarmed(accountDir);                    // before any account use
//
// The warm-up replicates core's `_androidLoadOrCreate` step for step
// (unwrap `secret.key.wrapped`, migrate a plain `secret.key`, create,
// quarantine on a lost key with plain-file fallback), so core's following
// synchronous pass sees settled files and returns the same key. The
// in-memory bridge holds a map of warmed `(key, blob)` pairs (one per folder)
// and refuses anything not warmed, so an un-warmed or changed key still fails
// safe (never guessed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'android_channel.dart';

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String _dirKey(String dir) {
  final norm = resolvePath('.', dir);
  return Platform.isWindows ? norm.toLowerCase() : norm;
}

Uint8List? _readTrimmed(String path) {
  try {
    final raw = File(path).readAsBytesSync();
    var start = 0;
    var end = raw.length;
    while (start < end && raw[start] <= 32) {
      start++;
    }
    while (end > start && raw[end - 1] <= 32) {
      end--;
    }
    final out = raw.sublist(start, end);
    return out.isEmpty ? null : Uint8List.fromList(out);
  } on FileSystemException {
    return null;
  }
}

/// The warmed bridge: holds warmed `(key, blob)` pairs per directory and
/// refuses any key or blob not in the map (§5.3).
///
/// [blob] is what the Keystore answered (the raw bytes, not the base64
/// text of `secret.key.wrapped`): core decodes the file before it calls
/// [unwrap] and encodes [wrap]'s answer itself. A null [blob] means the
/// Keystore was unavailable at warm-up: [wrap] refuses, so core keeps the
/// plain `secret.key` exactly like Python does when the Keystore fails.
class WarmedAndroidKeystore implements AndroidKeystoreBridge {
  final Map<String, ({Uint8List key, Uint8List? blob})> _entries;

  /// Single-pair constructor kept for existing callers and unit tests.
  WarmedAndroidKeystore(Uint8List key, Uint8List? blob)
      : _entries = {
          '': (key: Uint8List.fromList(key), blob: blob == null ? null : Uint8List.fromList(blob)),
        };

  /// Multi-directory bridge used in production (root + every account folder).
  WarmedAndroidKeystore.multi() : _entries = {};

  /// Registers or replaces the warmed pair for [dir].
  void addEntry(String dir, Uint8List key, Uint8List? blob) {
    _entries[_dirKey(dir)] = (
      key: Uint8List.fromList(key),
      blob: blob == null ? null : Uint8List.fromList(blob),
    );
  }

  /// True when [dir] already has a warmed entry in this bridge.
  bool hasEntry(String dir) => _entries.containsKey(_dirKey(dir));

  /// Drops [dir]'s warmed entry (called by `forgetKey` on account delete).
  void removeEntry(String dir) {
    _entries.remove(_dirKey(dir));
  }

  /// Number of warmed directory entries currently held.
  int get entryCount => _entries.length;

  @override
  bool get available => true;

  @override
  Uint8List wrap(Uint8List key) {
    for (final entry in _entries.values) {
      if (_bytesEqual(key, entry.key)) {
        final b = entry.blob;
        if (b == null) {
          throw const KeyStoreUnavailable(
              'The Android Keystore did not answer.');
        }
        return Uint8List.fromList(b);
      }
    }
    // A different or un-warmed key: refuse, like a Keystore that does not
    // answer. Core keeps the plain file then.
    throw const KeyStoreUnavailable('Key changed after the Keystore warm-up.');
  }

  @override
  Uint8List unwrap(Uint8List blob) {
    for (final entry in _entries.values) {
      final own = entry.blob;
      if (own != null && _bytesEqual(blob, own)) {
        return Uint8List.fromList(entry.key);
      }
    }
    throw const KeyStoreUnavailable('Wrapped key was not warmed.');
  }
}

WarmedAndroidKeystore _installOrReuseBridge() {
  final existing = androidKeystoreBridge;
  if (existing is WarmedAndroidKeystore) {
    onForgetKeyHook = existing.removeEntry;
    return existing;
  }
  final bridge = WarmedAndroidKeystore.multi();
  androidKeystoreBridge = bridge;
  onForgetKeyHook = bridge.removeEntry;
  return bridge;
}

Future<Uint8List> _channelWrap(AndroidChannel channel, Uint8List key) async {
  try {
    final out = await AndroidChannel.channel
        .invokeMethod<Uint8List>('keystoreWrap', {'data': key});
    if (out == null) throw const FormatException('empty wrap result');
    return out;
  } on MissingPluginException {
    throw const KeyStoreMissing('No Android backend.');
  } on PlatformException catch (e) {
    throw KeyStoreUnavailable('Keystore wrap failed: ${e.code}');
  }
}

/// Adopts the wrapped key another isolate just created (it may still be
/// writing it). Null when it cannot be read within a few seconds.
Future<Uint8List?> _adoptWrapped(
    AndroidChannel channel, String dataDir, String wrappedPath) async {
  for (var i = 0; i < 30; i++) {
    final wrapped = _readTrimmed(wrappedPath);
    if (wrapped != null && wrapped.isNotEmpty) {
      try {
        final blob = Uint8List.fromList(base64.decode(ascii.decode(wrapped)));
        final key = await _channelUnwrap(channel, blob);
        if (Fernet.isValidKeyBytes(key)) {
          _installOrReuseBridge().addEntry(dataDir, key, blob);
          return key;
        }
      } on FormatException {
        // Half written: read again below.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

Future<Uint8List> _channelUnwrap(
    AndroidChannel channel, Uint8List blob) async {
  try {
    final out = await AndroidChannel.channel
        .invokeMethod<Uint8List>('keystoreUnwrap', {'blob': blob});
    if (out == null) throw const FormatException('empty unwrap result');
    return out;
  } on MissingPluginException {
    throw const KeyStoreMissing('No Android backend.');
  } on PlatformException catch (e) {
    if (e.code == 'BAD_BLOB') {
      throw const FormatException('wrapped key too short');
    }
    throw KeyStoreUnavailable('Keystore unwrap failed: ${e.code}');
  }
}

/// Clean read-only unwrap of `<rootDir>/secret.key.wrapped` for the F4 one-time
/// move (§4.2 step 5–6).
///
/// Never quarantines or creates a key; returns `true` only if the wrapped blob
/// unwrapped cleanly to valid Fernet key bytes and registered in the bridge.
Future<bool> warmAndroidRootKeyClean(
  String rootDir, {
  AndroidChannel channel = const AndroidChannel(),
  @visibleForTesting bool? onAndroid,
}) async {
  if (!(onAndroid ?? Platform.isAndroid)) return true;
  final wrappedPath = resolvePath(wrappedFile, rootDir);
  final wrapped = _readTrimmed(wrappedPath);
  if (wrapped == null) return true;
  try {
    final blob = Uint8List.fromList(base64.decode(ascii.decode(wrapped)));
    final key = await _channelUnwrap(channel, blob);
    if (!Fernet.isValidKeyBytes(key)) return false;
    _installOrReuseBridge().addEntry(rootDir, key, blob);
    return true;
  } on Object {
    return false;
  }
}

/// Runs core's `_androidLoadOrCreate` lifecycle with async channel calls
/// and registers [dataDir]'s entry in the shared [WarmedAndroidKeystore].
///
/// Returns the Fernet key. Throws [KeyStoreMissing] off Android (callers
/// then skip the bridge: the plain file, like Python without pyjnius).
Future<Uint8List> warmAndroidKeystore(
  String dataDir, {
  AndroidChannel channel = const AndroidChannel(),
  @visibleForTesting bool? onAndroid,
}) async {
  if (!(onAndroid ?? Platform.isAndroid)) {
    throw const KeyStoreMissing('No Android backend.');
  }
  final plainPath = resolvePath(keyFile, dataDir);
  final wrappedPath = resolvePath(wrappedFile, dataDir);
  Uint8List? fileKey = _readTrimmed(plainPath);
  if (fileKey != null && !Fernet.isValidKeyBytes(fileKey)) {
    quarantineCorruptFile(plainPath);
    fileKey = null;
  }

  final wrapped = _readTrimmed(wrappedPath);
  if (wrapped != null) {
    Uint8List? key;
    Uint8List? blob;
    try {
      blob = Uint8List.fromList(base64.decode(ascii.decode(wrapped)));
      final unwrapped = await _channelUnwrap(channel, blob);
      if (!Fernet.isValidKeyBytes(unwrapped)) {
        throw const FormatException(
            'unwrapped bytes are not a valid Fernet key');
      }
      key = unwrapped;
    } on FormatException {
      // Corrupt blob or non-Fernet key bytes: quarantine and start over,
      // like core (stored passwords must be entered again).
      // ignore: avoid_print
      print('Warning: could not unlock $wrappedFile; '
          'stored passwords must be entered again.');
      quarantineCorruptFile(wrappedPath);
      key = null;
    }
    if (key != null) {
      if (fileKey != null && !_bytesEqual(fileKey, key)) {
        // The file encrypted what is in config.json now (e.g. restored
        // from a backup). Never guess, keep using it.
        // ignore: avoid_print
        print('Warning: $keyFile differs from $wrappedFile; using the file.');
        _installOrReuseBridge().addEntry(dataDir, key, blob);
        return fileKey;
      }
      if (fileKey != null) {
        try {
          File(plainPath).deleteSync();
        } on FileSystemException {
          // Best effort.
        }
      }
      _installOrReuseBridge().addEntry(dataDir, key, blob);
      return key;
    }
  }

  final key = fileKey ?? Fernet.generateKey();
  final Uint8List blob;
  try {
    blob = await _channelWrap(channel, key);
    if (!_bytesEqual(await _channelUnwrap(channel, blob), key)) {
      throw const FormatException('the wrapped key does not read back');
    }
    // The UI and a headless wake-up are two isolates in one process (a
    // file lock does not separate them): only the first may create the
    // wrapped key, the other adopts it, or one of them would encrypt
    // with a key that is then overwritten.
    final target = File(wrappedPath);
    try {
      target.createSync(exclusive: true);
    } on FileSystemException {
      final winner = await _adoptWrapped(channel, dataDir, wrappedPath);
      if (winner != null) return winner;
      rethrow; // unreadable: the plain-file fallback below
    }
    target.writeAsBytesSync(ascii.encode(base64.encode(blob)), flush: true);
  } on Object {
    // ignore: avoid_print
    print('Warning: Android Keystore unavailable; keeping $keyFile.');
    if (fileKey == null) {
      File(plainPath).writeAsBytesSync(key);
    }
    _installOrReuseBridge()
        .addEntry(dataDir, key, null); // refuses: plain file stays
    return key;
  }
  if (fileKey != null) {
    try {
      File(plainPath).deleteSync();
    } on FileSystemException {
      // Best effort.
    }
  }
  // ignore: avoid_print
  print('Info: password key '
      '${fileKey != null ? 'moved into' : 'created in'} the Android Keystore.');
  _installOrReuseBridge().addEntry(dataDir, key, blob);
  return key;
}

/// Warms [rootDir] and every account directory in [accountIds] (§5.3).
///
/// Called at UI startup (`prepareStartup`) and headless wake (`_runHeadless`).
Future<void> warmAndroidKeystoreAll(
  String rootDir,
  Iterable<String> accountIds, {
  AndroidChannel channel = const AndroidChannel(),
  @visibleForTesting bool? onAndroid,
}) async {
  if (!(onAndroid ?? Platform.isAndroid)) return;
  try {
    await warmAndroidKeystore(rootDir, channel: channel, onAndroid: onAndroid);
  } on KeyStoreMissing {
    return;
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: Keystore warm-up failed for root (${e.runtimeType}: $e).');
  }
  for (final id in accountIds) {
    try {
      final dir = accountDirFor(rootDir, id);
      if (!Directory(dir).existsSync()) continue;
      await ensureWarmed(dir, channel: channel, onAndroid: onAndroid);
    } on KeyStoreMissing {
      return;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: Keystore warm-up failed for account $id '
          '(${e.runtimeType}: $e).');
    }
  }
}

/// Optional test seam for verifying [ensureWarmed] calls off Android.
@visibleForTesting
Future<void> Function(String accountDir)? ensureWarmedOverride;

/// Idempotent warm-up of [accountDir]'s Android Keystore entry (§5.3).
///
/// No-op off Android or once [accountDir] is already in [WarmedAndroidKeystore].
/// Awaited before every `createApp`, `getKey`, `decrypt`, or `ConfigManager`
/// for an account so an account added in another isolate is warmed before use.
Future<void> ensureWarmed(
  String accountDir, {
  AndroidChannel channel = const AndroidChannel(),
  @visibleForTesting bool? onAndroid,
}) async {
  final override = ensureWarmedOverride;
  if (override != null) {
    await override(accountDir);
    return;
  }
  if (!(onAndroid ?? Platform.isAndroid)) return;
  final existing = androidKeystoreBridge;
  if (existing is WarmedAndroidKeystore && existing.hasEntry(accountDir)) {
    return;
  }
  try {
    await warmAndroidKeystore(accountDir,
        channel: channel, onAndroid: onAndroid);
  } on KeyStoreMissing {
    // Plain file fallback off Keystore.
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: ensureWarmed failed for $accountDir (${e.runtimeType}: $e).');
  }
}
