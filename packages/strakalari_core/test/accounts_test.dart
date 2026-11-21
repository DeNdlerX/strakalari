import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

class _MemoryKeyStore implements KeyStore {
  final Map<String, String> entries = {};
  Object? failGet;
  Object? failSet;
  bool refuseSet = false;

  @override
  String? getPassword(String service, String account) {
    if (failGet != null) throw failGet!;
    return entries['$service\x00$account'];
  }

  @override
  void setPassword(String service, String account, String password) {
    if (failSet != null) throw failSet!;
    if (refuseSet) return;
    entries['$service\x00$account'] = password;
  }

  @override
  void deletePassword(String service, String account) {
    entries.remove('$service\x00$account');
  }
}

class _FakeAndroidKeystore implements AndroidKeystoreBridge {
  @override
  bool available = true;
  bool failUnwrap = false;

  // Reversible XOR-wrap tagged with a 4-byte magic prefix.
  static const List<int> _magic = [0x53, 0x4B, 0x41, 0x31];

  @override
  Uint8List wrap(Uint8List plain) {
    final out = Uint8List(_magic.length + plain.length);
    out.setRange(0, _magic.length, _magic);
    for (var i = 0; i < plain.length; i++) {
      out[_magic.length + i] = plain[i] ^ 0x5A;
    }
    return out;
  }

  @override
  Uint8List unwrap(Uint8List wrapped) {
    if (failUnwrap) throw const FormatException('keystore unwrap failed');
    if (wrapped.length <= _magic.length) {
      throw const FormatException('too short');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (wrapped[i] != _magic[i]) {
        throw const FormatException('bad magic');
      }
    }
    final plain = Uint8List(wrapped.length - _magic.length);
    for (var i = 0; i < plain.length; i++) {
      plain[i] = wrapped[_magic.length + i] ^ 0x5A;
    }
    return plain;
  }
}

class _RecordingNotifier implements NotifierBackend {
  final List<(String tag, String body, String? route)> calls = [];

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) {
    calls.add((tag, body, route));
    return true;
  }
}

Map<String, String> _snapshotRootHashes(String rootDir, List<String> rels) {
  final out = <String, String>{};
  for (final rel in rels) {
    final f = File(p.join(rootDir, rel));
    if (f.existsSync()) {
      out[rel] = sha256.convert(f.readAsBytesSync()).toString();
    }
  }
  return out;
}

void _writeText(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content, encoding: utf8);
}

