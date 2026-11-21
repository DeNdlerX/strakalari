// Port of `TestKeystoreKey` (tests/test_mobile.py), run through the
// Flutter warm-up (`warmAndroidKeystore`) and then core's `getKey`, the
// way the app starts. The channel is faked like Python's `FakeKeystore`
// (XOR with a device key behind a 12-byte prefix). Every case checks that
// the warm-up and core answer the same key and leave the files Python's
// `_android_load_or_create` leaves (C-B1).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/platform/android/android_keystore.dart';
import 'package:strakalari_core/strakalari_core.dart';

class FakeKeystore {
  final secret = Uint8List.fromList('device-bound-key-0123456789abcdef'.codeUnits);
  bool brokenUnwrap = false;
  bool brokenWrap = false;
  int wraps = 0;

  Uint8List _xor(List<int> data) => Uint8List.fromList([
        for (var i = 0; i < data.length; i++) data[i] ^ secret[i % secret.length],
      ]);

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'keystoreWrap':
        if (brokenWrap) throw PlatformException(code: 'WRAP_FAILED', message: 'keystore busy');
        wraps++;
        return Uint8List.fromList([...List.filled(12, 1), ..._xor(args['data']! as Uint8List)]);
      case 'keystoreUnwrap':
        if (brokenUnwrap) {
          throw PlatformException(code: 'UNWRAP_FAILED', message: 'key permanently invalidated');
        }
        final blob = args['blob']! as Uint8List;
        if (blob.length < 13) throw PlatformException(code: 'BAD_BLOB');
        return _xor(blob.sublist(12));
    }
    throw MissingPluginException();
  }
}

