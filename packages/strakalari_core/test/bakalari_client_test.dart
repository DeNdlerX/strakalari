import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';
import 'package:strakalari_core/src/error_report.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

import 'fake_bakalari.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bakalari_client_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    clearKeyCache();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('configParsing', () {
    test('goBackWeeksGarbageFallsBack', () {
      final bak = BakalariClient({'go_back_weeks': 'nonsense'});
      expect(bak.goBackWeeks, 4);
    });

    test('goBackWeeksExtremeIsClamped', () {
      final bak = BakalariClient({'go_back_weeks': 1000000000});
      expect(bak.goBackWeeks, lessThanOrEqualTo(52));
    });

    test('goForwardWeeksConfigParsing', () {
      final bak = BakalariClient({'go_forward_weeks': 3});
      expect(bak.goBackWeeks, 4);
      expect(bak.goForwardWeeks, 3);

      final clamped = BakalariClient({'go_forward_weeks': 99});
      expect(clamped.goForwardWeeks, lessThanOrEqualTo(8));

      final garbage = BakalariClient({'go_forward_weeks': 'nonsense'});
      expect(garbage.goForwardWeeks, 1);
    });
  });

  group('initialState', () {
    test('substitutionsInitIsUnknown', () {
      final bak = BakalariClient({});
      expect(bak.substitutions, isNull);
    });
  });

  group('sessionWiring', () {
    test('loginPostsTheFormOnceAndReusesTheSession', () async {
      final server = FakeBakalari({
        'POST /Teaching/Subjects': {
          'data': <Object?>[]
        },
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      await bak.bakalariSession().request('POST', '/Teaching/Subjects');
      await bak.bakalariSession().request('POST', '/Teaching/Subjects');
      expect(server.logins, 1);
    });

    test('unparseableOutboxSurfacesHttp500', () async {
      final server = FakeBakalari({
        'GET /next/komens.aspx': '<html>outbox</html>',
        'POST /next/komens.aspx': '<html>listing</html>',
        'POST /Komens/GetMessageDataAsync':
            HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      final session = bak.bakalariSession();
      await session.login();
      // The read itself surfaces the failure (fetch_sent_excuses, in
      // data.dart, turns it into unknown + an error string instead).
      await expectLater(session.request(
              'POST', '/Komens/GetMessageDataAsync'),
          throwsA(isA<UserError>().having((e) => e.message, 'message',
              contains('HTTP 500'))));
    });

    test('missingCredentialsRaiseUserError', () {
      expect(() => BakalariClient({}).bakalariSession(),
          throwsA(isA<UserError>()));
      expect(
          () => BakalariClient(
                  {'bakalari_url': 'https://x.example.test'})
              .bakalariSession(),
          throwsA(isA<UserError>()));
      expect(
          () => BakalariClient({
                'bakalari_url': 'https://x.example.test',
                'bakalari_username': 's',
              }).bakalariSession(),
          throwsA(isA<UserError>()));
    });

    test('undecryptablePasswordRaisesUserError', () {
      final bak = BakalariClient({
        'bakalari_url': 'https://x.example.test',
        'bakalari_username': 's',
        'bakalari_password': '!!!not-a-token!!!',
        'bakalari_password_encrypted': true,
      });
      expect(() => bak.bakalariSession(),
          throwsA(isA<UserError>().having((e) => e.message, 'message',
              contains('nelze rozšifrovat'))));
    });
  });
}