void main() {
  late Directory tmp;
  late _MemoryKeyStore store;
  late Fernet Function() origFernet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('f4_accounts_test_');
    store = _MemoryKeyStore();
    keyStoreBackend = store;
    androidKeystoreBridge = null;
    allowMissingKeyStoreForTesting = false;
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    origFernet = fernetFactory;
    clearKeyCache();
    clearDataDirCaches();
    resetAccountsModeForTesting();
    notifierBackend = null;
    carryKeyHook = null;
    dataDirPlatformOverride = null;
    installDirOverride = null;
    setStorePackageProbe(null);
  });

  tearDown(() {
    keyStoreBackend = null;
    androidKeystoreBridge = null;
    allowMissingKeyStoreForTesting = false;
    setEnvironmentOverride(null);
    fernetFactory = origFernet;
    clearKeyCache();
    clearDataDirCaches();
    resetAccountsModeForTesting();
    notifierBackend = null;
    carryKeyHook = null;
    dataDirPlatformOverride = null;
    installDirOverride = null;
    setStorePackageProbe(null);
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Lock file may linger briefly on Windows.
    }
  });

  test('configKeyClassificationMatchesDesignSpec', () {
    expect(globalConfigKeys.length, 19);
    expect(canonicalDefaults.length, 74);
    for (final k in globalConfigKeys) {
      expect(canonicalDefaults.containsKey(k), isTrue, reason: 'Missing $k');
    }
    final perAccount =
        canonicalDefaults.keys.where((k) => !globalConfigKeys.contains(k));
    expect(perAccount.length, 55);
    expect(perAccount, contains('background_refresh'));
  });

  group('Item 1: Desktop layout move', () {
    Future<void> runDesktopMove({required bool noKeyring}) async {
      final root = Directory(p.join(tmp.path, noKeyring ? 'no_kr' : 'kr'))
        ..createSync(recursive: true);
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': root.path,
        if (noKeyring) 'STRAKALARI_NO_KEYRING': '1',
      });
      clearKeyCache();

      // Seed a pre-F4 flat layout using legacy single-file ConfigManager.
      final legacy = ConfigManager(p.join(root.path, 'config.json'));
      legacy.set('bakalari_url', 'https://bakaweb.school.cz');
      legacy.set('bakalari_username', 'jan.novak');
      legacy.set('bakalari_password', 'BakSecret#1');
      legacy.set('strava_canteen_id', '1950');
      legacy.set('strava_username', 'jan.strava');
      legacy.set('strava_password', 'StravaSecret#2');
      legacy.set('gemini_api_key', 'AIza-Shared-Key');
      legacy.set('your_signature', 'Jan Novák');
      legacy.set('theme', 'light');
      legacy.set('language', 'en');
      legacy.set('check_interval_minutes', 30);
      legacy.save();

      _writeText(p.join(root.path, 'data_cache.json'),
          jsonEncode({'_cache_version': 2, 'last_updated': '20.11.2026 10:00:00'}));
      _writeText(p.join(root.path, 'already_excused_lessons.json'), '[{"type":"day"}]');
      _writeText(p.join(root.path, 'strava_blacklist.json'), '["ryba"]');
      _writeText(p.join(root.path, 'automation_history.jsonl'), '{"kind":"excuse"}\n');
      _writeText(p.join(root.path, 'log.txt'), '[2026-11-20] hello\n');
      _writeText(p.join(root.path, 'log.txt.old'), '[2026-11-19] old\n');

      const files = [
        'config.json',
        'data_cache.json',
        'already_excused_lessons.json',
        'strava_blacklist.json',
        'automation_history.jsonl',
        'log.txt',
        'log.txt.old',
      ];
      final beforeHashes = _snapshotRootHashes(root.path, files);

      final res = await ensureMultiAccountLayout(root.path);
      expect(res.isReady, isTrue, reason: res.error);
      expect(res.migratedNow, isTrue);
      expect(res.registry!.activeId, 'default');
      expect(res.registry!.primaryId, 'default');
      expect(res.registry!.accounts.single.label, 'Jan Novák');
      expect(res.registry!.accounts.single.migrated, isTrue);
      expect(res.registry!.accounts.single.adding, isFalse);

      // Every original root file stays byte-identical.
      expect(_snapshotRootHashes(root.path, files), beforeHashes);

      // Every copied file in accounts/default/ is byte-identical.
      final defDir = accountDirFor(root.path, 'default');
      for (final rel in files) {
        final copyHash =
            sha256.convert(File(p.join(defDir, rel)).readAsBytesSync()).toString();
        expect(copyHash, beforeHashes[rel], reason: 'Mismatch for $rel');
      }

      // global.json holds ONLY shared keys present in source config.
      final globalJson = jsonDecode(
          File(p.join(root.path, globalConfigFile)).readAsStringSync()) as Map;
      expect(globalJson['theme'], 'light');
      expect(globalJson['language'], 'en');
      expect(globalJson['check_interval_minutes'], 30);
      expect(globalJson.keys.every(globalConfigKeys.contains), isTrue);

      // Passwords decrypt with the account key ALONE (no fallbackKeyDir).
      clearKeyCache();
      final movedCfg = ConfigManager.forAccount(root.path, 'default');
      expect(
        decryptStrict('${movedCfg.get('bakalari_password')}', dataDir: defDir),
        'BakSecret#1',
      );
      expect(
        decryptStrict('${movedCfg.get('strava_password')}', dataDir: defDir),
        'StravaSecret#2',
      );
      // Shared Gemini key decrypts with rootDir key.
      expect(
        decryptStrict('${movedCfg.get('gemini_api_key')}', dataDir: root.path),
        'AIza-Shared-Key',
      );

      if (!noKeyring) {
        // Key carried store-to-store; no secret.key file created in accounts/default.
        expect(File(p.join(defDir, keyFile)).existsSync(), isFalse);
        expect(store.entries.containsKey('$serviceName\x00${entryName(root.path)}'), isTrue);
        expect(store.entries.containsKey('$serviceName\x00${entryName(defDir)}'), isTrue);
      } else {
        expect(File(p.join(defDir, keyFile)).existsSync(), isTrue);
      }
    }

    test('keyringBackend', () => runDesktopMove(noKeyring: false));
    test('noKeyringFileFallback', () => runDesktopMove(noKeyring: true));

    test('migrationVerificationRejectsUnopenablePasswords (R6 S2)', () async {
      // Case 1: account password encrypted with a key different from the carried root key.
      final root1 = Directory(p.join(tmp.path, 'bad_acct_pw'))
        ..createSync(recursive: true);
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': root1.path});
      clearKeyCache();

      // Create a valid root key in the store, then write a config whose
      // bakalari_password was encrypted under a completely different key.
      final legacy1 = ConfigManager(p.join(root1.path, 'config.json'));
      legacy1.set('bakalari_url', 'https://bakaweb.school.cz');
      legacy1.set('bakalari_username', 'jan');
      legacy1.set('bakalari_password', 'ValidInitialPw');
      legacy1.save();

      final otherKey = Fernet.generateKey();
      final wrongToken = Fernet.fromKeyBytes(otherKey)
          .encryptBytes(utf8.encode('EncryptedWithWrongKey'));
      final cfgFile1 = File(p.join(root1.path, 'config.json'));
      final raw1 = jsonDecode(cfgFile1.readAsStringSync()) as Map<String, Object?>;
      raw1['bakalari_password'] = wrongToken;
      raw1['bakalari_password_encrypted'] = true;
      cfgFile1.writeAsStringSync(jsonEncode(raw1));
      _writeText(p.join(root1.path, 'data_cache.json'), '{"v":1}');

      final before1 =
          _snapshotRootHashes(root1.path, ['config.json', 'data_cache.json']);
      final res1 = await ensureMultiAccountLayout(root1.path);
      expect(res1.isDegraded, isTrue);
      expect(res1.error, contains('bakalari_password'));
      expect(File(p.join(root1.path, accountsFile)).existsSync(), isFalse);
      expect(Directory(accountDirFor(root1.path, 'default')).existsSync(), isFalse);
      expect(_snapshotRootHashes(root1.path, ['config.json', 'data_cache.json']),
          before1);

      // Case 2: account password opens with carried key, but shared gemini_api_key
      // is encrypted with another key (covers _verifyMigration step 5).
      resetAccountsModeForTesting();
      final root2 = Directory(p.join(tmp.path, 'bad_gemini_pw'))
        ..createSync(recursive: true);
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': root2.path});
      clearKeyCache();

      final legacy2 = ConfigManager(p.join(root2.path, 'config.json'));
      legacy2.set('bakalari_url', 'https://bakaweb.school.cz');
      legacy2.set('bakalari_username', 'jan');
      legacy2.set('bakalari_password', 'ValidAccountPw');
      legacy2.set('gemini_api_key', 'ValidGemini');
      legacy2.save();

      final wrongGemini = Fernet.fromKeyBytes(Fernet.generateKey())
          .encryptBytes(utf8.encode('WrongGeminiKey'));
      final cfgFile2 = File(p.join(root2.path, 'config.json'));
      final raw2 = jsonDecode(cfgFile2.readAsStringSync()) as Map<String, Object?>;
      raw2['gemini_api_key'] = wrongGemini;
      raw2['gemini_api_key_encrypted'] = true;
      cfgFile2.writeAsStringSync(jsonEncode(raw2));

      final before2 = _snapshotRootHashes(root2.path, ['config.json']);
      final res2 = await ensureMultiAccountLayout(root2.path);
      expect(res2.isDegraded, isTrue);
      expect(res2.error, contains('gemini_api_key'));
      expect(File(p.join(root2.path, accountsFile)).existsSync(), isFalse);
      expect(Directory(accountDirFor(root2.path, 'default')).existsSync(), isFalse);
      expect(_snapshotRootHashes(root2.path, ['config.json']), before2);
    });
  });

  group('Item 2: Android / Play (Flet) layout move', () {
    test('wrappedKeyAndCustomRelativePathsAndLogOld', () async {
      final root = Directory(p.join(tmp.path, 'android_wrapped'))
        ..createSync(recursive: true);
      final bridge = _FakeAndroidKeystore();
      androidKeystoreBridge = bridge;
      keyStoreBackend = null;
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': root.path,
        'FLET_PLATFORM': 'android',
      });
      clearKeyCache();

      // Encrypt using Android Keystore wrapped blob at root.
      final legacy = ConfigManager(p.join(root.path, 'config.json'));
      legacy.set('bakalari_url', 'https://bakaweb.gekom.cz');
      legacy.set('bakalari_username', 'play.user');
      legacy.set('bakalari_password', 'AndroidPw!99');
      legacy.set('already_excused_file', './sub/my_excused.json');
      legacy.set('log_file', './logs/custom.log');
      legacy.set('strava_blacklist', '/abs/outside_blacklist.json');
      legacy.save();

      expect(File(p.join(root.path, wrappedFile)).existsSync(), isTrue);
      _writeText(p.join(root.path, 'sub', 'my_excused.json'), '[{"ok":1}]');
      _writeText(p.join(root.path, 'logs', 'custom.log'), 'line1\n');
      _writeText(p.join(root.path, 'log.txt.old'), 'rotated\n');

      final rootFiles = [
        'config.json',
        wrappedFile,
        p.join('sub', 'my_excused.json'),
        p.join('logs', 'custom.log'),
        'log.txt.old',
      ];
      final before = _snapshotRootHashes(root.path, rootFiles);

      final res = await ensureMultiAccountLayout(root.path);
      expect(res.isReady, isTrue, reason: res.error);
      expect(res.migratedNow, isTrue);
      expect(res.registry!.accounts.single.label, 'play.user');

      // Originals untouched.
      expect(_snapshotRootHashes(root.path, rootFiles), before);

      // Copied files match byte-for-byte.
      final defDir = accountDirFor(root.path, 'default');
      for (final rel in rootFiles) {
        final h = sha256.convert(File(p.join(defDir, rel)).readAsBytesSync()).toString();
        expect(h, before[rel], reason: 'Mismatch for $rel');
      }
      // Password decrypts using default account's wrapped key alone.
      clearKeyCache();
      final cfg = ConfigManager.forAccount(root.path, 'default');
      expect(
        decryptStrict('${cfg.get('bakalari_password')}', dataDir: defDir),
        'AndroidPw!99',
      );
    });

    test('plainSecretKeyOnAndroidAndFailedUnwrapAbortsCleanly', () async {
      final root = Directory(p.join(tmp.path, 'android_plain'))
        ..createSync(recursive: true);
      final bridge = _FakeAndroidKeystore()..available = false;
      androidKeystoreBridge = bridge;
      keyStoreBackend = null;
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': root.path,
        'FLET_PLATFORM': 'android',
      });
      clearKeyCache();

      final legacy = ConfigManager(p.join(root.path, 'config.json'));
      legacy.set('bakalari_password', 'PlainAndroidPw');
      legacy.save();
      expect(File(p.join(root.path, keyFile)).existsSync(), isTrue);

      final before = _snapshotRootHashes(root.path, ['config.json', keyFile]);
      final res = await ensureMultiAccountLayout(root.path);
      expect(res.isReady, isTrue);
      expect(_snapshotRootHashes(root.path, ['config.json', keyFile]), before);

      // Now test a root wrapped blob that fails to unwrap: must degrade, never quarantine root.
      resetAccountsModeForTesting();
      final rootBad = Directory(p.join(tmp.path, 'android_bad_unwrap'))
        ..createSync(recursive: true);
      final badBridge = _FakeAndroidKeystore()..available = true;
      androidKeystoreBridge = badBridge;
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': rootBad.path,
        'FLET_PLATFORM': 'android',
      });
      clearKeyCache();
      final legacyBad = ConfigManager(p.join(rootBad.path, 'config.json'));
      legacyBad.set('bakalari_password', 'CantUnwrap');
      legacyBad.save();

      final badBefore =
          _snapshotRootHashes(rootBad.path, ['config.json', wrappedFile]);
      badBridge.failUnwrap = true;
      clearKeyCache();
      final badRes = await ensureMultiAccountLayout(rootBad.path);
      expect(badRes.isDegraded, isTrue);
      expect(File(p.join(rootBad.path, accountsFile)).existsSync(), isFalse);
      // Root wrapped file was NOT quarantined or modified.
      expect(
          _snapshotRootHashes(rootBad.path, ['config.json', wrappedFile]),
          badBefore);
    });
  });

  test('Item 3: secondRunChangesNothing', () async {
    final legacy = ConfigManager(p.join(tmp.path, 'config.json'));
    legacy.set('bakalari_username', 'student1');
    legacy.save();

    final first = await ensureMultiAccountLayout(tmp.path);
    expect(first.isReady, isTrue);
    expect(first.migratedNow, isTrue);

    final regFile = File(p.join(tmp.path, accountsFile));
    final globFile = File(p.join(tmp.path, globalConfigFile));
    final accCfg = File(p.join(accountDirFor(tmp.path, 'default'), 'config.json'));
    final mtimesBefore = (
      regFile.lastModifiedSync(),
      globFile.lastModifiedSync(),
      accCfg.lastModifiedSync(),
    );
    final bytesBefore = (
      regFile.readAsBytesSync(),
      globFile.readAsBytesSync(),
      accCfg.readAsBytesSync(),
    );

    final second = await ensureMultiAccountLayout(tmp.path);
    expect(second.isReady, isTrue);
    expect(second.migratedNow, isFalse);
    expect(
      (
        regFile.lastModifiedSync(),
        globFile.lastModifiedSync(),
        accCfg.lastModifiedSync(),
      ),
      mtimesBefore,
    );
    expect(regFile.readAsBytesSync(), bytesBefore.$1);
    expect(globFile.readAsBytesSync(), bytesBefore.$2);
    expect(accCfg.readAsBytesSync(), bytesBefore.$3);
  });

  test('Item 4: interruptedRunAtEveryStepRecoversCleanly', () async {
    for (final failStep in const [
      'staging_copy',
      'key_carry',
      'verify',
      'global_json',
      'rename',
    ]) {
      resetAccountsModeForTesting();
      clearKeyCache();
      final root = Directory(p.join(tmp.path, 'crash_$failStep'))
        ..createSync(recursive: true);
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': root.path});

      final legacy = ConfigManager(p.join(root.path, 'config.json'));
      legacy.set('bakalari_username', 'u_$failStep');
      legacy.set('bakalari_password', 'pw_$failStep');
      legacy.set('theme', 'dark');
      legacy.save();

      var crashed = false;
      try {
        await ensureMultiAccountLayout(
          root.path,
          onMigrationStep: (step) {
            if (step == failStep) {
              crashed = true;
              throw StateError('simulated crash at $step');
            }
          },
        );
      } on StateError {
        // Expected crash.
      }
      expect(crashed, isTrue);
      expect(File(p.join(root.path, accountsFile)).existsSync(), isFalse);

      // For global_json crash, edit root config theme before retry to verify
      // global.json is overwritten from the current root config on retry.
      if (failStep == 'global_json') {
        final raw = jsonDecode(
            File(p.join(root.path, 'config.json')).readAsStringSync()) as Map;
        raw['theme'] = 'light';
        atomicWriteJson(p.join(root.path, 'config.json'), raw);
      }
      final beforeRetry = _snapshotRootHashes(root.path, ['config.json']);

      // Retry without crash.
      final res = await ensureMultiAccountLayout(root.path);
      expect(res.isReady, isTrue, reason: 'Failed recovery for $failStep: ${res.error}');
      expect(res.registry!.activeId, 'default');
      expect(res.registry!.accounts.single.migrated, isTrue);
      expect(res.registry!.accounts.single.label, 'u_$failStep');
      expect(_snapshotRootHashes(root.path, ['config.json']), beforeRetry);

      final cfg = ConfigManager.forAccount(root.path, 'default');
      if (failStep == 'global_json') {
        expect(cfg.get('theme'), 'light');
      }
      expect(
        decryptStrict('${cfg.get('bakalari_password')}',
            dataDir: accountDirFor(root.path, 'default')),
        'pw_$failStep',
      );
    }
  });

  test('Item 5: lostOrCorruptRegistryRebuildsFromFoldersNeverReRunsMove', () async {
    final legacy = ConfigManager(p.join(tmp.path, 'config.json'));
    legacy.set('bakalari_username', 'old_root_user');
    legacy.set('your_signature', 'Root Name');
    legacy.save();

    final moved = await ensureMultiAccountLayout(tmp.path);
    expect(moved.isReady, isTrue);

    // Edit default account AFTER move and add a second account.
    final defCfg = ConfigManager.forAccount(tmp.path, 'default');
    defCfg.setAndSave('your_signature', 'Updated Child 1');
    final created = AccountManager.createProvisionalAccount(
      tmp.path,
      initialWizardStep: 1,
    );
    final acc2Cfg = ConfigManager.forAccount(tmp.path, created.account.id);
    acc2Cfg.setAndSave('your_signature', 'Child 2');
    AccountManager.finishAddingAccount(
      tmp.path,
      created.account.id,
      fallbackLabel: 'Account 2',
    );
    final rootBefore = _snapshotRootHashes(tmp.path, ['config.json']);

    // Case A: delete accounts.json completely.
    File(p.join(tmp.path, accountsFile)).deleteSync();
    resetAccountsModeForTesting();
    final rebuiltA = await ensureMultiAccountLayout(tmp.path);
    expect(rebuiltA.isReady, isTrue);
    expect(rebuiltA.migratedNow, isFalse);
    expect(rebuiltA.registry!.accounts.length, 2);
    expect(rebuiltA.registry!.activeId, 'default');
    expect(rebuiltA.registry!.primaryId, 'default');
    expect(rebuiltA.registry!.byId('default')!.label, 'Updated Child 1');
    expect(rebuiltA.registry!.byId('default')!.migrated, isTrue);
    expect(rebuiltA.registry!.byId(created.account.id)!.label, 'Child 2');
    expect(rebuiltA.registry!.accounts.every((a) => !a.adding), isTrue);
    expect(ConfigManager.forAccount(tmp.path, 'default').get('your_signature'),
        'Updated Child 1');
    expect(_snapshotRootHashes(tmp.path, ['config.json']), rootBefore);

    // Case B: corrupt accounts.json.
    File(p.join(tmp.path, accountsFile)).writeAsStringSync('{not valid json');
    resetAccountsModeForTesting();
    final rebuiltB = await ensureMultiAccountLayout(tmp.path);
    expect(rebuiltB.isReady, isTrue);
    expect(rebuiltB.migratedNow, isFalse);
    expect(rebuiltB.registry!.accounts.length, 2);
    expect(
      Directory(tmp.path)
          .listSync()
          .any((e) => p.basename(e.path).startsWith('accounts.json.corrupt-')),
      isTrue,
    );
    expect(_snapshotRootHashes(tmp.path, ['config.json']), rootBefore);
  });

  test('Item 6: degradedModeOnLockedSessionOrFailingKeyCarry', () async {
    final legacy = ConfigManager(p.join(tmp.path, 'config.json'));
    legacy.set('bakalari_password', 'LockTestPw');
    legacy.save();
    final before = _snapshotRootHashes(tmp.path, ['config.json']);

    // Hold session.lock -> move cannot acquire -> degraded.
    final lock = InterProcessLock(p.join(tmp.path, 'session.lock'));
    expect(lock.acquire(timeoutS: 0), isTrue);
    try {
      final resLocked = await ensureMultiAccountLayout(
        tmp.path,
        sessionLockTimeoutS: 0.05,
      );
      expect(resLocked.isDegraded, isTrue);
      expect(isAccountsMode, isFalse);
      expect(File(p.join(tmp.path, accountsFile)).existsSync(), isFalse);
    } finally {
      lock.release();
    }

    // Failing key store carry -> degraded, no accounts.json, no accounts/default.
    store.refuseSet = true;
    final resBadStore = await ensureMultiAccountLayout(tmp.path);
    expect(resBadStore.isDegraded, isTrue);
    expect(File(p.join(tmp.path, accountsFile)).existsSync(), isFalse);
    expect(Directory(accountDirFor(tmp.path, 'default')).existsSync(), isFalse);
    expect(_snapshotRootHashes(tmp.path, ['config.json']), before);

    // Once store works, move succeeds.
    store.refuseSet = false;
    final resOk = await ensureMultiAccountLayout(tmp.path);
    expect(resOk.isReady, isTrue);
    expect(resOk.migratedNow, isTrue);
    expect(_snapshotRootHashes(tmp.path, ['config.json']), before);
  });

  test('Item 7: accountsModeGuardConfigPrecedenceSplitSaveAndRootUntouched',
      () async {
    final legacy = ConfigManager(p.join(tmp.path, 'config.json'));
    legacy.set('bakalari_url', 'https://a.school.cz');
    legacy.set('bakalari_username', 'child_a');
    legacy.set('bakalari_password', 'PassA');
    legacy.set('theme', 'dark');
    legacy.set('excuse_mode', 'dry_run');
    legacy.set('strava_order_mode', 'dry_run');
    legacy.save();
    _writeText(p.join(tmp.path, 'data_cache.json'),
        jsonEncode({'_cache_version': 2, 'last_updated': '01.01.2026 08:00:00'}));
    _writeText(p.join(tmp.path, 'strava_blacklist.json'), '["orig"]');
    _writeText(p.join(tmp.path, 'automation_history.jsonl'), '{"orig":1}\n');
    _writeText(p.join(tmp.path, 'log.txt'), 'orig log\n');

    const rootFiles = [
      'config.json',
      'data_cache.json',
      'strava_blacklist.json',
      'automation_history.jsonl',
      'log.txt',
    ];
    final beforeRoot = _snapshotRootHashes(tmp.path, rootFiles);

    final moved = await ensureMultiAccountLayout(tmp.path);
    expect(moved.isReady, isTrue);

    // Every per-account function called without dataDir in accounts mode throws.
    expect(() => loadDataCache(), throwsStateError);
    expect(() => saveDataCache({'x': 1}), throwsStateError);
    expect(() => historyPath(), throwsStateError);
    expect(() => record('excuse', 'dry_run', 'manual', 's'), throwsStateError);
    expect(() => recent(), throwsStateError);
    expect(() => hasDryRun('excuse'), throwsStateError);
    expect(() => ConfigManager(), throwsStateError);
    expect(() => ConfigManager(p.join(tmp.path, 'config.json')), throwsStateError);
    expect(() => encrypt('secret'), throwsStateError);
    expect(() => decrypt('secret'), throwsStateError);
    expect(() => decryptStrict('secret'), throwsStateError);

    // Precedence: shared key comes from global.json even when accounts/default/config.json
    // still holds the byte-copied pre-F4 value ('dark').
    final defDir = accountDirFor(tmp.path, 'default');
    final globalMap = jsonDecode(
        File(p.join(tmp.path, globalConfigFile)).readAsStringSync()) as Map;
    globalMap['theme'] = 'light';
    atomicWriteJson(p.join(tmp.path, globalConfigFile), globalMap);
    final defCfg = ConfigManager.forAccount(tmp.path, 'default');
    expect(defCfg.get('theme'), 'light');

    // Split save: shared keys go ONLY to global.json, account keys ONLY to config.json.
    defCfg.set('language', 'en');
    defCfg.set('background_refresh', false);
    defCfg.save();
    final savedGlobal = jsonDecode(
        File(p.join(tmp.path, globalConfigFile)).readAsStringSync()) as Map;
    final savedAcc = jsonDecode(
        File(p.join(defDir, 'config.json')).readAsStringSync()) as Map;
    expect(savedGlobal['language'], 'en');
    expect(savedGlobal.containsKey('background_refresh'), isFalse);
    expect(savedAcc['background_refresh'], isFalse);
    expect(savedAcc.containsKey('language'), isFalse);
    expect(savedAcc.containsKey('theme'), isFalse);

    // Half-failed save: global write succeeds, account write fails -> global stands,
    // account edits stay pending and error is raised, retry saves account edits.
    defCfg.set('theme', 'dark');
    defCfg.set('excuse_delay_days', 5);
    defCfg.accountWriteOverride = () => throw StateError('disk full');
    expect(() => defCfg.save(), throwsStateError);
    expect(
      (jsonDecode(File(p.join(tmp.path, globalConfigFile)).readAsStringSync())
          as Map)['theme'],
      'dark',
    );
    expect(
      (jsonDecode(File(p.join(defDir, 'config.json')).readAsStringSync())
          as Map)['excuse_delay_days'],
      isNot(5),
    );
    defCfg.accountWriteOverride = null;
    defCfg.save();
    expect(
      (jsonDecode(File(p.join(defDir, 'config.json')).readAsStringSync())
          as Map)['excuse_delay_days'],
      5,
    );

    // Add second account and run a full cycle across both accounts.
    final created = AccountManager.createProvisionalAccount(
      tmp.path,
      initialWizardStep: 1,
    );
    final acc2Id = created.account.id;
    final acc2Dir = accountDirFor(tmp.path, acc2Id);
    final acc2Cfg = ConfigManager.forAccount(tmp.path, acc2Id);
    acc2Cfg.set('bakalari_url', 'https://b.school.cz');
    acc2Cfg.set('bakalari_username', 'child_b');
    acc2Cfg.set('bakalari_password', 'PassB');
    acc2Cfg.set('excuse_mode', 'dry_run');
    acc2Cfg.set('strava_order_mode', 'dry_run');
    acc2Cfg.save();
    AccountManager.finishAddingAccount(
      tmp.path,
      acc2Id,
      fallbackLabel: 'Child B',
    );

    for (final dir in [defDir, acc2Dir]) {
      final cfg = ConfigManager.scoped(
        p.join(dir, 'config.json'),
        globalPath: p.join(tmp.path, globalConfigFile),
        baseDir: dir,
        rootDir: tmp.path,
      );
      cfg.addBlacklistItem('houby');
      saveDataCache({'timetable': {'01.09.2026': <Object?>[]}}, dataDir: dir);
      record('excuse', 'dry_run', 'manual', 'dry excuse', dataDir: dir);
      record('lunch', 'dry_run', 'auto', 'dry cancel', dataDir: dir);
      final app = Strakalari(dataDir: dir, rootDir: tmp.path);
      app.writeLog('cycle log line');
      buildReport('cycle', 'oops PassA PassB',
          config: cfg.data, dataDir: dir, rootDir: tmp.path);
    }

    // Deleted account's ConfigManager and saveDataCache refuse to recreate folder.
    final liveAcc2 = ConfigManager.forAccount(tmp.path, acc2Id);
    AccountManager.deleteAccount(tmp.path, acc2Id, liveConfigManager: liveAcc2);
    expect(Directory(acc2Dir).existsSync(), isFalse);
    liveAcc2.set('excuse_delay_days', 9);
    expect(() => liveAcc2.save(), throwsStateError);
    expect(() => saveDataCache({'x': 1}, dataDir: acc2Dir), throwsStateError);
    expect(Directory(acc2Dir).existsSync(), isFalse);

    // Every original pre-F4 root file is STILL byte-identical!
    expect(_snapshotRootHashes(tmp.path, rootFiles), beforeRoot);
  });

  group('Item 8: Store & macOS moves after F4', () {
    Future<void> runPlatformMove({
      required bool darwin,
      required bool noKeyring,
    }) async {
      final sub = Directory(
          p.join(tmp.path, '${darwin ? 'mac' : 'msix'}_${noKeyring ? 'file' : 'kr'}'))
        ..createSync(recursive: true);
      final home = p.join(sub.path, 'home');
      final localAppData = p.join(sub.path, 'local');
      final srcDir = darwin
          ? p.join(sub.path, 'App.app', 'Contents', 'MacOS')
          : p.join(localAppData, 'Programs', 'Strakalari');
      final dstDir = darwin
          ? p.join(home, 'Library', 'Application Support', 'Strakalari')
          : p.join(localAppData, 'Strakalari');
      Directory(srcDir).createSync(recursive: true);

      // Build a 2-account F4 layout in srcDir.
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': srcDir,
        if (noKeyring) 'STRAKALARI_NO_KEYRING': '1',
      });
      clearKeyCache();
      resetAccountsModeForTesting();

      final init = await ensureMultiAccountLayout(srcDir);
      expect(init.isReady, isTrue);
      final c1 = ConfigManager.forAccount(srcDir, 'default');
      c1.set('bakalari_password', 'SrcPw1');
      c1.set('gemini_api_key', 'SrcGemKey');
      c1.save();

      final added = AccountManager.createProvisionalAccount(
          srcDir, initialWizardStep: 1);
      final c2 = ConfigManager.forAccount(srcDir, added.account.id);
      c2.set('bakalari_password', 'SrcPw2');
      c2.save();
      AccountManager.finishAddingAccount(
          srcDir, added.account.id, fallbackLabel: 'Acc 2');
      // Leftover .migrating folder should NOT be copied.
      _writeText(p.join(srcDir, 'accounts', '.migrating', 'junk.txt'), 'junk');

      // Switch to target platform environment (no STRAKALARI_DATA_DIR override).
      resetAccountsModeForTesting();
      clearKeyCache();
      clearDataDirCaches();
      setEnvironmentOverride({
        'HOME': home,
        'USERPROFILE': home,
        'LOCALAPPDATA': localAppData,
        if (noKeyring) 'STRAKALARI_NO_KEYRING': '1',
      });
      dataDirPlatformOverride = darwin ? 'darwin' : 'win32';
      installDirOverride = darwin ? srcDir : p.join(sub.path, 'msix_bin');
      if (!darwin) {
        setStorePackageProbe(() => true);
      }

      // First simulate interruption before accounts.json (carry fails on 2nd account).
      var calls = 0;
      carryKeyHook = (oldD, newD) {
        calls++;
        if (calls == 3) return false;
        return carryKey(oldD, newD);
      };
      final firstDir = getUserDataDir();
      if (darwin) {
        // On macOS, failed move keeps bundle for this run.
        expect(p.equals(p.normalize(firstDir), p.normalize(srcDir)), isTrue);
      }
      expect(File(p.join(dstDir, accountsFile)).existsSync(), isFalse);
      expect(hasAnyAccountFolder(dstDir), isFalse);

      // Next launch: carry succeeds and completes move.
      carryKeyHook = null;
      clearDataDirCaches();
      clearKeyCache();
      final resolved = getUserDataDir();
      expect(p.equals(p.normalize(resolved), p.normalize(dstDir)), isTrue);
      expect(File(p.join(dstDir, accountsFile)).existsSync(), isTrue);
      expect(Directory(p.join(dstDir, 'accounts', '.migrating')).existsSync(),
          isFalse);

      // Verify both accounts' passwords and shared Gemini key decrypt in target!
      clearKeyCache();
      final movedRes = await ensureMultiAccountLayout(dstDir);
      expect(movedRes.isReady, isTrue);
      expect(movedRes.registry!.accounts.length, 2);

      final d1 = accountDirFor(dstDir, 'default');
      final d2 = accountDirFor(dstDir, added.account.id);
      final t1 = ConfigManager.forAccount(dstDir, 'default');
      final t2 = ConfigManager.forAccount(dstDir, added.account.id);
      expect(decryptStrict('${t1.get('bakalari_password')}', dataDir: d1), 'SrcPw1');
      expect(decryptStrict('${t2.get('bakalari_password')}', dataDir: d2), 'SrcPw2');
      expect(decryptStrict('${t1.get('gemini_api_key')}', dataDir: dstDir), 'SrcGemKey');
    }

    test('macosKeyring', () => runPlatformMove(darwin: true, noKeyring: false));
    test('macosNoKeyring', () => runPlatformMove(darwin: true, noKeyring: true));
    test('msixKeyring', () => runPlatformMove(darwin: false, noKeyring: false),
        skip: !Platform.isWindows ? 'legacyDesktopDataDir is Windows-only' : false);
    test('msixNoKeyring', () => runPlatformMove(darwin: false, noKeyring: true),
        skip: !Platform.isWindows ? 'legacyDesktopDataDir is Windows-only' : false);
  });

  group('Item 12: Keys, forgetAllKeys, fallback & all-account redaction', () {
    test('forgetAllKeysForgetsOrphanFolderToo', () async {
      final res = await ensureMultiAccountLayout(tmp.path);
      expect(res.isReady, isTrue);

      final defDir = accountDirFor(tmp.path, 'default');
      final orphanDir = accountDirFor(tmp.path, 'acc_deadbeef0001');
      Directory(orphanDir).createSync(recursive: true);

      // Create keys in OS store for root, default, and an orphan folder not in accounts.json.
      encrypt('g', dataDir: tmp.path);
      encrypt('a', dataDir: defDir);
      encrypt('o', dataDir: orphanDir);
      expect(store.entries, hasLength(3));

      expect(AccountManager.forgetAllKeys(tmp.path), isTrue);
      expect(store.entries, isEmpty);
    });

    test('decryptStrictFallsBackToRootKey', () async {
      final res = await ensureMultiAccountLayout(tmp.path);
      expect(res.isReady, isTrue);
      final defDir = accountDirFor(tmp.path, 'default');
      // Encrypt with root key, then create a DIFFERENT key for defDir.
      final rootToken = encrypt('MigratedFallbackPw', dataDir: tmp.path);
      encrypt('other', dataDir: defDir);

      expect(decryptStrict(rootToken, dataDir: defDir), isNull);
      expect(
        decryptStrict(rootToken, dataDir: defDir, fallbackKeyDir: tmp.path),
        'MigratedFallbackPw',
      );
    });

    test('redactWithSavedConfigAndWriteLogScrubEveryAccountsSecrets', () async {
      final res = await ensureMultiAccountLayout(tmp.path);
      expect(res.isReady, isTrue);

      final c1 = ConfigManager.forAccount(tmp.path, 'default');
      c1.set('bakalari_password', 'ChildOneSecret!');
      c1.set('gemini_api_key', 'SharedGemSecret!');
      c1.save();

      final added = AccountManager.createProvisionalAccount(
          tmp.path, initialWizardStep: 1);
      final c2 = ConfigManager.forAccount(tmp.path, added.account.id);
      c2.set('bakalari_password', 'ChildTwoSecret!');
      c2.save();
      AccountManager.finishAddingAccount(
          tmp.path, added.account.id, fallbackLabel: 'Child 2');

      final rawTrace =
          'Crash echoing ChildOneSecret!, ChildTwoSecret!, and SharedGemSecret!';
      final scrubbed = redactWithSavedConfig(rawTrace, rootDir: tmp.path);
      expect(scrubbed, isNot(contains('ChildOneSecret!')));
      expect(scrubbed, isNot(contains('ChildTwoSecret!')));
      expect(scrubbed, isNot(contains('SharedGemSecret!')));

      // Strakalari.writeLog on account 1 also scrubs account 2's password!
      final captured = <String>[];
      final app1 = Strakalari(
        dataDir: accountDirFor(tmp.path, 'default'),
        rootDir: tmp.path,
        onLog: captured.add,
      );
      app1.writeLog('Oops ChildTwoSecret! leaked');
      expect(captured.single, isNot(contains('ChildTwoSecret!')));
    });
  });

  group('Lifecycle, duplicate login & notifyForAccount', () {
    test('addCancelFinishRenameDeleteAndOutsideFiles', () async {
      final init = await ensureMultiAccountLayout(tmp.path);
      expect(init.isReady, isTrue);

      // Cannot cancel or delete the sole non-adding account.
      expect(
        () => AccountManager.cancelAddingAccount(tmp.path, 'default'),
        throwsStateError,
      );
      expect(
        () => AccountManager.deleteAccount(tmp.path, 'default'),
        throwsStateError,
      );

      // Provisional account can be cancelled under session.lock.
      final prov = AccountManager.createProvisionalAccount(
        tmp.path,
        initialWizardStep: 1,
      );
      expect(prov.account.adding, isTrue);
      final provDir = accountDirFor(tmp.path, prov.account.id);
      encrypt('prov_pw', dataDir: provDir);
      final afterCancel = AccountManager.cancelAddingAccount(
        tmp.path,
        prov.account.id,
        returnToId: 'default',
      );
      expect(afterCancel.accounts.length, 1);
      expect(afterCancel.activeId, 'default');
      expect(Directory(provDir).existsSync(), isFalse);
      expect(store.entries.containsKey('$serviceName\x00${entryName(provDir)}'),
          isFalse);

      // Add a real 2nd account, finish it, check unique labels on rename, delete primary.
      final prov2 = AccountManager.createProvisionalAccount(
        tmp.path,
        initialWizardStep: 1,
      );
      final c2 = ConfigManager.forAccount(tmp.path, prov2.account.id);
      c2.set('bakalari_url', 'https://bakaweb.gekom.cz/');
      c2.set('bakalari_username', 'Klára');
      c2.set('strava_canteen_id', '1950');
      c2.set('strava_username', 'klara.s');
      c2.save();
      var reg = AccountManager.finishAddingAccount(
        tmp.path,
        prov2.account.id,
        fallbackLabel: 'Account 2',
      );
      expect(reg.byId(prov2.account.id)!.adding, isFalse);
      expect(reg.byId(prov2.account.id)!.label, 'Klára');

      // Duplicate login checks (case/trailing slash insensitive).
      expect(
        findDuplicateBakalariLogin(
          tmp.path,
          reg,
          excludeAccountId: 'default',
          url: 'HTTPS://BAKAWEB.GEKOM.CZ',
          username: 'klára ',
        )?.id,
        prov2.account.id,
      );
      expect(
        findDuplicateStravaLogin(
          tmp.path,
          reg,
          excludeAccountId: 'default',
          canteenId: '1950',
          username: 'KLARA.S',
        )?.id,
        prov2.account.id,
      );

      // Unique rename on clash.
      reg = AccountManager.renameAccount(tmp.path, 'default', 'klára');
      expect(reg.byId('default')!.label, 'klára 2');

      // Outside-folder file detection.
      final absLog = p.join(tmp.path, 'external_log.txt');
      _writeText(absLog, 'keep me');
      expect(
        accountHasOutsideFiles(
            accountDirFor(tmp.path, 'default'), {'log_file': absLog}),
        isTrue,
      );
      expect(
        accountHasOutsideFiles(
            accountDirFor(tmp.path, 'default'), {'log_file': './log.txt'}),
        isFalse,
      );

      // Deleting primary promotes remaining account and leaves external file intact.
      final del = AccountManager.deleteAccount(tmp.path, 'default');
      expect(del.wasPrimary, isTrue);
      expect(del.nextPrimaryId, prov2.account.id);
      expect(del.registry.primaryId, prov2.account.id);
      expect(File(absLog).existsSync(), isTrue);
    });

    test('cancelAddingAccountRefusesNonAddingAccountEvenWithTwoAccounts (R6 M2)',
        () async {
      final init = await ensureMultiAccountLayout(tmp.path);
      expect(init.isReady, isTrue);

      final prov = AccountManager.createProvisionalAccount(
        tmp.path,
        initialWizardStep: 1,
      );
      final acc2Id = prov.account.id;
      final acc2Dir = accountDirFor(tmp.path, acc2Id);
      final c2 = ConfigManager.forAccount(tmp.path, acc2Id);
      c2.set('bakalari_url', 'https://school2.cz');
      c2.set('bakalari_username', 'child2');
      c2.set('your_signature', 'Tonda');
      c2.save();
      final reg = AccountManager.finishAddingAccount(
        tmp.path,
        acc2Id,
        fallbackLabel: 'Účet',
      );
      expect(reg.accounts.length, 2);
      expect(reg.byId(acc2Id)!.adding, isFalse);

      final regBytesBefore =
          File(p.join(tmp.path, accountsFile)).readAsBytesSync();
      final cfgBytesBefore =
          File(p.join(acc2Dir, 'config.json')).readAsBytesSync();

      expect(
        () => AccountManager.cancelAddingAccount(tmp.path, acc2Id),
        throwsStateError,
      );

      // Registry file and account folder must be completely untouched.
      expect(
        File(p.join(tmp.path, accountsFile)).readAsBytesSync(),
        regBytesBefore,
      );
      expect(Directory(acc2Dir).existsSync(), isTrue);
      expect(
        File(p.join(acc2Dir, 'config.json')).readAsBytesSync(),
        cfgBytesBefore,
      );
      final regAfter = AccountRegistry.load(tmp.path)!;
      expect(regAfter.accounts.map((a) => a.id).toList(), ['default', acc2Id]);
    });

    test('notifyForAccountPrefixesLabelAndEncodesRouteExceptUpdate', () {
      final rec = _RecordingNotifier();
      notifierBackend = rec;

      notifyForAccount('new_mark', 'Matematika: 1',
          accountId: 'acc_2', accountLabel: 'Klára');
      notifyForAccount('new_mark', 'Fyzika: 2', accountId: 'default');
      notifyForAccount('update_available', 'New version',
          accountId: 'acc_2', accountLabel: 'Klára');

      expect(rec.calls, [
        ('new_mark', '[Klára] Matematika: 1', 'marks?account=acc_2'),
        ('new_mark', 'Fyzika: 2', 'marks?account=default'),
        ('update_available', '[Klára] New version', null),
      ]);
    });
  });
}
