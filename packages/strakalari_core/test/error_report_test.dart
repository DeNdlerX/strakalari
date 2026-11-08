// Error report redaction and report builders.
//
// Port of tests/test_error_report.py + tests/test_log_redaction.py (the
// core cases: redaction, report content, timeout classification). The
// Flet/AppState cases (dialogs, clipboard service, Shell, report_error
// wiring) have no Dart counterpart yet: core owns the builders, the app
// owns the dialog.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/error_report.dart';
import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

void main() {
  Directory? tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('error_report_test_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp!.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    clearKeyCache();
  });
  tearDown(() {
    setEnvironmentOverride(null);
    setLanguage('cs');
    if (tmp != null && tmp!.existsSync()) tmp!.deleteSync(recursive: true);
  });

  group('redactConfig', () {
    test('exposesOnlyPresence', () {
      final config = <String, Object?>{
        'bakalari_url': 'https://school.example.cz',
        'bakalari_username': 'student',
        'bakalari_password': 'hunter2-hunter2',
        'strava_password': 'lunch-secret',
        'gemini_api_key': 'AIza-secret-value',
        'bakalari_password_encrypted': false,
        'check_interval_minutes': 60,
        'empty_slot': '',
        'no_value': null,
      };
      final redacted = redactConfig(config);
      expect(redacted['bakalari_password'], 'set');
      expect(redacted['bakalari_url'], 'set');
      expect(redacted['bakalari_username'], 'set');
      // False is a real choice, not an empty value.
      expect(redacted['bakalari_password_encrypted'], 'set');
      expect(redacted['check_interval_minutes'], 'set');
      expect(redacted['empty_slot'], 'empty');
      expect(redacted['no_value'], 'empty');
      // No value survives — the whole point of presence-only redaction.
      final blob = redacted.values.join(' ');
      for (final secret in [
        'hunter2-hunter2',
        'lunch-secret',
        'AIza-secret-value',
        'https://school.example.cz',
        'student',
      ]) {
        expect(blob, isNot(contains(secret)));
      }
      // Original untouched.
      expect(config['bakalari_password'], 'hunter2-hunter2');
    });
  });

  group('isTimeoutError', () {
    test('classification', () {
      expect(
          isTimeoutError(
              TimeoutException('Timeout 30000ms exceeded.')), isTrue);
      expect(isTimeoutError(TimeoutException('login timed out')), isTrue);
      expect(
          isTimeoutError(Exception(
              'Timeout 250ms exceeded. (budget 30000ms in 250ms slices)')),
          isTrue);
      expect(isTimeoutError(StateError('boom')), isFalse);
      expect(isTimeoutError(Exception('net::ERR_CONNECTION_REFUSED')),
          isFalse);
      expect(isTimeoutError(StateError('cancelled')), isFalse);
      expect(isTimeoutError(null), isFalse);
      try {
        throw const UserError('Chybí URL Bakalářů — doplňte ho v Nastavení.');
      } on UserError catch (exc) {
        expect(isTimeoutError(exc), isFalse);
      }
    });
  });

  group('timeoutUserMessage', () {
    test('namesFix', () {
      final text = timeoutUserMessage();
      expect(text, anyOf(contains('Nastavení'), contains('Settings')));
      expect(text, anyOf(contains('síti'), contains('network')));
    });
  });

  group('redactText', () {
    test('scrubsSecretValues', () {
      final config = <String, Object?>{
        'bakalari_password': 'hunter2-hunter2',
        'other': 'x',
      };
      const text = 'login failed for hunter2-hunter2 at school';
      expect(redactText(text, config), isNot(contains('hunter2-hunter2')));
      expect(redactText(text, config), contains(redacted));
    });

    test('numericAndShort', () {
      final config = <String, Object?>{
        'api_token': 12345,
        'pin_token': 'abc',
      };
      expect(redactText('key 12345 used', config), isNot(contains('12345')));
      expect(redactText('use abc now', config), isNot('use abc now'));
      // ...but prose without the token is untouched.
      expect(redactText('nothing here', config), 'nothing here');
    });

    test('scrubsDecryptedPasswordAndPersonalData', () {
      final config = <String, Object?>{
        'bakalari_password': encrypt('Tajne-Heslo-42'),
        'bakalari_password_encrypted': true,
        'bakalari_username': 'novak.jan',
        'your_signature': 'Jan Novák, 3.B',
      };
      const text = 'locator.fill("Tajne-Heslo-42") for novak.jan\n'
          'signed Jan Novák, 3.B / Novák';
      final out = redactText(text, config);
      for (final leaked in ['Tajne-Heslo-42', 'novak.jan', 'Novák']) {
        expect(out, isNot(contains(leaked)));
      }
    });
  });

  group('secretValues', () {
    test('plaintextAndCiphertextSecretsAreScrubbed', () {
      final cipher = encrypt('hunter2-secret');
      final config = <String, Object?>{
        'bakalari_password': cipher,
        'bakalari_password_encrypted': true,
        'bakalari_username': 'novak.jan',
      };
      final values = secretValues(config);
      final redactedLog = redactValues(
          "fill('#password', 'hunter2-secret') failed; raw=$cipher", values);
      expect(redactedLog, isNot(contains('hunter2-secret')));
      expect(redactedLog, isNot(contains(cipher)));
      expect(redactedLog, contains(redacted));
      // Not a report: the user's own name may stay in their own log.
      expect(redactValues('user novak.jan logged in', values),
          contains('novak.jan'));
    });

    test('followsChangedPassword', () {
      final before = secretValues(<String, Object?>{
        'strava_password': 'old-pass-1',
        'strava_password_encrypted': false,
      });
      expect(redactValues('leak old-pass-1 here', before),
          isNot(contains('old-pass-1')));
      final after = secretValues(<String, Object?>{
        'strava_password': 'new-pass-2',
        'strava_password_encrypted': false,
      });
      expect(redactValues('leak new-pass-2 here', after),
          isNot(contains('new-pass-2')));
    });

    test('skipPersonalData', () {
      expect(
          secretValues(<String, Object?>{
            'gemini_api_key': 'AIzaKEY123',
            'your_signature': 'Jan Novák',
          }),
          {'AIzaKEY123'});
    });
  });

  group('buildReport', () {
    test('carriesDiagnostics', () {
      late final String tb;
      try {
        throw StateError('bad week number');
      } catch (e, st) {
        tb = currentTraceback(e, st);
      }
      final report = buildReport(
        'refresh (all)',
        'ValueError: bad week number',
        tracebackStr: tb,
        logTail: const ['[10:00:01] Stahuji data z Bakalářů…'],
        config: {'bakalari_url': 'https://x.example'},
        extra: {'scope': 'all'},
      );
      expect(report['operation'], 'refresh (all)');
      expect(report['traceback'], contains('bad week number'));
      expect(report['context'], isA<Map<String, Object?>>());
      expect((report['context'] as Map<String, Object?>)['app_version'],
          isNotEmpty);
      expect(
          (report['context'] as Map<String, Object?>)['platform'], isNotEmpty);
      expect(report['log_tail'], ['[10:00:01] Stahuji data z Bakalářů…']);
      expect(
          (report['config'] as Map<String, String>)['bakalari_url'], 'set');

      final text = formatReport(report);
      for (final needle in [
        'Strakalari error report',
        'operation: refresh (all)',
        'ValueError',
        'recent log',
        'config (values hidden',
      ]) {
        expect(text, contains(needle));
      }
    });

    test('extraSecretsRedacted', () {
      final config = <String, Object?>{
        'bakalari_password': 's3cr3t-pass',
        'pin_token': '123',
        'num_secret': 12345,
      };
      final report = buildReport('op', 'boom',
          config: config,
          extra: const {
            'label': 'leak s3cr3t-pass here',
            'pin': 'code 123 done',
          });
      final text = formatReport(report);
      expect(text, isNot(contains('s3cr3t-pass')));
      // Short PIN redacted on token boundaries.
      expect(text, isNot(contains('code 123 done')));
      expect(text, contains(redacted));
    });

    test('logTailIsContextNotTracebackCopy', () {
      late final String tb;
      try {
        throw StateError('boom');
      } catch (e, st) {
        tb = currentTraceback(e, st);
      }
      final report = buildReport(
        'refresh (all)',
        'StateError: boom',
        tracebackStr: tb,
        logTail: [for (var i = 0; i < 80; i++) 'step $i'],
      );
      final tail = report['log_tail'] as List;
      expect(tail, hasLength(logTailLines));
      expect(tail.last, endsWith('step 79')); // what the app did right before
      expect(tail.any((line) => '$line'.contains('Traceback')), isFalse);
      expect(report['traceback'], contains('Traceback'));
    });

    test('neverContainsSecrets', () {
      late final String tb;
      try {
        throw StateError('boom hunter2-hunter2');
      } catch (e, st) {
        tb = currentTraceback(e, st);
      }
      final report = buildReport(
        'refresh (all)',
        'StateError: boom hunter2-hunter2',
        tracebackStr: tb,
        config: {'bakalari_password': 'hunter2-hunter2'},
      );
      final text = formatReport(report);
      expect(text, isNot(contains('hunter2-hunter2')));
      expect(text, contains('boom'));
    });
  });

  group('shortSummary', () {
    test('prefersTypeAndFirstLine', () {
      expect(shortSummary(StateError('timeout\nsecond line')),
          'StateError: Bad state: timeout');
      expect(shortSummary(null, 'plain'), 'plain');
      expect(shortSummary(null, ''), 'unknown error');
    });
  });

  group('collectContext', () {
    test('namesBuildAndLanguage', () {
      final ctx = collectContext();
      expect(ctx['build'], isIn(['installer', 'source']));
      expect(ctx['language'], isIn(['cs', 'en']));
    });
  });

  group('clients', () {
    test('raiseUserErrorForMissingLogin', () async {
      expect(() => BakalariClient({}).bakalariSession(),
          throwsA(isA<UserError>()));
      expect(
          () => BakalariClient(
              {'bakalari_url': 'https://x.example'}).bakalariSession(),
          throwsA(isA<UserError>()));
      await expectLater(BakalariClient({}).login(),
          throwsA(isA<UserError>()));
    });
  });
}
