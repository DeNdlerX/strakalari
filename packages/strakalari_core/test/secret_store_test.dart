import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/android_bridge.dart';
import 'package:strakalari_core/src/platform/keystore.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/fernet.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

class MemoryKeyStore implements KeyStore {
  final store = <String, String>{};

  /// When set, getPassword throws it (mirrors a locked store).
  Object? failGet;

  @override
  String? getPassword(String service, String account) {
    if (failGet != null) throw failGet!;
    return store['$service\x00$account'];
  }

  @override
  void setPassword(String service, String account, String password) {
    store['$service\x00$account'] = password;
  }

  @override
  void deletePassword(String service, String account) {
    store.remove('$service\x00$account');
  }
}

void main() {
  late Directory tmp;
  late MemoryKeyStore backend;
  late Fernet Function() originalFernetFactory;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('secret_store_test_');
    backend = MemoryKeyStore();
    keyStoreBackend = backend;
    allowMissingKeyStoreForTesting = false;
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    originalFernetFactory = fernetFactory;
    clearKeyCache();
  });

  tearDown(() {
    keyStoreBackend = null;
    allowMissingKeyStoreForTesting = false;
    setEnvironmentOverride(null);
    fernetFactory = originalFernetFactory;
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String keyPath() => '${tmp.path}${Platform.pathSeparator}$keyFile';

  test('newKeyGoesToTheStoreNotAFile', () {
    final token = encrypt('hunter2');
    expect(File(keyPath()).existsSync(), isFalse);
    expect(backend.store, hasLength(1));
    clearKeyCache();
    expect(decrypt(token), 'hunter2');
    expect(storageLocation(getUserDataDir()), 'keyring');
  });

  test('existingKeyFileIsMigratedAndDeleted', () {
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    final token = encrypt('hunter2');
    expect(File(keyPath()).existsSync(), isTrue);
    clearKeyCache();
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    expect(decrypt(token), 'hunter2');
    expect(File(keyPath()).existsSync(), isFalse);
    expect(backend.store, hasLength(1));
    clearKeyCache();
    expect(decrypt(token), 'hunter2');
  });

  test('copiedFolderWithoutStoreEntryCannotDecrypt', () {
    final token = encrypt('hunter2');
    // Another machine/user: same files, empty credential store.
    backend.store.clear();
    clearKeyCache();
    expect(decryptStrict(token), isNull);
  });

  test('lockedStoreWithFileUsesFile', () {
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    final token = encrypt('hunter2');
    clearKeyCache();
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    backend.failGet = const KeyStoreUnavailable('locked');
    expect(decrypt(token), 'hunter2');
  });

  test('lockedStoreWithoutFileFailsLoudly', () {
    backend.failGet = const KeyStoreUnavailable('locked');
    expect(() => encrypt('hunter2'),
        throwsA(isA<KeyStoreUnavailable>()));
  });

  test('differentFileAndStoreKeysPreferFile', () {
    encrypt('x'); // Creates a store key.
    clearKeyCache();
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    final token = encrypt('hunter2'); // Separate file key (restored backup).
    expect(File(keyPath()).existsSync(), isTrue);
    clearKeyCache();
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    expect(decrypt(token), 'hunter2');
    expect(File(keyPath()).existsSync(), isTrue);
  });

  test('missingBackendOnDesktopThrowsInsteadOfCreatingFile', () {
    keyStoreBackend = null;
    expect(() => encrypt('hunter2'), throwsA(isA<KeyStoreUnavailable>()));
    expect(File(keyPath()).existsSync(), isFalse);
    expect(() => getKey(tmp.path), throwsA(isA<KeyStoreUnavailable>()));
    expect(
      () => storageLocation(tmp.path),
      throwsA(isA<KeyStoreUnavailable>()),
    );
  });

  test('noBackendFallsBackToFile', () {
    keyStoreBackend = null;
    allowMissingKeyStoreForTesting = true;
    final token = encrypt('hunter2');
    expect(File(keyPath()).existsSync(), isTrue);
    expect(decrypt(token), 'hunter2');
  });

  test('entryIsBoundToTheDataDir', () {
    expect(entryName('${tmp.path}/a'), isNot(entryName('${tmp.path}/b')));
  });

  test('entryNameNormalizesSlashesTrailingSeparatorDotDotAndCase', () {
    final canonical = entryName(tmp.path);
    expect(entryName('${tmp.path}/'), canonical);
    expect(entryName('${tmp.path}${Platform.pathSeparator}'), canonical);
    expect(
      entryName(
        '${tmp.path}${Platform.pathSeparator}sub${Platform.pathSeparator}..',
      ),
      canonical,
    );
    expect(entryName(tmp.path.replaceAll(r'\', '/')), canonical);
    if (Platform.isWindows) {
      expect(entryName(tmp.path.toUpperCase()), canonical);
      expect(entryName(tmp.path.toLowerCase()), canonical);
    }
    const winCanonical = r'C:\Users\Student\AppData\Local\Strakalari';
    final winExpected = entryName(winCanonical, windows: true);
    expect(
      entryName('C:/Users/Student/AppData/Local/Strakalari', windows: true),
      winExpected,
    );
    expect(
      entryName(r'C:\Users\Student\AppData\Local\Strakalari\', windows: true),
      winExpected,
    );
    expect(
      entryName(
        'C:/Users/Student/AppData/Local/Other/../Strakalari/./',
        windows: true,
      ),
      winExpected,
    );
    expect(
      entryName(r'c:\USERS\student\AppData\LOCAL\strakalari', windows: true),
      winExpected,
    );
  });

  test('forgetKeyRemovesFileKey', () {
    // Explicit opt-in: the key lands in the file (mirrors CI without keyring).
    keyStoreBackend = null;
    allowMissingKeyStoreForTesting = true;
    getKey(tmp.path);
    expect(File('${tmp.path}${Platform.pathSeparator}$keyFile').existsSync(),
        isTrue);
    expect(forgetKey(tmp.path), isTrue);
    expect(File('${tmp.path}${Platform.pathSeparator}$keyFile').existsSync(),
        isFalse);
  });

  test('decryptSurvivesKeyFileOSError', () {
    // Dart file APIs raise FileSystemException where Python raises OSError.
    fernetFactory =
        () => throw const FileSystemException('disk unavailable');
    expect(decrypt('whatever-unreadable'), 'whatever-unreadable');
  });

  test('iosEntryNameUsesPathRelativeToMobileDataRoot (R7 M1)', () {
    addTearDown(() => setMobileDataDir(null));
    final rootA = '${tmp.path}${Platform.pathSeparator}UUID-A${Platform.pathSeparator}data';
    final rootB = '${tmp.path}${Platform.pathSeparator}UUID-B${Platform.pathSeparator}data';
    final defA = '$rootA${Platform.pathSeparator}accounts${Platform.pathSeparator}default';
    final defB = '$rootB${Platform.pathSeparator}accounts${Platform.pathSeparator}default';
    final acc1A = '$rootA${Platform.pathSeparator}accounts${Platform.pathSeparator}acc_1';

    // Desktop keeps absolute-path hashing unchanged.
    expect(entryName(rootA), isNot(entryName(rootB)));

    // Android keeps absolute-path hashing unchanged.
    setEnvironmentOverride({'FLET_PLATFORM': 'android'});
    setMobileDataDir(rootA);
    final androidA = entryName(defA);
    setMobileDataDir(rootB);
    expect(entryName(defB), isNot(androidA));

    // iOS hashes relative to setMobileDataDir (`data`, `data/accounts/<id>`).
    setEnvironmentOverride({'FLET_PLATFORM': 'ios'});
    setMobileDataDir(rootA);
    final iosRootA = entryName(rootA);
    final iosDefA = entryName(defA);
    final iosAcc1A = entryName(acc1A);
    expect(iosRootA, isNot(iosDefA));
    expect(iosDefA, isNot(iosAcc1A));

    setMobileDataDir(rootB);
    expect(entryName(rootB), iosRootA);
    expect(entryName(defB), iosDefA);
  });

  group('androidLoadOrCreate error handling (F2)', () {
    tearDown(() {
      androidKeystoreBridge = null;
    });

    test('unavailableKeystoreLeavesWrappedKeyUntouchedAndPropagates', () {
      final bridge = _FakeAndroidBridge();
      androidKeystoreBridge = bridge;
      final original = getKey(tmp.path);
      final wrapped = File('${tmp.path}${Platform.pathSeparator}$wrappedFile');
      expect(wrapped.existsSync(), isTrue);
      final wrappedBytes = wrapped.readAsBytesSync();

      clearKeyCache();
      bridge.unwrapError = const KeyStoreUnavailable('keystore busy');
      expect(() => getKey(tmp.path), throwsA(isA<KeyStoreUnavailable>()));
      expect(wrapped.existsSync(), isTrue);
      expect(wrapped.readAsBytesSync(), wrappedBytes);
      expect(File(keyPath()).existsSync(), isFalse);
      expect(
        tmp.listSync().where((e) => e.path.contains('.corrupt-')),
        isEmpty,
      );

      // Once Keystore recovers, the original key unwraps intact.
      bridge.unwrapError = null;
      expect(getKey(tmp.path), original);
    });

    test('corruptBlobStillQuarantines', () {
      final bridge = _FakeAndroidBridge();
      androidKeystoreBridge = bridge;
      final first = getKey(tmp.path);

      clearKeyCache();
      bridge.unwrapError = const FormatException('bad blob');
      final second = getKey(tmp.path);
      expect(second, isNot(first));
      expect(
        tmp.listSync().where((e) => e.path.contains('$wrappedFile.corrupt-')),
        hasLength(1),
      );
    });

    test('nonFernetUnwrappedBytesStillQuarantine', () {
      final bridge = _FakeAndroidBridge();
      androidKeystoreBridge = bridge;
      final first = getKey(tmp.path);

      clearKeyCache();
      bridge.returnBadKeyOnce = true;
      final second = getKey(tmp.path);
      expect(second, isNot(first));
      expect(
        tmp.listSync().where((e) => e.path.contains('$wrappedFile.corrupt-')),
        hasLength(1),
      );
    });
  });
}

class _FakeAndroidBridge implements AndroidKeystoreBridge {
  Object? unwrapError;
  bool returnBadKeyOnce = false;

  @override
  bool get available => true;

  @override
  Uint8List wrap(Uint8List key) =>
      Uint8List.fromList([1, 2, 3, 4, ...key]);

  @override
  Uint8List unwrap(Uint8List blob) {
    if (unwrapError != null) {
      final err = unwrapError!;
      unwrapError = null; // allow subsequent wrap/unwrap round-trip to succeed
      throw err;
    }
    if (returnBadKeyOnce) {
      returnBadKeyOnce = false;
      return Uint8List.fromList(utf8.encode('not-a-fernet-key'));
    }
    if (blob.length <= 4) throw const FormatException('too short');
    return Uint8List.fromList(blob.sublist(4));
  }
}
