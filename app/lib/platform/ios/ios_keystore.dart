// iOS Keychain backend for the password-encryption key.
//
// Core's `KeyStore` interface is synchronous while the iOS `MethodChannel`
// (`strakalari/ios`, served by `AppDelegate.swift` with
// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) is async. Just like
// Android's `WarmedAndroidKeystore`, startup (`prepareStartup`) and account
// lifecycle hooks (`ensureIosWarmed`) warm each directory's Keychain entry
// asynchronously so core's synchronous `getKey(dir)` reads from memory without
// blocking and never silently regenerates a key when Keychain is locked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'ios_channel.dart';

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

bool get _noKeyring {
  final value = (getenv('STRAKALARI_NO_KEYRING') ?? '').trim();
  return value.isNotEmpty && value != '0';
}

/// Synchronous [KeyStore] backed by warmed iOS Keychain entries.
class WarmedIosKeyStore implements KeyStore {
  WarmedIosKeyStore([this.channel = const IosChannel()]);

  final IosChannel channel;
  final Map<String, String> _vault = {};
  final Map<String, String> _unavailable = {};

  static String _slot(String service, String account) => '$service\x00$account';

  /// True when [dataDir] has a warmed entry (present or marked unavailable).
  bool hasEntry(String dataDir) {
    final slot = _slot(serviceName, entryName(dataDir));
    return _vault.containsKey(slot) || _unavailable.containsKey(slot);
  }

  /// Stores a warmed key value in memory for [service]/[account].
  void cacheEntry(String service, String account, String value) {
    final slot = _slot(service, account);
    _unavailable.remove(slot);
    _vault[slot] = value;
  }

  /// Records that Keychain refused access for [service]/[account] so core
  /// throws [KeyStoreUnavailable] instead of silently creating a new key.
  void markUnavailable(String service, String account, String reason) {
    final slot = _slot(service, account);
    _vault.remove(slot);
    _unavailable[slot] = reason;
  }

  /// Evicts [dataDir]'s entry from memory.
  void removeEntry(String dataDir) {
    final slot = _slot(serviceName, entryName(dataDir));
    _vault.remove(slot);
    _unavailable.remove(slot);
  }

  @override
  String? getPassword(String service, String account) {
    final slot = _slot(service, account);
    final err = _unavailable[slot];
    if (err != null) throw KeyStoreUnavailable(err);
    return _vault[slot];
  }

  @override
  void setPassword(String service, String account, String password) {
    final slot = _slot(service, account);
    if (_vault[slot] == password && !_unavailable.containsKey(slot)) {
      return; // Already saved & read-back verified during async warm-up.
    }
    // Never claim a synchronous write succeeded without awaiting Keychain:
    // `_toStore` in core catches this and keeps the `secret.key` fallback
    // rather than deleting the plain file on an unconfirmed async write.
    throw const KeyStoreUnavailable(
      'iOS Keychain entry was not verified during warm-up.',
    );
  }

  @override
  void deletePassword(String service, String account) {
    final slot = _slot(service, account);
    _vault.remove(slot);
    _unavailable.remove(slot);
    unawaited(
      channel.keychainDelete(service, account).catchError((Object e) {
        // ignore: avoid_print
        print('Warning: iOS Keychain delete failed ($e).');
      }),
    );
  }
}

WarmedIosKeyStore _installOrReuseStore(IosChannel channel) {
  final existing = keyStoreBackend;
  if (existing is WarmedIosKeyStore) {
    onForgetKeyHook = existing.removeEntry;
    return existing;
  }
  final store = WarmedIosKeyStore(channel);
  keyStoreBackend = store;
  onForgetKeyHook = store.removeEntry;
  return store;
}