List<String> _names(Directory dir) =>
    (dir.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList()
      ..sort());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory data;
  late FakeKeystore fake;

  setUp(() {
    data = Directory.systemTemp.createTempSync('ks_');
    fake = FakeKeystore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, fake.handle);
    clearKeyCache();
    androidKeystoreBridge = null;
    // flutter_test_config sets STRAKALARI_NO_KEYRING, which turns the
    // Keystore off; Python's fixture patches `_android_keystore` instead.
    setEnvironmentOverride({
      for (final e in Platform.environment.entries)
        if (e.key != 'STRAKALARI_NO_KEYRING') e.key: e.value,
      'STRAKALARI_DATA_DIR': data.path,
      'FLET_PLATFORM': 'android', // core then behaves as on the phone
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, null);
    clearKeyCache();
    androidKeystoreBridge = null;
    data.deleteSync(recursive: true);
  });

  /// One app start: warm-up, then core reads the key like `Strakalari()`.
  Future<Uint8List> start() async {
    clearKeyCache();
    final warmed = await warmAndroidKeystore(data.path, onAndroid: true);
    final key = getKey(data.path);
    expect(key, warmed, reason: 'core must use the key the warm-up settled');
    return key;
  }

  test('freshInstallKeepsOnlyTheWrappedKey', () async {
    final key = await start();
    expect(Fernet.isValidKeyBytes(key), isTrue);
    expect(File('${data.path}/secret.key').existsSync(), isFalse);
    expect(File('${data.path}/secret.key.wrapped').existsSync(), isTrue);
    expect(await start(), key); // unwrapped again
    expect(storageLocation(data.path), 'keystore');
    expect(_names(data), ['secret.key.lock', 'secret.key.wrapped']);
  });

  test('plainKeyFromAnOlderBuildIsMigrated', () async {
    final old = Fernet.generateKey();
    File('${data.path}/secret.key').writeAsBytesSync(old);
    expect(await start(), old); // passwords stay readable
    expect(File('${data.path}/secret.key').existsSync(), isFalse);
    expect(await start(), old);
    expect(_names(data), ['secret.key.lock', 'secret.key.wrapped']);
  });

  test('lostKeystoreKeyQuarantinesAndStartsOver', () async {
    final first = await start();
    fake.brokenUnwrap = true;
    fake.brokenWrap = true; // and the Keystore refuses new keys too
    final second = await start();
    expect(second, isNot(first));
    expect(
        data.listSync().where((e) => e.path.contains('secret.key.wrapped.corrupt-')), isNotEmpty);
    expect(File('${data.path}/secret.key').existsSync(), isTrue); // the plain fallback
    expect(File('${data.path}/secret.key').readAsBytesSync(), second);
    expect(File('${data.path}/secret.key.wrapped').existsSync(), isFalse);
    // The next start still reads the same plain key, it does not lose it.
    expect(await start(), second);
  });

  test('forgetRemovesTheWrappedKey', () async {
    await start();
    expect(forgetKey(data.path), isTrue);
    expect(File('${data.path}/secret.key.wrapped').existsSync(), isFalse);
    expect(File('${data.path}/secret.key').existsSync(), isFalse);
  });

  test('keystoreDownOnFreshInstallKeepsThePlainKeyAcrossStarts', () async {
    fake.brokenWrap = true;
    final key = await start();
    expect(_names(data), ['secret.key', 'secret.key.lock']);
    expect(await start(), key);
    // The Keystore works again: the plain key is moved in, unchanged.
    fake.brokenWrap = false;
    expect(await start(), key);
    expect(_names(data), ['secret.key.lock', 'secret.key.wrapped']);
  });

  test('twoIsolatesStartingTogetherShareOneKey', () async {
    // The UI and a headless wake-up warm at the same time.
    final keys = await Future.wait([
      warmAndroidKeystore(data.path, onAndroid: true),
      warmAndroidKeystore(data.path, onAndroid: true),
    ]);
    expect(keys[0], keys[1]);
    clearKeyCache();
    expect(getKey(data.path), keys[0]);
    expect(_names(data), ['secret.key.lock', 'secret.key.wrapped']);
    expect(await start(), keys[0]);
  });

  test('differingPlainKeyIsKeptAlongsideWrappedKeyAcrossStarts', () async {
    await start();
    final wrappedBefore =
        File('${data.path}/secret.key.wrapped').readAsBytesSync();
    final fileKey = Fernet.generateKey();
    File('${data.path}/secret.key').writeAsBytesSync(fileKey);

    expect(await start(), fileKey);
    expect(File('${data.path}/secret.key').existsSync(), isTrue);
    expect(File('${data.path}/secret.key').readAsBytesSync(), fileKey);
    expect(File('${data.path}/secret.key.wrapped').readAsBytesSync(),
        wrappedBefore);

    expect(await start(), fileKey);
    expect(File('${data.path}/secret.key').existsSync(), isTrue);
    expect(File('${data.path}/secret.key').readAsBytesSync(), fileKey);
    expect(File('${data.path}/secret.key.wrapped').readAsBytesSync(),
        wrappedBefore);
  });

  group('F4 multi-key WarmedAndroidKeystore (Item 12)', () {
    test('warmAndroidKeystoreAllHoldsSeparateKeysForRootAndMultipleAccounts',
        () async {
      final acc1 = Directory('${data.path}/accounts/default')
        ..createSync(recursive: true);
      final acc2 = Directory('${data.path}/accounts/acc_001122334455')
        ..createSync(recursive: true);

      await warmAndroidKeystoreAll(
        data.path,
        const ['default', 'acc_001122334455'],
        onAndroid: true,
      );

      clearKeyCache();
      final kRoot = getKey(data.path);
      final k1 = getKey(acc1.path);
      final k2 = getKey(acc2.path);
      expect(kRoot, isNot(equals(k1)));
      expect(k1, isNot(equals(k2)));

      final tRoot = encrypt('gem_secret', dataDir: data.path);
      final t1 = encrypt('child1_pw', dataDir: acc1.path);
      final t2 = encrypt('child2_pw', dataDir: acc2.path);
      clearKeyCache();
      expect(decryptStrict(tRoot, dataDir: data.path), 'gem_secret');
      expect(decryptStrict(t1, dataDir: acc1.path), 'child1_pw');
      expect(decryptStrict(t2, dataDir: acc2.path), 'child2_pw');
      // Cross-account decryption without fallback must fail.
      expect(decryptStrict(t1, dataDir: acc2.path), isNull);
    });

    test('ensureWarmedHandlesAccountAddedAfterIsolateStartWithoutQuarantine',
        () async {
      final acc1 = Directory('${data.path}/accounts/default')
        ..createSync(recursive: true);
      await warmAndroidKeystoreAll(data.path, const ['default'], onAndroid: true);

      // Simulate another isolate creating a brand-new account and wrapping its key.
      final accNew = Directory('${data.path}/accounts/acc_abcdef123456')
        ..createSync(recursive: true);
      final savedBridge = androidKeystoreBridge;
      androidKeystoreBridge = null;
      final createdKey = await warmAndroidKeystore(accNew.path, onAndroid: true);
      final pwCipher = encrypt('late_added_pw', dataDir: accNew.path);
      final wrappedBefore =
          File('${accNew.path}/secret.key.wrapped').readAsBytesSync();

      // Switch back to the earlier isolate's bridge (doesn't know accNew yet).
      androidKeystoreBridge = savedBridge;
      clearKeyCache();

      // Calling ensureWarmed warms accNew cleanly without quarantining its blob.
      await ensureWarmed(accNew.path, onAndroid: true);
      final wrapsAfterFirst = fake.wraps;
      expect(getKey(accNew.path), createdKey);
      expect(decryptStrict(pwCipher, dataDir: accNew.path), 'late_added_pw');
      expect(
        File('${accNew.path}/secret.key.wrapped').readAsBytesSync(),
        wrappedBefore,
      );
      expect(
        accNew
            .listSync()
            .where((e) => e.path.contains('.corrupt-')),
        isEmpty,
      );
      // Idempotent second call does nothing.
      await ensureWarmed(accNew.path, onAndroid: true);
      expect(fake.wraps, wrapsAfterFirst);

      // forgetKey evicts accNew from WarmedAndroidKeystore while acc1 survives.
      expect(forgetKey(accNew.path), isTrue);
      expect((androidKeystoreBridge as WarmedAndroidKeystore).hasEntry(accNew.path),
          isFalse);
      expect((androidKeystoreBridge as WarmedAndroidKeystore).hasEntry(acc1.path),
          isTrue);
    });
  });
}
