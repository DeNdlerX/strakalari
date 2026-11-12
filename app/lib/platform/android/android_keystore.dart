// Android Keystore backend for the password-encryption key.
//
// The Keystore crypto itself runs in Java (`StrakalariChannel`: alias
// `strakalari-secret-key`, AES/GCM/NoPadding, 12-byte IV prefix — identical
// to `core/android.py`). The catch is that core's `AndroidKeystoreBridge`
// is synchronous (like pyjnius was) while a MethodChannel is async, so this
// layer warms the key once per isolate start and serves core from memory:
//
//   await warmAndroidKeystore(dataDir);   // UI startup + background entry
//   androidKeystoreBridge = warmedBridge; // then Strakalari()/getKey()
//
// The warm-up replicates core's `_androidLoadOrCreate` step for step
// (unwrap `secret.key.wrapped`, migrate a plain `secret.key`, create,
// quarantine on a lost key with plain-file fallback), so core's following
// synchronous pass sees settled files and returns the same key. The
// in-memory bridge answers only for that warmed pair and refuses anything
// else, so a key that changed underneath still fails safe (never guessed).
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

/// The warmed bridge: answers only for the warmed (key, blob) pair.
///
/// [blob] is what the Keystore answered (the raw bytes, not the base64
/// text of `secret.key.wrapped`): core decodes the file before it calls
/// [unwrap] and encodes [wrap]'s answer itself. A null [blob] means the
/// Keystore was unavailable at warm-up: [wrap] refuses, so core keeps the
/// plain `secret.key` exactly like Python does when the Keystore fails.
class WarmedAndroidKeystore implements AndroidKeystoreBridge {
  final Uint8List key;
  final Uint8List? blob;

  const WarmedAndroidKeystore(this.key, this.blob);

  @override
  bool get available => true;

  @override
  Uint8List wrap(Uint8List key) {
    final blob = this.blob;
    if (blob == null) {
      throw const KeyStoreUnavailable('The Android Keystore did not answer.');
    }
    if (_bytesEqual(key, this.key)) return Uint8List.fromList(blob);
    // A different key after warm-up (restored backup, …): refuse, like a
    // Keystore that does not answer. Core keeps the plain file then.
    throw const KeyStoreUnavailable('Key changed after the Keystore warm-up.');
  }

  @override
  Uint8List unwrap(Uint8List blob) {
    final own = this.blob;
    if (own != null && _bytesEqual(blob, own)) return Uint8List.fromList(key);
    throw const FormatException('the wrapped key does not read back');
  }
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
    AndroidChannel channel, String wrappedPath) async {
  for (var i = 0; i < 30; i++) {
    final wrapped = _readTrimmed(wrappedPath);
    if (wrapped != null && wrapped.isNotEmpty) {
      try {
        final blob = Uint8List.fromList(base64.decode(ascii.decode(wrapped)));
        final key = await _channelUnwrap(channel, blob);
        if (Fernet.isValidKeyBytes(key)) {
          androidKeystoreBridge = WarmedAndroidKeystore(key, blob);
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

/// Runs core's `_androidLoadOrCreate` lifecycle with async channel calls
/// and registers the warmed sync bridge. Call once per isolate start,
/// before the first `getKey`/`Strakalari`.
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
  final plainPath = '$dataDir/$keyFile';
  final wrappedPath = '$dataDir/$wrappedFile';
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
      key = await _channelUnwrap(channel, blob);
    } on Object {
      // Lost Keystore key or tampered blob: quarantine and start over,
      // like core (stored passwords must be entered again).
      // ignore: avoid_print
      print('Warning: could not unlock $wrappedFile; '
          'stored passwords must be entered again.');
      quarantineCorruptFile(wrappedPath);
      key = null;
    }
    if (key != null && Fernet.isValidKeyBytes(key)) {
      if (fileKey != null && !_bytesEqual(fileKey, key)) {
        // The file encrypted what is in config.json now (e.g. restored
        // from a backup). Never guess, keep using it.
        // ignore: avoid_print
        print('Warning: $keyFile differs from $wrappedFile; using the file.');
        androidKeystoreBridge = WarmedAndroidKeystore(fileKey, blob);
        return fileKey;
      }
      if (fileKey != null) {
        try {
          File(plainPath).deleteSync();
        } on FileSystemException {
          // Best effort.
        }
      }
      androidKeystoreBridge = WarmedAndroidKeystore(key, blob);
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
      final winner = await _adoptWrapped(channel, wrappedPath);
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
    androidKeystoreBridge =
        WarmedAndroidKeystore(key, null); // refuses: plain file stays
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
  androidKeystoreBridge = WarmedAndroidKeystore(key, blob);
  return key;
}
