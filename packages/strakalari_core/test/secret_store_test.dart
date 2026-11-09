import 'dart:io';

import 'package:test/test.dart';

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
}