/// Runs the iOS Keychain load-or-create lifecycle asynchronously for [dataDir]
/// and registers the warmed key in [keyStoreBackend].
///
/// Throws [KeyStoreMissing] off iOS (or when no iOS plugin answers).
/// Throws [KeyStoreUnavailable] when Keychain refuses access and no plain
/// `secret.key` exists to fall back to.
Future<Uint8List> warmIosKeystore(
  String dataDir, {
  IosChannel channel = const IosChannel(),
  @visibleForTesting bool? onIos,
}) async {
  if (!(onIos ?? (mobilePlatform() == 'ios'))) {
    throw const KeyStoreMissing('No iOS backend.');
  }
  final plainPath = resolvePath(keyFile, dataDir);
  Uint8List? fileKey = _readTrimmed(plainPath);
  if (fileKey != null && !Fernet.isValidKeyBytes(fileKey)) {
    quarantineCorruptFile(plainPath);
    fileKey = null;
  }
  if (_noKeyring) {
    if (fileKey == null) {
      fileKey = Fernet.generateKey();
      writeKeyFileDirect(plainPath, fileKey);
    }
    return fileKey;
  }

  final name = entryName(dataDir);
  String? storedText;
  try {
    storedText = await channel.keychainGet(serviceName, name);
  } on KeyStoreMissing {
    rethrow;
  } on KeyStoreUnavailable catch (e) {
    if (fileKey != null) return fileKey;
    _installOrReuseStore(channel).markUnavailable(serviceName, name, e.message);
    rethrow;
  }

  final stored =
      storedText == null ? null : Uint8List.fromList(ascii.encode(storedText));
  if (stored != null && Fernet.isValidKeyBytes(stored)) {
    final store = _installOrReuseStore(channel);
    store.cacheEntry(serviceName, name, storedText!);
    if (fileKey != null) {
      if (!_bytesEqual(fileKey, stored)) {
        // Never guess when plain secret.key differs from Keychain.
        // ignore: avoid_print
        print('Warning: $keyFile differs from the key in the OS credential '
            'store; using the file.');
        return fileKey;
      }
      try {
        File(plainPath).deleteSync();
      } on FileSystemException {
        // Best effort.
      }
    }
    return stored;
  }

  final key = fileKey ?? Fernet.generateKey();
  final encoded = ascii.decode(key);
  try {
    final saved = await channel.keychainSet(serviceName, name, encoded);
    final readBack = saved ? await channel.keychainGet(serviceName, name) : null;
    if (readBack == encoded) {
      final store = _installOrReuseStore(channel);
      store.cacheEntry(serviceName, name, encoded);
      if (fileKey != null) {
        try {
          File(plainPath).deleteSync();
        } on FileSystemException {
          // Best effort.
        }
      }
      // ignore: avoid_print
      print('Info: password key '
          '${fileKey != null ? 'moved into' : 'created in'} the iOS Keychain.');
      return key;
    }
  } on KeyStoreMissing {
    rethrow;
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: could not save the key to the iOS Keychain '
        '(${e.runtimeType}: $e); keeping $keyFile.');
  }

  if (fileKey == null) {
    writeKeyFileDirect(plainPath, key);
  }
  return key;
}

/// Warms [rootDir] and every account directory in [accountIds] on iOS.
Future<void> warmIosKeystoreAll(
  String rootDir,
  Iterable<String> accountIds, {
  IosChannel channel = const IosChannel(),
  @visibleForTesting bool? onIos,
}) async {
  if (!(onIos ?? (mobilePlatform() == 'ios'))) return;
  try {
    await warmIosKeystore(rootDir, channel: channel, onIos: onIos);
  } on KeyStoreMissing {
    return;
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: iOS Keychain warm-up failed for root '
        '(${e.runtimeType}: $e).');
  }
  for (final id in accountIds) {
    try {
      final dir = accountDirFor(rootDir, id);
      if (!Directory(dir).existsSync()) continue;
      await ensureIosWarmed(dir, channel: channel, onIos: onIos);
    } on KeyStoreMissing {
      return;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: iOS Keychain warm-up failed for account $id '
          '(${e.runtimeType}: $e).');
    }
  }
}

/// Idempotent warm-up of [accountDir]'s iOS Keychain entry.
///
/// No-op off iOS or once [accountDir] is already warmed.
Future<void> ensureIosWarmed(
  String accountDir, {
  IosChannel channel = const IosChannel(),
  @visibleForTesting bool? onIos,
}) async {
  if (!(onIos ?? (mobilePlatform() == 'ios'))) return;
  final existing = keyStoreBackend;
  if (existing is WarmedIosKeyStore && existing.hasEntry(accountDir)) {
    return;
  }
  try {
    await warmIosKeystore(accountDir, channel: channel, onIos: onIos);
  } on KeyStoreMissing {
    // Plain file fallback off iOS Keychain.
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: ensureIosWarmed failed for $accountDir '
        '(${e.runtimeType}: $e).');
  }
}
