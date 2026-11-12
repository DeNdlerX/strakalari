// Port of tests/test_store_package.py: the Store (MSIX) build has no
// GitHub update checks, no Run-key autostart, and keeps its data in
// %LOCALAPPDATA%\Strakalari (copying a classic install's data once).
// TestMsixVersion and test_store_submit_loads test Python tools that
// still build and publish the MSIX; they stay in the Python suite.
import 'dart:convert';
import 'dart:io';

import 'package:app/platform/desktop/autostart.dart';
import 'package:app/platform/desktop/store_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

class MemoryKeyStore implements KeyStore {
  final Map<String, String> entries = {};
  @override
  String? getPassword(String service, String account) => entries['$service/$account'];
  @override
  void setPassword(String service, String account, String password) =>
      entries['$service/$account'] = password;
  @override
  void deletePassword(String service, String account) => entries.remove('$service/$account');
}

/// `os.path.join` / `normcase` comparisons without package:path.
// ignore: camel_case_types
class p {
  static String join(String a, [String? b, String? c, String? d]) =>
      [a, b, c, d].whereType<String>().join(Platform.pathSeparator);
  static bool equals(String a, String b) => _norm(a) == _norm(b);
  static String _norm(String x) {
    var s = x.replaceAll('/', r'\').toLowerCase();
    while (s.endsWith(r'\')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

void _write(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('store_');
    clearKeyCache();
  });

  tearDown(() {
    setStorePackageProbe(null);
    fetchReleasesHook = null;
    keyStoreBackend = null;
    clearKeyCache();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock file may still be open on Windows.
    }
  });

  group('TestPackageDetection', () {
    test('unpackagedHere', () {
      expect(hasPackageIdentity(), isFalse); // this test run has no package identity
      expect(storePackageProbe(release: true)(), isFalse);
    });

    test('devRunNeverCounts', () {
      // The Microsoft Store's python.exe has a package identity too; a
      // Flutter debug run is the same case.
      expect(storePackageProbe(release: false, identity: () => true)(), isFalse);
    });

    test('frozenWithIdentity', () {
      expect(storePackageProbe(release: true, identity: () => true)(), isTrue);
      expect(hasPackageIdentity(rc: () => 122, windows: true), isTrue);
      expect(hasPackageIdentity(rc: () => appModelErrorNoPackage, windows: true), isFalse);
      expect(hasPackageIdentity(rc: () => 122, windows: false), isFalse);
    });

    test('legacyDirAbsent', () {
      setEnvironmentOverride({'LOCALAPPDATA': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
      expect(legacyDesktopDataDir(), isNull);
    });
  });

  group('TestStoreDataDir', () {
    late String local;

    setUp(() {
      local = p.join(tmp.path, 'Local');
      Directory(local).createSync();
      // No STRAKALARI_DATA_DIR: the real resolution runs.
      setEnvironmentOverride({
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_DATA_DIR' && e.key != 'LOCALAPPDATA' && e.key != 'APPDATA') e.key: e.value,
        'LOCALAPPDATA': local,
        'STRAKALARI_NO_KEYRING': '1',
      });
      setStorePackageProbe(() => true);
    });

    test('neverThePackageDir', () {
      expect(p.equals(getUserDataDir(), p.join(local, 'Strakalari')), isTrue);
    });

    test('classicInstallDataIsCopied', () {
      final legacy = p.join(local, 'Programs', 'Strakalari');
      _write(p.join(legacy, 'config.json'), jsonEncode({'school': 'x'}));
      _write(p.join(legacy, 'automation_history.jsonl'), 'history');
      final target = p.join(local, 'Strakalari');
      expect(p.equals(getUserDataDir(), target), isTrue);
      expect(jsonDecode(File(p.join(target, 'config.json')).readAsStringSync()), {'school': 'x'});
      expect(File(p.join(target, 'automation_history.jsonl')).readAsStringSync(), 'history');
      // The classic install keeps its own copy.
      expect(File(p.join(legacy, 'config.json')).existsSync(), isTrue);
    });

    test('copiedPasswordsDecryptWithCredentialManager', () {
      final legacy = p.join(local, 'Programs', 'Strakalari');
      _write(p.join(legacy, 'config.json'), '{}');
      keyStoreBackend = MemoryKeyStore();
      final base = {
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_DATA_DIR' && e.key != 'LOCALAPPDATA' && e.key != 'APPDATA' &&
              e.key != 'STRAKALARI_NO_KEYRING')
            e.key: e.value,
        'LOCALAPPDATA': local,
      };
      // Encrypted by the classic install: key bound to its dir path.
      setEnvironmentOverride({...base, 'STRAKALARI_DATA_DIR': legacy});
      final token = encrypt('hunter2');
      expect(File(p.join(legacy, 'secret.key')).existsSync(), isFalse);
      setEnvironmentOverride(base);
      clearKeyCache();
      expect(p.equals(getUserDataDir(), p.join(local, 'Strakalari')), isTrue);
      expect(decrypt(token), 'hunter2');
    });

    test('existingStoreDataWins', () {
      _write(p.join(local, 'Programs', 'Strakalari', 'config.json'), '{"from": "classic"}');
      _write(p.join(local, 'Strakalari', 'config.json'), '{"from": "store"}');
      getUserDataDir();
      expect(jsonDecode(File(p.join(local, 'Strakalari', 'config.json')).readAsStringSync()),
          {'from': 'store'});
    });
  }, skip: Platform.isWindows ? false : 'the Store build exists on Windows only');

  group('TestUpdateGate', () {
    setUp(() => setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'}));

    test('checkReturnsNoneWithoutNetwork', () async {
      setStorePackageProbe(() => true);
      fetchReleasesHook = (_) => throw StateError('no network in Store builds');
      expect(await checkForUpdates(), isNull);
      expect(await checkForUpdates(force: true), isNull);
    });

    test('cachedHidden', () {
      setStorePackageProbe(() => true);
      expect(loadCached(), isNull);
    });

    test('gateOffForClassic', () {
      setStorePackageProbe(() => false);
      expect(updatesManagedExternally(), isFalse);
    });
  });

  group('TestAutostartGate', () {
    setUp(() => setStorePackageProbe(() => true));

    test('setRefused', () {
      expect(setAutostart(true), isFalse);
      expect(setAutostart(false), isFalse);
    });

    test('enabledUnknown', () {
      expect(isAutostartEnabled(), isFalse);
    });
  });
}
