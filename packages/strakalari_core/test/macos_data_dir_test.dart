// Port of tests/test_macos_data_dir.py: the installed macOS app keeps its
// data out of the .app bundle (~/Library/Application Support/Strakalari)
// and copies an older build's bundle data over once, with the password
// key. Runs on any OS through the same seams Python patches (platform,
// executable folder, carry_key).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

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

void _write(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

String _read(String path) => File(path).readAsStringSync();

bool _same(String a, String b) => p.equals(p.normalize(a), p.normalize(b));

void main() {
  late Directory tmp;
  late String bundle;
  late String support;
  late Map<String, String> env;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('macdata_');
    final home = p.join(tmp.path, 'home');
    Directory(home).createSync();
    bundle = p.join(tmp.path, 'Applications', 'Strakalari.app', 'Contents', 'MacOS');
    Directory(bundle).createSync(recursive: true);
    support = p.join(home, 'Library', 'Application Support', 'Strakalari');
    env = {
      for (final e in Platform.environment.entries)
        if (e.key != 'STRAKALARI_DATA_DIR') e.key: e.value,
      'HOME': home,
      'USERPROFILE': home,
      'STRAKALARI_NO_KEYRING': '1',
    };
    setEnvironmentOverride(env);
    dataDirPlatformOverride = 'darwin';
    installDirOverride = bundle;
    clearDataDirCaches();
    clearKeyCache();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dataDirPlatformOverride = null;
    installDirOverride = null;
    carryKeyHook = null;
    keyStoreBackend = null;
    clearDataDirCaches();
    clearKeyCache();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock file may still be open on Windows.
    }
  });

  /// Resolve to the bundle dir, as an older build did.
  void useBundle() {
    macosDataDirCache['$bundle\x00$support'] = bundle;
  }

  test('freshInstallUsesApplicationSupport', () {
    expect(_same(getUserDataDir(), support), isTrue);
    expect(Directory(support).existsSync(), isTrue);
    expect(_same(resolvePath('./config.json'), p.join(support, 'config.json')), isTrue);
    expect(Directory(bundle).listSync(), isEmpty);
  });

  test('oldBundleDataIsMovedOnce', () {
    _write(p.join(bundle, 'config.json'), jsonEncode({
      'strava_blacklist': './my_blacklist.json',
      'already_excused_file': '/abs/elsewhere.json',
      'log_file': '../outside.txt',
    }));
    const names = ['data_cache.json', 'automation_history.jsonl', 'log.txt',
        'already_excused_lessons.json', 'my_blacklist.json'];
    for (final name in names) {
      _write(p.join(bundle, name), name);
    }
    _write(p.join(bundle, 'school_presets', 'mine.json'), 'preset');
    _write(p.join(bundle, 'session.lock'), ''); // locks are not data

    expect(_same(getUserDataDir(), support), isTrue);
    expect((jsonDecode(_read(p.join(support, 'config.json'))) as Map)['strava_blacklist'],
        './my_blacklist.json');
    for (final name in names) {
      expect(_read(p.join(support, name)), name, reason: name);
    }
    expect(_read(p.join(support, 'school_presets', 'mine.json')), 'preset');
    expect(File(p.join(support, 'session.lock')).existsSync(), isFalse);
    expect(File(p.join(p.dirname(support), 'outside.txt')).existsSync(), isFalse);
    // The bundle copy stays (an older build may still run from it).
    expect(File(p.join(bundle, 'config.json')).existsSync(), isTrue);
  });

  test('existingApplicationSupportDataWins', () {
    _write(p.join(bundle, 'config.json'), '{"from": "bundle"}');
    _write(p.join(bundle, 'data_cache.json'), 'bundle');
    _write(p.join(support, 'config.json'), '{"from": "support"}');
    expect(_same(getUserDataDir(), support), isTrue);
    expect(jsonDecode(_read(p.join(support, 'config.json'))), {'from': 'support'});
    expect(File(p.join(support, 'data_cache.json')).existsSync(), isFalse);
  });

  test('movedPasswordsStillDecryptWithKeyFile', () {
    _write(p.join(bundle, 'config.json'), '{}');
    // Encrypt under the bundle dir, as an older build did.
    useBundle();
    final token = encrypt('hunter2');
    expect(File(p.join(bundle, 'secret.key')).existsSync(), isTrue);

    clearDataDirCaches();
    clearKeyCache();
    expect(_same(getUserDataDir(), support), isTrue);
    expect(decrypt(token), 'hunter2');
  });

  test('movedPasswordsStillDecryptWithKeychain', () {
    keyStoreBackend = MemoryKeyStore();
    setEnvironmentOverride({...env}..remove('STRAKALARI_NO_KEYRING'));
    _write(p.join(bundle, 'config.json'), '{}');
    useBundle();
    final token = encrypt('hunter2');
    expect(File(p.join(bundle, 'secret.key')).existsSync(), isFalse); // key sits in the store

    clearDataDirCaches();
    clearKeyCache();
    expect(_same(getUserDataDir(), support), isTrue);
    expect(decrypt(token), 'hunter2');
    expect(File(p.join(support, 'secret.key')).existsSync(), isFalse); // carried store to store
  });

  test('lockedKeychainKeepsBundleForThisRun', () {
    _write(p.join(bundle, 'config.json'), '{}');
    carryKeyHook = (oldDir, newDir) => false;
    expect(_same(getUserDataDir(), bundle), isTrue);
    // Not marked done: the next launch tries again.
    expect(File(p.join(support, 'config.json')).existsSync(), isFalse);
    clearDataDirCaches();
    carryKeyHook = (oldDir, newDir) => true;
    expect(_same(getUserDataDir(), support), isTrue);
    expect(File(p.join(support, 'config.json')).existsSync(), isTrue);
  });

  test('dataDirOverrideStillWins', () {
    _write(p.join(bundle, 'config.json'), '{}');
    final custom = p.join(tmp.path, 'custom');
    setEnvironmentOverride({...env, 'STRAKALARI_DATA_DIR': custom});
    expect(_same(getUserDataDir(), custom), isTrue);
  });

  test('windowsPortableDirUnchanged', () {
    final exeDir = p.join(tmp.path, 'Strakalari');
    Directory(exeDir).createSync();
    dataDirPlatformOverride = 'win32';
    installDirOverride = exeDir;
    expect(_same(getUserDataDir(), exeDir), isTrue);
  });
}
