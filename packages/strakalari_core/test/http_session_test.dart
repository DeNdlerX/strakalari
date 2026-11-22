import 'dart:async';
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

    test('surviveScriptsAndStrayCharacters', () {
      // A `<` inside JavaScript or text is not a tag, and a stray `/` in a
      // tag must not stall the parser (the phone froze on the real Komens
      // page: this used to loop forever).
      const html = '<form id="formbaka">'
          '<script>if (a<b/2) { x = "<input name=\\"js\\" value=\\"1\\">"; }'
          '</script>'
          '<input name="a" value="1" / >'
          '<p>1 < 2 and <3</p>'
          '<input name="b" / value="2">'
          '</form><b';
      expect(formFields(html), <(String, String)>[('a', '1'), ('b', '2')]);
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
      // The fake throws ConnectFailure for its refused case, like the
      // production transport does for DNS + connect failures.
      final refused = ConnectFailure(SocketException(
          '[Errno 11001] getaddrinfo failed',
          osError: OSError('[Errno 11001] getaddrinfo failed', 11001)));
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

    test('connectTimeoutIsATimeoutNotUnreachable', () async {
      // Python: httpx.ConnectTimeout is a TimeoutException.
      for (final cause in [
        TimeoutException('connect'),
        SocketException('HTTP connection timed out after 0:00:20.000000'),
      ]) {
        final bak = session(_ThrowingTransport(ConnectFailure(cause)));
        await expectLater(
            bak.login(),
            throwsA(isA<UserError>().having(
                (e) => e.message, 'message', timeoutUserMessage())));
      }
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
      // F6 §4.1: neither login nor the cookie re-check downloads /dashboard.
      expect(server.calls('GET', '/dashboard'), isEmpty);
    });

    test('f6LoginSkipsDashboardAndRejectsForeignOrRootRedirects (R8a S8)',
        () async {
      // 1. Normal login makes zero GET /dashboard requests.
      final normalServer = FakeBakalari();
      final normalBak = session(normalServer);
      await normalBak.login();
      expect(normalBak.loggedIn, isTrue);
      expect(normalServer.calls('GET', '/dashboard'), isEmpty);

      // 2. GET /login -> 302 to another host is rejected (bak_no_login_page).
      final foreignGet = _ScriptedTransport([
        HttpResponseData(
          statusCode: 302,
          url: Uri.parse('$fakeRoot/login'),
          headers: {
            'location': ['https://evil.other.test/dashboard']
          },
        ),
      ]);
      await expectLater(
        session(foreignGet).login(),
        throwsA(isA<UserError>()),
      );

      // 3. GET /login -> 302 to `/` is rejected (bak_no_login_page).
      final rootGet = _ScriptedTransport([
        HttpResponseData(
          statusCode: 302,
          url: Uri.parse('$fakeRoot/login'),
          headers: {
            'location': ['$fakeRoot/']
          },
        ),
      ]);
      await expectLater(
        session(rootGet).login(),
        throwsA(isA<UserError>()),
      );

      // 4. POST /Login -> 302 to /login follows once and rejects with error text.
      final postToLogin = _ScriptedTransport([
        fakeReply(fakeLoginPage(), url: Uri.parse('$fakeRoot/login')),
        HttpResponseData(
          statusCode: 302,
          url: Uri.parse('$fakeRoot/Login'),
          headers: {
            'location': ['$fakeRoot/login?err=1']
          },
        ),
        fakeReply(
          fakeLoginPage('<div class="login-error">Špatné heslo</div>'),
          url: Uri.parse('$fakeRoot/login?err=1'),
        ),
      ]);
      await expectLater(
        session(postToLogin).login(),
        throwsA(isA<UserError>()
            .having((e) => e.message, 'message', contains('Špatné heslo'))),
      );
      expect(postToLogin.seen, hasLength(3));

      // 5. POST /Login -> 302 to another host follows and checks isLoginPage.
      final postToForeign = _ScriptedTransport([
        fakeReply(fakeLoginPage(), url: Uri.parse('$fakeRoot/login')),
        HttpResponseData(
          statusCode: 302,
          url: Uri.parse('$fakeRoot/Login'),
          headers: {
            'location': ['https://sso.other.test/check']
          },
        ),
        fakeReply(
          fakeLoginPage('<div class="login-error">SSO denied</div>'),
          url: Uri.parse('https://sso.other.test/check'),
        ),
      ]);
      await expectLater(
        session(postToForeign).login(),
        throwsA(isA<UserError>()
            .having((e) => e.message, 'message', contains('SSO denied'))),
      );
      expect(postToForeign.seen, hasLength(3));
    });

    test('droppedConnectionIsRetriedOnceForReads', () async {
      final server = FakeBakalari({
        'POST /Teaching/Subjects': {
          'data': <Object?>[]
        },
      });
      // Drop the subjects POST (call 3: login GET, login POST — no dashboard
      // GET after F6 §4.1 — then the read) — the retry must succeed.
      final flaky = _FlakyTransport(server, 3);
      final bak = session(flaky);
      await bak.login();
      final resp =
          await bak.request('POST', '/Teaching/Subjects');
      expect(resp.statusCode, 200);
      expect(flaky.calls, 4);
      expect(server.logins, 1);
    });

    test('tlsAndConnectErrorsAreNotRetried', () async {
      var tlsCalls = 0;
      final tlsTransport = _CountingErrorTransport(
        HandshakeException('certificate verify failed'),
        () => tlsCalls++,
      );
      final bakTls = session(tlsTransport);
      await expectLater(bakTls.login(), throwsA(isA<UserError>()));
      expect(tlsCalls, 1);

      var connectCalls = 0;
      final connectTransport = _CountingErrorTransport(
        ConnectFailure(SocketException('Connection refused')),
        () => connectCalls++,
      );
      final bakConn = session(connectTransport);
      await expectLater(bakConn.login(), throwsA(isA<UserError>()));
      expect(connectCalls, 1);
    });

    test('dartIoTransportWrapsConnectErrorAsNeverSent', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unusedPort = server.port;
      await server.close();
      final transport = DartIoHttpTransport();
      try {
        await expectLater(
          () => transport.send(
            'GET',
            Uri.parse('http://127.0.0.1:$unusedPort/bakaweb'),
            timeout: const Duration(milliseconds: 500),
          ),
          throwsA(
            isA<ConnectFailure>().having(
              (e) => isNeverSentCause(e),
              'isNeverSentCause',
              isTrue,
            ),
          ),
        );
      } finally {
        transport.close();
      }
    });
  });
}

class _CountingErrorTransport implements HttpTransport {
  final Object error;
  final void Function() onCall;
  _CountingErrorTransport(this.error, this.onCall);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) {
    onCall();
    return Future.error(error);
  }

  @override
  void close() {}
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

class _FlakyTransport implements HttpTransport {
  final HttpTransport inner;
  final int dropOnCall;
  int calls = 0;

  _FlakyTransport(this.inner, this.dropOnCall);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) {
    calls += 1;
    if (calls == dropOnCall) {
      throw SocketException(
          'Server disconnected without sending a response');
    }
    return inner.send(method, url,
        headers: headers, body: body, timeout: timeout);
  }

  @override
  void close() => inner.close();
}

class _ScriptedTransport implements HttpTransport {
  final List<HttpResponseData> replies;
  final List<(String, Uri)> seen = [];
  int _idx = 0;

  _ScriptedTransport(this.replies);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    seen.add((method, url));
    return replies[_idx++];
  }

  @override
  void close() {}
}
