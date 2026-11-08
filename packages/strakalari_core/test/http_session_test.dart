import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/cancel.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';
import 'package:strakalari_core/src/error_report.dart';

import 'fake_bakalari.dart';

BakalariSession session(
  HttpTransport transport, {
  String? password,
  bool Function()? isCancelled,
  List<String>? logs,
}) =>
    BakalariSession(
      fakeConfig['bakalari_url']!,
      fakeConfig['bakalari_username']!,
      () => password ?? fakePassword,
      transport: transport,
      isCancelled: isCancelled,
      logger: logs?.add,
    );

void main() {
  group('appRoot', () {
    test('dropsPageNames', () {
      expect(appRoot('bakaweb.example.test'),
          'https://bakaweb.example.test');
      expect(appRoot('https://x.example.test/login'),
          'https://x.example.test');
      expect(appRoot('https://x.example.test/bakaweb/next/komens.aspx'),
          'https://x.example.test/bakaweb');
      expect(appRoot(''), '');
    });
  });

  group('formFields', () {
    test('areWhatABrowserSubmits', () {
      const html = '<form id="other"><input name="x" value="1"></form>'
          '<form id="formbaka"><input name="a" value="1">'
          '<input type="submit" name="s">'
          '<input type="checkbox" name="c1">'
          '<input type="checkbox" name="c2" checked>'
          '<select name="sel"><option value="p">P</option>'
          '<option value="q" selected>Q</option>'
          '</select><textarea name="t">text</textarea></form>';
      expect(formFields(html),
          <(String, String)>[('a', '1'), ('c2', 'on'), ('sel', 'q'), ('t', 'text')]);
    });
  });

  group('dxCallbackResult', () {
    String reply(String resultHtml) =>
        '0|/*DX*/({\'id\':0,\'result\':$resultHtml})';

    test('readsTheResultOrRaises', () {
      expect(dxCallbackResult(reply('"<b>x</b>\\n"')), '<b>x</b>\n');
      expect(dxCallbackResult("1|/*DX*/({'id':0,'result':'a\\'b\\u0041'})"),
          "a'bA");
      expect(
          () => dxCallbackResult(
              "0|/*DX*/({'id':0,'error':{'message':'boom'}})"),
          throwsStateError);
      expect(() => dxCallbackResult('<html>login</html>'),
          throwsArgumentError);
    });
  });

  group('login', () {
    test('postsTheFormOnceAndReusesTheSession', () async {
      final server = FakeBakalari({
        'POST /Teaching/Subjects': {'data': <Object?>[]},
      });
      final bak = session(server);
      await bak.request('POST', '/Teaching/Subjects');
      await bak.request('POST', '/Teaching/Subjects');
      expect(server.logins, 1);
    });

    test('rejectedLoginRaisesUserErrorWithTheReason', () async {
      final bak = session(FakeBakalari(), password: 'spatne');
      await expectLater(
          bak.login(),
          throwsA(isA<UserError>().having((e) => e.message, 'message',
              contains('Nesprávné jméno nebo heslo'))));
    });

    test('wrongAddressSaysSo', () async {
      for (final reply in [
        HttpResponseData(
            statusCode: 404,
            url: Uri.parse('$fakeRoot/login'),
            bodyBytes: [78, 111, 116]),
        HttpResponseData(
            statusCode: 200,
            url: Uri.parse('$fakeRoot/login'),
            headers: {
              'content-type': ['text/html']
            },
            bodyBytes: [60, 104, 116, 109, 108, 62]),
      ]) {
        final bak = session(_FixedTransport(reply));
        await expectLater(
            bak.login(),
            throwsA(isA<UserError>().having((e) => e.message,
                'message', contains('bakalari.example.test'))));
      }
    });

    test('serverErrorAtLoginIsNeverALogin', () async {
      final bak = session(_FixedTransport(HttpResponseData(
        statusCode: 503,
        url: Uri.parse('$fakeRoot/login'),
        bodyBytes: [120],
      )));
      await expectLater(
          bak.login(),
          throwsA(isA<UserError>().having((e) => e.message, 'message',
              contains('HTTP 503'))));
    });

    test('networkFailuresExplainThemselves', () async {
      final refused = SocketException(
          '[Errno 11001] getaddrinfo failed',
          osError: OSError('[Errno 11001] getaddrinfo failed', 11001));
      final bak = session(_ThrowingTransport(refused));
      await expectLater(
          bak.login(),
          throwsA(isA<UserError>().having((e) => e.message, 'message',
              contains('bakalari.example.test'))));
      final dropped =
          SocketException('Server disconnected without sending a response');
      final bak2 = session(_ThrowingTransport(dropped));
      await expectLater(
          bak2.login(),
          throwsA(isA<UserError>().having(
              (e) => e.message,
              'message',
              anyOf(contains('přerušilo'), contains('interrupted')))));
    });

    test('cancelStopsBeforeAnyRequest', () async {
      final server = FakeBakalari();
      final bak =
          session(server, isCancelled: () => true);
      await expectLater(bak.request('GET', '/Teaching/Subjects'),
          throwsA(isA<CancelledError>()));
      expect(server.requests, isEmpty);
    });

    test('stillValidSessionNeedsNoNewLogin', () async {
      final server = FakeBakalari();
      final bak = session(server);
      await bak.login();
      bak.loggedIn = false; // e.g. a new run with the same cookies
      await bak.login();
      expect(server.logins, 1);
      expect(bak.loggedIn, isTrue);
    });
  });
}

class _FixedTransport implements HttpTransport {
  final HttpResponseData reply;
  _FixedTransport(this.reply);

  @override
  Future<HttpResponseData> send(String method, Uri url,
          {Map<String, String>? headers,
          List<int>? body,
          Duration timeout = const Duration(seconds: 60)}) async =>
      HttpResponseData(
        statusCode: reply.statusCode,
        url: url,
        headers: reply.headers,
        bodyBytes: reply.bodyBytes,
      );

  @override
  void close() {}
}

class _ThrowingTransport implements HttpTransport {
  final Object error;
  _ThrowingTransport(this.error);

  @override
  Future<HttpResponseData> send(String method, Uri url,
          {Map<String, String>? headers,
          List<int>? body,
          Duration timeout = const Duration(seconds: 60)}) =>
      Future.error(error);

  @override
  void close() {}
}
