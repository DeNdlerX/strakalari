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
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    originalFernetFactory = fernetFactory;
    clearKeyCache();
  });

  tearDown(() {
    keyStoreBackend = null;
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

  test('noBackendFallsBackToFile', () {
    keyStoreBackend = null;
    final token = encrypt('hunter2');
    expect(File(keyPath()).existsSync(), isTrue);
    expect(decrypt(token), 'hunter2');
  });

  test('entryIsBoundToTheDataDir', () {
    expect(entryName('${tmp.path}/a'), isNot(entryName('${tmp.path}/b')));
  });

  test('forgetKeyRemovesFileKey', () {
    // No backend: the key lands in the file (mirrors CI without keyring).
    keyStoreBackend = null;
    getKey(tmp.path);
    expect(File('${tmp.path}${Platform.pathSeparator}$keyFile').existsSync(),
        isTrue);
    expect(forgetKey(tmp.path), isTrue);
    expect(File('${tmp.path}${Platform.pathSeparator}$keyFile').existsSync(),
        isFalse);
  });

  test('decryptSurvivesKeyFileOSError', () {
    fernetFactory = () => throw const OSError('disk unavailable');
    expect(decrypt('whatever-unreadable'), 'whatever-unreadable');
  });
}
