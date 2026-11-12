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
}
