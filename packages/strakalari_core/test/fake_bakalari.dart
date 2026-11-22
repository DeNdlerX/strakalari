// A tiny fake Bakaláři web server for the plain-HTTP client tests.
//
// Port of tests/fake_bakalari.py. Serves the login form and whatever
// routes a test registers, behind a session cookie. Never the network.
// All names and data are made up.
import 'dart:convert';

import 'package:clock/clock.dart';
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

  /// Optional sliding session lifetime in minutes (null = never expires,
  /// default for existing tests; set e.g. `15` for F6 §6.3 tests).
  final int? sessionMinutes;

  int logins = 0;
  int renewals = 0;
  String? _token;
  DateTime? _renewedAt;

  FakeBakalari([Map<String, Object?>? routes, this.sessionMinutes])
      : routes = {
          for (final e in (routes ?? {}).entries)
            e.key: _wrap(e.value)
        };

  static Object? Function(FakeRequest) _wrap(Object? value) {
    if (value is Object? Function(FakeRequest)) return value;
    return (_) => value;
  }

  /// Checks cookie validity + optional sliding expiry; returns `(valid, setCookieHeader)`.
  (bool, String?) _validateSession(FakeRequest request) {
    if (_token == null || request.headers['cookie'] != 'BakaAuth=$_token') {
      return (false, null);
    }
    final mins = sessionMinutes;
    if (mins == null || _renewedAt == null) return (true, null);
    final elapsed = clock.now().difference(_renewedAt!);
    final full = Duration(minutes: mins);
    if (elapsed >= full) {
      _token = null;
      _renewedAt = null;
      return (false, null);
    }
    final half = Duration(microseconds: full.inMicroseconds ~/ 2);
    if (elapsed >= half) {
      renewals += 1;
      _token = 't${logins}_r$renewals';
      _renewedAt = clock.now();
      return (true, 'BakaAuth=$_token; Path=/');
    }
    return (true, null);
  }

  HttpResponseData _withSetCookie(HttpResponseData resp, String? setCookie) {
    if (setCookie == null) return resp;
    final headers = <String, List<String>>{
      for (final e in resp.headers.entries) e.key: List<String>.of(e.value),
    };
    headers.putIfAbsent('set-cookie', () => []).add(setCookie);
    return HttpResponseData(
      statusCode: resp.statusCode,
      url: resp.url,
      headers: headers,
      bodyBytes: resp.bodyBytes,
    );
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
      final (valid, setCookie) = _validateSession(request);
      if (valid) {
        // A still-valid session goes straight into the app.
        return _withSetCookie(
          HttpResponseData(
            statusCode: 302,
            url: url,
            headers: {
              'location': ['$fakeRoot/dashboard']
            },
          ),
          setCookie,
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
        _renewedAt = clock.now();
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
    final (valid, setCookie) = _validateSession(request);
    if (!valid) {
      final ret = sessionMinutes != null
          ? '?ReturnUrl=${Uri.encodeQueryComponent(path)}'
          : '';
      return HttpResponseData(
        statusCode: 302,
        url: url,
        headers: {
          'location': ['$fakeRoot/login$ret']
        },
      );
    }
    if (path == '/dashboard') {
      return _withSetCookie(
          fakeReply('<html><body>dashboard</body></html>', url: url),
          setCookie);
    }
    final handler = routes['$method $path'];
    if (handler == null) {
      return _withSetCookie(
          HttpResponseData(statusCode: 404, url: url), setCookie);
    }
    return _withSetCookie(fakeReply(handler(request), url: url), setCookie);
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

/// A `/Marks/Widget` HTML fragment carrying [marks].
String marksWidgetHtml(List<Map<String, Object?>> marks) {
  final buf = StringBuffer('<div class="bk-widget-marks">');
  for (final m in marks) {
    final isNew = m['is_new'] == true;
    final cls = isNew ? 'mark-displayGrade isNew' : 'mark-displayGrade';
    buf.write('<div class="mark-line">');
    buf.write('<span class="$cls">${m['grade'] ?? ''}</span>');
    buf.write('<span class="mark-subjectName">${m['subject'] ?? ''}</span>');
    buf.write('<span class="mark-note">${m['note'] ?? ''}</span>');
    buf.write('<span class="mark-date">${m['date'] ?? ''}</span>');
    buf.write('</div>');
  }
  buf.write('</div>');
  return buf.toString();
}

/// A Komens outbox page HTML carrying the 3 WebForms hidden fields and period label.
String outboxPageHtml({
  String periodLabel = '20.8.2026 - 31.8.2027',
  String viewstate = 'vs-year',
  String viewstateGenerator = 'VSG12345',
  String eventValidation = 'ev-year',
}) =>
    '<form id="formbaka">'
    '<input type="hidden" name="__VIEWSTATE" value="$viewstate">'
    '<input type="hidden" name="__VIEWSTATEGENERATOR" value="$viewstateGenerator">'
    '<input type="hidden" name="__EVENTVALIDATION" value="$eventValidation">'
    '<input type="hidden" name="ctl00\$cphmain\$hfListType" id="hfListType" value="odeslane">'
    '<span id="cphmain_obdobiLabel">$periodLabel</span>'
    '</form>';
