// A tiny fake Bakaláři web server for the plain-HTTP client tests.
//
// Port of tests/fake_bakalari.py. Serves the login form and whatever
// routes a test registers, behind a session cookie. Never the network.
// All names and data are made up.
import 'dart:convert';

import 'package:strakalari_core/src/bakalari/http_session.dart';

const String fakeRoot = 'https://bakalari.example.test';
const String fakeUser = 'student';
const String fakePassword = 'heslo';

const Map<String, String> fakeConfig = {
  'bakalari_url': '$fakeRoot/login',
  'bakalari_username': fakeUser,
  'bakalari_password': fakePassword,
};

String fakeLoginPage([String error = '']) =>
    '<html><body>\n<form id="formlogin" method="post" action="/login">\n'
    '<input type="hidden" name="returnUrl" value="">\n'
    '<input id="username" name="username" type="text" value="">\n'
    '<input id="password" name="password" type="password">\n'
    '<button id="loginButton" type="submit" name="login" formaction="/Login">'
    'Přihlásit</button>\n</form>$error</body></html>';

HttpResponseData fakeReply(Object? value,
    {int status = 200, Uri? url}) {
  if (value is HttpResponseData) return value;
  if (value is String) {
    return HttpResponseData(
      statusCode: status,
      url: url ?? Uri.parse(fakeRoot),
      headers: {
        'content-type': ['text/html; charset=utf-8']
      },
      bodyBytes: utf8.encode(value),
    );
  }
  return HttpResponseData(
    statusCode: status,
    url: url ?? Uri.parse(fakeRoot),
    headers: {
      'content-type': ['application/json']
    },
    bodyBytes: utf8.encode(jsonEncode(value)),
  );
}

/// `routes` maps `"METHOD /path"` to a reply: HTML text, JSON data, an
/// [HttpResponseData], or a function taking the request.
class FakeBakalari implements HttpTransport {
  final Map<String, Object? Function(FakeRequest)> routes;
  final List<FakeRequest> requests = [];
  int logins = 0;
  String? _token;

  FakeBakalari([Map<String, Object?>? routes])
      : routes = {
          for (final e in (routes ?? {}).entries)
            e.key: _wrap(e.value)
        };

  static Object? Function(FakeRequest) _wrap(Object? value) {
    if (value is Object? Function(FakeRequest)) return value;
    return (_) => value;
  }

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    final request = FakeRequest(
        method: method,
        url: url,
        headers: Map.of(headers ?? {}),
        body: body ?? []);
    requests.add(request);
    final path = url.path;
    if (method == 'GET' && path == '/login') {
      if (_token != null &&
          request.headers['cookie'] == 'BakaAuth=$_token') {
        // A still-valid session goes straight into the app.
        return HttpResponseData(
          statusCode: 302,
          url: url,
          headers: {
            'location': ['$fakeRoot/dashboard']
          },
        );
      }
      return fakeReply(fakeLoginPage(), url: url);
    }
    if (method == 'POST' && path == '/Login') {
      final form = Uri.splitQueryString(
          utf8.decode(request.body, allowMalformed: true));
      if (form['username'] == fakeUser &&
          form['password'] == fakePassword) {
        logins += 1;
        _token = 't$logins';
        return HttpResponseData(
          statusCode: 302,
          url: url,
          headers: {
            'location': ['$fakeRoot/dashboard'],
            'set-cookie': ['BakaAuth=$_token; Path=/'],
          },
        );
      }
      return fakeReply(
          fakeLoginPage(
              '<div class="login-error">Nesprávné jméno nebo heslo</div>'),
          url: url);
    }
    if (_token == null ||
        request.headers['cookie'] != 'BakaAuth=$_token') {
      return HttpResponseData(
        statusCode: 302,
        url: url,
        headers: {
          'location': ['$fakeRoot/login']
        },
      );
    }
    if (path == '/dashboard') {
      return fakeReply('<html><body>dashboard</body></html>', url: url);
    }
    final handler = routes['$method $path'];
    if (handler == null) {
      return HttpResponseData(statusCode: 404, url: url);
    }
    return fakeReply(handler(request), url: url);
  }

  /// Requests matching [method] and [path], in order.
  List<FakeRequest> calls(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == path)
      .toList();

  void expireSession() {
    _token = null;
  }

  @override
  void close() {}
}

class FakeRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> body;

  FakeRequest(
      {required this.method,
      required this.url,
      required this.headers,
      required this.body});
}

/// A `/Timetable/GetContentData` reply holding `details` (one atom each).
Map<String, Object?> weekContent(List<Object?> details) => {
      'Days': [
        {
          'Hours': [
            {
              'Atoms': [
                for (final d in details)
                  {
                    'TooltipDetails':
                        jsonEncode(d, toEncodable: (e) => '$e'),
                  }
              ]
            }
          ]
        }
      ]
    };

/// A DevExpress callback reply carrying [resultHtml].
String dxReply(String resultHtml) =>
    '0|/*DX*/({\'id\':0,\'result\':${jsonEncode(resultHtml)}})';
