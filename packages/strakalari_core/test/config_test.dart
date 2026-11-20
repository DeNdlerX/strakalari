import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/keystore.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

class MemoryKeyStore implements KeyStore {
  final store = <String, String>{};

  @override
  String? getPassword(String service, String account) =>
      store['$service\x00$account'];

  @override
  void setPassword(String service, String account, String password) {
    store['$service\x00$account'] = password;
  }

  @override
  void deletePassword(String service, String account) {
    store.remove('$service\x00$account');
  }
}

Map<String, Object?> validationBase() {
  final data = Map<String, Object?>.of(defaultConfig());
  // Fresh-install defaults intentionally flag empty Strava creds;
  // fill them so the new rules are what this tests.
  data['use_strava'] = true;
  data['strava_username'] = 'u';
  data['strava_canteen_id'] = '1';
  return data;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('config_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    keyStoreBackend = MemoryKeyStore();
    clearKeyCache();
  });

  tearDown(() {
    keyStoreBackend = null;
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('exampleParity', () {
    test('exampleKeysMatchCanonical', () {
      final example = jsonDecode(
          File('../../config.example.json').readAsStringSync()) as Map;
      final exampleKeys = example.keys.map<String>((k) => '$k').toSet();
      final canonicalKeys =
          canonicalDefaults.keys.toSet();
      expect(exampleKeys.difference(canonicalKeys), isEmpty,
          reason: 'extra: ${exampleKeys.difference(canonicalKeys)}');
      expect(canonicalKeys.difference(exampleKeys), isEmpty,
          reason: 'missing: ${canonicalKeys.difference(exampleKeys)}');
    });

    test('repoExampleFilesAreValid', () {
      for (final name in [
        'already_excused_lessons.example.json',
        'strava_blacklist.example.json'
      ]) {
        final data =
            jsonDecode(File('../../$name').readAsStringSync());
        expect(data, isList, reason: name);
      }
    });

    test('newCanonicalKeys', () {
      expect(canonicalDefaults['timetable_view'], 'table');
      expect(canonicalDefaults['compact_density'], isFalse);
      expect(canonicalDefaults['excuse_day_per_lesson'], isFalse);
      final example = jsonDecode(
          File('../../config.example.json').readAsStringSync()) as Map;
      expect(example.keys.map<String>((k) => '$k').toSet(), canonicalDefaults.keys.toSet());
    });
  });

  group('validateNewRules', () {
    test('defaultsPass', () {
      expect(validateConfig(validationBase()), isEmpty);
    });

    test('negativeDelayRejected', () {
      final data = validationBase();
      data['excuse_delay_days'] = -1;
      expect(validateConfig(data).any((p) => p.contains('excuse_delay_days')),
          isTrue);
    });

    test('badLanguageAndModelRejected', () {
      final data = validationBase();
      data['language'] = 'de';
      data['gemini_model'] = '  ';
      final problems = validateConfig(data);
      expect(problems.any((p) => p.contains('language')), isTrue);
      expect(problems.any((p) => p.contains('gemini_model')), isTrue);
    });

    test('wizardStepMustBeAStepOrMinusOne', () {
      for (final ok in [-1, 0, 7]) {
        final data = validationBase()..['wizard_step'] = ok;
        expect(validateConfig(data), isEmpty, reason: 'wizard_step $ok');
      }
      for (final bad in <Object>[-2, 'two', <int>[1]]) {
        final data = validationBase()..['wizard_step'] = bad;
        expect(validateConfig(data).any((p) => p.contains('wizard_step')),
            isTrue,
            reason: 'wizard_step $bad');
      }
    });

    test('sentExcusesLimitDefaultsToZeroAndValidates', () {
      expect(canonicalDefaults['sent_excuses_limit'], 0);
      expect(defaultConfig()['sent_excuses_limit'], 0);
      for (final ok in [0, 1, 100]) {
        final data = validationBase()..['sent_excuses_limit'] = ok;
        expect(validateConfig(data), isEmpty,
            reason: 'sent_excuses_limit $ok');
      }
      for (final bad in <Object>[-1, -5, 'ten', '1.5', <int>[1]]) {
        final data = validationBase()..['sent_excuses_limit'] = bad;
        expect(
            validateConfig(data).any((p) => p.contains('sent_excuses_limit')),
            isTrue,
            reason: 'sent_excuses_limit $bad');
      }
    });
  });

  group('configManager', () {
    test('missingConfigInitializesDefaultsWithoutExit', () {
      final cfg = ConfigManager('${tmp.path}/non_existent_config.json');
      expect(cfg.data, isMap);
      expect(cfg.data.containsKey('late_income_excuses'), isTrue);
      expect(cfg.data.containsKey('short_absence_excuses'), isTrue);
      expect((cfg.data['late_income_excuses'] as List).isNotEmpty, isTrue);
    });

    test('getAndSet', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      cfg.set('custom_key', 'custom_val');
      expect(cfg.get('custom_key'), 'custom_val');
      expect(cfg.get('non_existent_key', 'default_val'), 'default_val');
    });

    test('setPasswordAutoEncryption', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      cfg.set('bakalari_password', 'SecretPassword123!');
      final stored = cfg.get('bakalari_password');
      expect(stored, isNot('SecretPassword123!'));
      expect(cfg.get('bakalari_password_encrypted'), isTrue);
      expect(decrypt('$stored'), 'SecretPassword123!');
    });

    test('preventDoubleEncryption', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      cfg.set('bakalari_password', 'SecretPassword123!');
      final encryptedFirst = cfg.get('bakalari_password');
      cfg.set('bakalari_password', encryptedFirst);
      expect(cfg.get('bakalari_password'), encryptedFirst);
    });

    test('saveAndReload', () {
      final configPath = '${tmp.path}/config.json';
      final cfg = ConfigManager(configPath);
      cfg.set('your_signature', 'Jan Novák');
      cfg.save();
      expect(File(configPath).existsSync(), isTrue);

      final diskData = jsonDecode(File(configPath).readAsStringSync()) as Map;
      diskData['your_signature'] = 'Petr Svoboda';
      File(configPath).writeAsStringSync(jsonEncode(diskData));

      cfg.reload();
      expect(cfg.get('your_signature'), 'Petr Svoboda');
    });

    test('loadMergesDefaultsOnPartialConfig', () {
      final configPath = '${tmp.path}/partial_config.json';
      File(configPath).writeAsStringSync(jsonEncode({
        'bakalari_username': 'student1',
        'bakalari_url': 'https://skola.cz',
      }));
      final cfg = ConfigManager(configPath);
      expect(cfg.get('bakalari_username'), 'student1');
      expect(cfg.get('bakalari_url'), 'https://skola.cz');
      expect(cfg.get('excuse_mode'), 'confirm');
      expect(cfg.get('strava_order_mode'), 'confirm');
      expect(cfg.get('language'), 'cs');
      expect(cfg.get('late_income_excuses'), isList);
    });

    test('blacklistManagement', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      cfg.setAndSave('strava_blacklist', '${tmp.path}/bl.json');
      expect(cfg.getBlacklist(), isEmpty);
      expect(cfg.addBlacklistItem('vepřové'), isTrue);
      expect(cfg.addBlacklistItem('vepřové'), isFalse);
      expect(cfg.getBlacklist(), contains('vepřové'));
      expect(cfg.removeBlacklistItem('vepřové'), isTrue);
      expect(cfg.getBlacklist(), isNot(contains('vepřové')));
    });

    test('historyManagement', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      final histPath = '${tmp.path}/history.json';
      cfg.setAndSave('already_excused_file', histPath);
      expect(cfg.getExcuseHistory(), isEmpty);
      File(histPath).writeAsStringSync(jsonEncode([
        {'type': 'income', 'starting_day': '01.09.2026'}
      ]));
      expect(cfg.getExcuseHistory(), hasLength(1));
    });

    test('blacklistExampleFallback', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      final blPath = '${tmp.path}/strava_blacklist.json';
      File('${tmp.path}/strava_blacklist.example.json')
          .writeAsStringSync(jsonEncode(['rybí', 'vepřový']));
      cfg.setAndSave('strava_blacklist', blPath);
      // A missing blacklist means "no bans" — the example template
      // must never leak into the live filter path.
      expect(cfg.getBlacklist(), isEmpty);
      cfg.addBlacklistItem('kuřecí');
      expect(File(blPath).existsSync(), isTrue);
      expect(cfg.getBlacklist(), contains('kuřecí'));
    });

    test('blacklistFiltersTemplatePlaceholders', () {
      final blPath = '${tmp.path}/strava_blacklist.json';
      File(blPath).writeAsStringSync(
          jsonEncode(['YOUR_BLACKLIST_EXAMPLE', 'vepřové']));
      final cfg = ConfigManager('${tmp.path}/config.json');
      cfg.setAndSave('strava_blacklist', blPath);
      expect(cfg.getBlacklist(), ['vepřové']);
    });

    test('historyExampleFallback', () {
      final cfg = ConfigManager('${tmp.path}/config.json');
      final histPath = '${tmp.path}/already_excused_lessons.json';
      File('${tmp.path}/already_excused_lessons.example.json')
          .writeAsStringSync(jsonEncode([
        {'type': 'pure days', 'starting_day': '01.09.2026'}
      ]));
      cfg.setAndSave('already_excused_file', histPath);
      expect(cfg.getExcuseHistory(), hasLength(1));
    });
  });

  group('legacyAliasValidation', () {
    test('legacyAliasesPass', () {
      final problems = validateConfig(
          {'use_strava': true, 'strava_user': 's', 'strava_id': '1'});
      expect(problems.any((p) => p.contains('Strava')), isFalse);
    });

    test('missingBothStillFlagged', () {
      final problems = validateConfig({'use_strava': true});
      expect(problems.any((p) => p.contains('username')), isTrue);
      expect(problems.any((p) => p.contains('canteen')), isTrue);
    });
  });

  group('validatorGaps', () {
    test('badExcuseSelectionRejected', () {
      final data = validationBase();
      data['default_excuse_selection'] = 'sometimes';
      expect(
          validateConfig(data)
              .any((p) => p.contains('default_excuse_selection')),
          isTrue);
    });

    test('weekCapsRejected', () {
      final data = validationBase();
      data['go_back_weeks'] = 99;
      data['go_forward_weeks'] = 99;
      final problems = validateConfig(data);
      expect(problems.any((p) => p.contains('go_back_weeks')), isTrue);
      expect(problems.any((p) => p.contains('go_forward_weeks')), isTrue);
    });

    test('weekCapsAcceptBounds', () {
      final data = validationBase();
      data['go_back_weeks'] = 52;
      data['go_forward_weeks'] = 8;
      expect(validateConfig(data), isEmpty);
    });

    test('explicitNullKeepsDefault', () {
      final cfgPath = '${tmp.path}/c.json';
      File(cfgPath).writeAsStringSync(jsonEncode(
          {'theme': null, 'go_back_weeks': null, 'language': 'en'}));
      final mgr = ConfigManager(cfgPath);
      expect(mgr.data['theme'], 'dark');
      expect(mgr.data['go_back_weeks'], 4);
      expect(mgr.data['language'], 'en');
    });
  });

  group('canonicalConfig', () {
    test('legacyKeysAreIgnored', () {
      final mgr = ConfigManager('${tmp.path}/c.json');
      mgr.data = Map<String, Object?>.of(
          canonicalDefaults.map((k, v) => MapEntry(k, v as Object?)));
      mgr.data.addAll({
        'strava_enable': false,
        'strava_user': 'jan',
        'strava_id': '1234',
        'confirm_excuses': false,
      });
      // No migration: canonical values stand, legacy keys unread.
      expect(mgr.get('use_strava'), isTrue);
      expect(mgr.get('strava_username'), '');
      expect(mgr.get('excuse_mode'), 'confirm');
    });

    test('canonicalKeysUsedVerbatim', () {
      final mgr = ConfigManager('${tmp.path}/c.json');
      mgr.data = Map<String, Object?>.of(
          canonicalDefaults.map((k, v) => MapEntry(k, v as Object?)));
      mgr.data.addAll({'use_strava': false, 'excuse_mode': 'auto'});
      expect(mgr.get('use_strava'), isFalse);
      expect(mgr.get('excuse_mode'), 'auto');
    });

    test('validateCatchesBadModeAndThresholds', () {
      final problems = validateConfig({
        'bakalari_username': 'x',
        'bakalari_url': '',
        'use_strava': false,
        'excuse_mode': 'sometimes',
        'strava_order_mode': 'confirm',
        'absence_warn_pct': 30,
        'absence_critical_pct': 20,
        'theme': 'neon',
      });
      expect(problems.any((p) => p.contains('excuse_mode')), isTrue);
      expect(
          problems.any((p) =>
              p.toLowerCase().contains('warn') ||
              p.toLowerCase().contains('threshold')),
          isTrue);
      expect(problems.any((p) => p.contains('Theme')), isTrue);
    });

    test('managerSetGetCanonical', () {
      final cfg = ConfigManager('${tmp.path}/c.json');
      cfg.set('strava_canteen_id', '999');
      expect(cfg.get('strava_canteen_id'), '999');
      cfg.set('excuse_mode', 'auto');
      expect(cfg.get('excuse_mode'), 'auto');
    });
  });

  group('firstRunKeys', () {
    test('stravaOnlyCredentialsRecognized', () {
      final (bak, strava) = hasValidCredentials({
        'bakalari_username': '',
        'bakalari_url': '',
        'strava_username': 'student',
        'strava_canteen_id': '1950',
      });
      expect(bak, isFalse);
      expect(strava, isTrue);
    });

    test('legacyStravaAliasRecognized', () {
      final (bak, strava) = hasValidCredentials({
        'bakalari_username': '',
        'bakalari_url': '',
        'strava_user': 'student',
        'strava_id': '1950',
      });
      expect(bak, isFalse);
      expect(strava, isTrue);
    });

    test('examplePlaceholdersRejected', () {
      expect(
          hasValidCredentials({
            'bakalari_username': 'VAS_BAKALARI_LOGIN',
            'bakalari_url': 'https://vas-bakalari-portal.cz',
            'strava_username': 'x',
            'strava_canteen_id': 'CISLO_JIDELNY',
          }),
          (false, false));
    });
  });

  group('credentialsPlaceholders', () {
    test('exampleStravaLoginRejected', () {
      final (bak, strava) = hasValidCredentials({
        'bakalari_username': 'student',
        'bakalari_url': 'https://skola.cz',
        'strava_username': 'VAS_STRAVA_LOGIN',
        'strava_canteen_id': '1950',
      });
      expect(bak, isTrue);
      expect(strava, isFalse);
    });

    test('realCredentialsAccepted', () {
      expect(
          hasValidCredentials({
            'bakalari_username': 'novak',
            'bakalari_url': 'https://skola.cz',
            'strava_username': 'novak',
            'strava_canteen_id': '1950',
          }),
          (true, true));
    });

    test('stravaOnly recognized', () {
      expect(
          hasValidCredentials({
            'bakalari_url': '',
            'bakalari_username': '',
            'strava_username': 'novak',
            'strava_canteen_id': '123',
          }),
          (false, true));
    });
  });

  group('saveLock', () {
    test('saveRefusesWhenLockBusy', () {
      final configPath = '${tmp.path}/config.json';
      File(configPath).writeAsStringSync(jsonEncode({'theme': 'dark'}));
      final mgr = ConfigManager(configPath);
      mgr.set('theme', 'light');
      final busy = InterProcessLock('$configPath.lock');
      expect(busy.acquire(), isTrue);
      try {
        expect(() => mgr.save(), throwsStateError);
        expect(
            (jsonDecode(File(configPath).readAsStringSync()) as Map)['theme'],
            'dark');
      } finally {
        busy.release();
      }
      // The edit was kept and goes out with the next save.
      mgr.save();
      expect(
          (jsonDecode(File(configPath).readAsStringSync()) as Map)['theme'],
          'light');
    });
  });

  group('f3AutoCancelConfig', () {
    test('defaultIsTrueAndRejectsNonBoolean', () {
      expect(canonicalDefaults['strava_auto_cancel_lunches'], isTrue);
      final mgr = ConfigManager('${tmp.path}/c_f3.json');
      expect(mgr.get('strava_auto_cancel_lunches'), isTrue);

      final okCfg = validationBase();
      okCfg['strava_auto_cancel_lunches'] = false;
      expect(validateConfig(okCfg), isEmpty);

      final badCfg = validationBase();
      badCfg['strava_auto_cancel_lunches'] = 'yes';
      expect(
          validateConfig(badCfg)
              .any((p) => p.contains('strava_auto_cancel_lunches')),
          isTrue);
    });
  });

  group('f4BackgroundRefreshConfig', () {
    test('defaultIsTrueAndRejectsNonBoolean', () {
      expect(canonicalDefaults['background_refresh'], isTrue);
      final mgr = ConfigManager('${tmp.path}/c_f4.json');
      expect(mgr.get('background_refresh'), isTrue);

      final okCfg = validationBase();
      okCfg['background_refresh'] = false;
      expect(validateConfig(okCfg), isEmpty);

      final badCfg = validationBase();
      badCfg['background_refresh'] = 'no';
      expect(
          validateConfig(badCfg)
              .any((p) => p.contains('background_refresh')),
          isTrue);
    });
  });
}
