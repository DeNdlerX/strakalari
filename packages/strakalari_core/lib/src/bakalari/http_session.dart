// Bakaláři web over plain HTTP: session, login and WebForms helpers.
//
// Port of strakalari/core/bakalari_http.py. Talks to the same pages and
// endpoints the Bakaláři web app uses itself (never the mobile API): the
// login form, the pages' own JSON endpoints and, for the WebForms
// (`.aspx`) pages, form posts and DevExpress callbacks rebuilt from the
// page's raw HTML.
//
// Redirects are followed by hand (302/303 -> GET), storing cookies at
// every hop — `dart:io` only follows redirects for GET/HEAD, and a
// transparent client would swallow the `Set-Cookie` on the login 302.
// Transports are injectable ([HttpTransport]); production runs on
// `dart:io`, tests use a fake Bakaláři server (no `package:http`:
// its client follows redirects transparently, which would hide the
// login cookie — see STATUS.md).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html_unescape/html_unescape.dart';

import '../error_report.dart';
import '../automation/cancel.dart';
import '../i18n.dart';

/// Web root of the configured Bakaláři URL, without a trailing slash.
///
/// Users paste whatever the address bar showed (`bakaweb.x.cz`,
/// `https://bakaweb.x.cz/login`, `…/next/komens.aspx`); page names
/// are dropped so a school hosted under a sub-path keeps that path.
String appRoot(Object? url) {
  var raw = '${url ?? ''}'.trim();
  if (raw.isEmpty) return '';
  if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
    raw = 'https://$raw';
  }
  final parts = Uri.parse(raw);
  final segments =
      parts.path.split('/').where((s) => s.isNotEmpty).toList();
  while (segments.isNotEmpty &&
      (['login', 'dashboard', 'next']
              .contains(segments.last.toLowerCase()) ||
          segments.last.contains('.'))) {
    segments.removeLast();
  }
  final path =
      segments.isEmpty ? '' : '/${segments.join('/')}';
  return '${parts.scheme}://${parts.host}'
      '${parts.hasPort ? ':${parts.port}' : ''}$path';
}

// -- Raw-HTML form handling (what a browser would submit) --------------------

const List<String> _skippedInputTypes = [
  'submit',
  'button',
  'image',
  'reset',
  'file'
];

/// Unescapes HTML entities (attribute values and text nodes).
String _unescape(String text) => HtmlUnescape().convert(text);

/// Collects the submittable fields of one `<form id=…>` in tree order.
class _FormFields {
  final String formId;
  int depth = 0;
  final List<(String, String)> fields = [];
  List<String>? textarea;
  Map<String, Object?>? select;

  _FormFields(this.formId);

  void feed(String html) {
    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      final data = _unescape(text.toString());
      if (textarea != null) textarea![1] += data;
      text.clear();
    }

    var i = 0;
    final n = html.length;
    while (i < n) {
      if (html[i] != '<') {
        text.write(html[i]);
        i++;
        continue;
      }
      flushText();
      if (html.startsWith('<!--', i)) {
        final end = html.indexOf('-->', i + 4);
        i = end < 0 ? n : end + 3;
        continue;
      }
      if (i + 1 < n && html[i + 1] == '!') {
        final end = html.indexOf('>', i + 2);
        i = end < 0 ? n : end + 1;
        continue;
      }
      final isEnd = i + 1 < n && html[i + 1] == '/';
      var j = i + (isEnd ? 2 : 1);
      var k = j;
      while (k < n && !' \t\r\n/>'.contains(html[k])) {
        k++;
      }
      final tag = html.substring(j, k).toLowerCase();
      final attrs = <String, String>{};
      var selfClose = false;
      var p = k;
      var closed = false;
      while (p < n && html[p] != '>') {
        while (p < n && ' \t\r\n'.contains(html[p])) {
          p++;
        }
        if (p + 1 < n && html[p] == '/' && html[p + 1] == '>') {
          selfClose = true;
          p += 2;
          closed = true;
          break;
        }
        if (p >= n || html[p] == '>') break;
        var a = p;
        while (a < n && !' \t\r\n=/>'.contains(html[a])) {
          a++;
        }
        final name = html.substring(p, a).toLowerCase();
        p = a;
        while (p < n && ' \t\r\n'.contains(html[p])) {
          p++;
        }
        var value = '';
        var hasValue = false;
        if (p < n && html[p] == '=') {
          hasValue = true;
          p++;
          while (p < n && ' \t\r\n'.contains(html[p])) {
            p++;
          }
          if (p < n && (html[p] == '"' || html[p] == "'")) {
            final quote = html[p];
            p++;
            final buf = StringBuffer();
            while (p < n && html[p] != quote) {
              buf.write(html[p]);
              p++;
            }
            if (p < n) p++;
            value = _unescape(buf.toString());
          } else {
            final buf = StringBuffer();
            while (p < n &&
                !' \t\r\n>'.contains(html[p]) &&
                !(html[p] == '/' && p + 1 < n && html[p + 1] == '>')) {
              buf.write(html[p]);
              p++;
            }
            value = _unescape(buf.toString());
          }
        }
        if (name.isNotEmpty) {
          attrs[name] = hasValue ? value : '';
        }
      }
      if (!closed && p < n && html[p] == '>') p++;
      i = p;
      if (isEnd) {
        _endTag(tag);
      } else {
        _startTag(tag, attrs);
        if (selfClose) _endTag(tag);
      }
    }
  }

  void _startTag(String tag, Map<String, String> attrs) {
    if (tag == 'form') {
      if (depth > 0 || attrs['id'] == formId) depth++;
      return;
    }
    if (depth == 0 || attrs.containsKey('disabled')) return;
    final name = attrs['name'] ?? '';
    if (tag == 'input' && name.isNotEmpty) {
      final kind = (attrs['type'] ?? 'text').toLowerCase();
      if (_skippedInputTypes.contains(kind)) return;
      if ((kind == 'checkbox' || kind == 'radio') &&
          !attrs.containsKey('checked')) {
        return;
      }
      final def =
          (kind == 'checkbox' || kind == 'radio') ? 'on' : '';
      fields.add(
          (name, attrs.containsKey('value') ? attrs['value']! : def));
    } else if (tag == 'textarea' && name.isNotEmpty) {
      textarea = [name, ''];
    } else if (tag == 'select' && name.isNotEmpty) {
      select = {'name': name, 'first': null, 'chosen': null};
    } else if (tag == 'option' && select != null) {
      final value = attrs['value'] ?? '';
      select!['first'] ??= value;
      if (attrs.containsKey('selected')) select!['chosen'] = value;
    }
  }

  void _endTag(String tag) {
    if (tag == 'form') {
      if (depth > 0) depth--;
    } else if (tag == 'textarea' && textarea != null) {
      fields.add((textarea![0], textarea![1]));
      textarea = null;
    } else if (tag == 'select' && select != null) {
      final chosen =
          select!['chosen'] ?? select!['first'];
      if (chosen != null) {
        fields.add((select!['name'] as String, chosen as String));
      }
      select = null;
    }
  }
}

/// `[(name, value)]` a browser would submit from the raw form HTML.
///
/// Fields the page's JavaScript adds later (DevExpress `$State` and
/// friends) are not in the raw HTML; callers add those themselves.
List<(String, String)> formFields(Object? pageHtml,
    [String formId = 'formbaka']) {
  final parser = _FormFields(formId);
  parser.feed('${pageHtml ?? ''}');
  return parser.fields;
}

/// Percent-encodes form fields (order and duplicates kept), like
/// `urlencode`. The result is pure ASCII bytes.
List<int> formUrlEncode(List<(String, String)> fields) {
  final parts = fields.map((f) =>
      '${Uri.encodeQueryComponent(f.$1)}=${Uri.encodeQueryComponent(f.$2)}');
  return utf8.encode(parts.join('&'));
}

/// Request parts posting [fields] form-encoded, order and duplicates kept.
({List<int> body, Map<String, String> headers}) formBody(
    List<(String, String)> fields) => (
      body: formUrlEncode(fields),
      headers: {
        'Content-Type':
            'application/x-www-form-urlencoded; charset=UTF-8',
      }
    );

/// `ASPx.Str.EncodeHtml` of the DevExpress client, step for step.
///
/// DevExpress runs every client state through it before posting (the
/// pre-escaped entities get an `x` so the server can tell them apart).
String dxEncodeHtml(String text) {
  for (final pair in [
    ('&amp;', '&ampx;'),
    ('&', '&amp;'),
    ('&quot;', '&quotx;'),
    ('"', '&quot;'),
    ('&lt;', '&ltx;'),
    ('<', '&lt;'),
    ('&gt;', '&gtx;'),
    ('>', '&gt;'),
  ]) {
    text = text.replaceAll(pair.$1, pair.$2);
  }
  return text;
}

/// A DevExpress client-state field value (compact JSON, then encoded).
String dxState(Map<String, Object?> state) =>
    dxEncodeHtml(jsonEncode(state));

const Map<String, String> _jsEscapes = {
  'n': '\n',
  'r': '\r',
  't': '\t',
  'b': '\b',
  'f': '\f',
  'v': '\v',
  '0': '\x00',
};

/// Decodes the JS string literal whose opening quote is at [start].
String _readJsString(String text, int start) {
  final quote = text[start];
  final out = StringBuffer();
  var i = start + 1;
  while (i < text.length) {
    final ch = text[i];
    if (ch == quote) return out.toString();
    if (ch != '\\') {
      out.write(ch);
      i += 1;
      continue;
    }
    final nxt = i + 1 < text.length ? text[i + 1] : '';
    String hexAt(int offset, int length) {
      if (i + offset < 0 || i + offset + length > text.length) return '';
      return text.substring(i + offset, i + offset + length);
    }

    if (nxt == 'u' &&
        RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hexAt(2, 4))) {
      out.writeCharCode(int.parse(hexAt(2, 4), radix: 16));
      i += 6;
    } else if (nxt == 'x' &&
        RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(hexAt(2, 2))) {
      out.writeCharCode(int.parse(hexAt(2, 2), radix: 16));
      i += 4;
    } else {
      out.write(_jsEscapes[nxt] ?? nxt);
      i += 2;
    }
  }
  throw ArgumentError('unterminated string in the DevExpress callback reply');
}

/// The `result` string of a DevExpress callback reply.
///
/// Replies look like `<n>|<state>/*DX*/({'id':0,'result':'…'})` with the
/// result as a JS string literal. Raises [StateError] on a callback
/// error and [ArgumentError] when the reply is not a callback reply at all.
String dxCallbackResult(Object? reply) {
  final text = '${reply ?? ''}';
  final start = text.indexOf('/*DX*/(');
  if (start < 0) {
    throw ArgumentError('not a DevExpress callback reply');
  }
  final body = text.substring(start + 7);
  final error = RegExp(
      '[\'"]error[\'"]\\s*:\\s*\\{\\s*[\'"]message[\'"]\\s*:\\s*([\'"])')
      .firstMatch(body);
  if (error != null) {
    throw StateError(
        'DevExpress callback error: ${truncateRunes(_readJsString(body, error.end - 1), 200)}');
  }
  final result = RegExp('[\'"]result[\'"]\\s*:\\s*([\'"])')
      .firstMatch(body);
  if (result == null) {
    throw ArgumentError('DevExpress callback reply without a result');
  }
  return _readJsString(body, result.end - 1);
}

String truncateRunes(String text, int limit) => text.runes.length <= limit
    ? text
    : String.fromCharCodes(text.runes.take(limit));

// -- Login page --------------------------------------------------------------

final _loginErrorNodeRe = RegExp(
  '<\\w+[^>]*(?:class="[^"]*\\b(?:login-error|validation-summary-errors|alert-danger|dx-invalid-message)\\b[^"]*"|id="loginError")[^>]*>(.*?)</\\w+>',
  caseSensitive: false,
  dotAll: true,
);

const List<String> _loginErrorWords = [
  'nesprávné',
  'neplatné',
  'chybné',
  'neúspěšné',
  'špatné',
  'nespravne',
  'invalid',
  'incorrect'
];

String _visibleText(String fragment) {
  var text = fragment.replaceAll(
      RegExp(r'<(script|style)\b.*?</\1>',
          caseSensitive: false, dotAll: true),
      ' ');
  text = _unescape(text.replaceAll(RegExp(r'<[^>]+>'), ' '));
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Why Bakaláři rejected the login, or `""`. Never raises.
String loginErrorText(HttpResponseData resp) {
  try {
    final message = (resp.url.queryParameters['e'] ?? '').trim();
    if (message.isNotEmpty) return truncateRunes(message, 300);
    final body = resp.text;
    for (final match in _loginErrorNodeRe.allMatches(body)) {
      final text = _visibleText(match.group(1)!);
      if (text.isNotEmpty) return truncateRunes(text, 300);
    }
    final visible = _visibleText(body);
    final lowered = visible.toLowerCase();
    for (final word in _loginErrorWords) {
      final idx = lowered.indexOf(word);
      if (idx >= 0) {
        final start = idx - 40 < 0 ? 0 : idx - 40;
        var end = idx + 120;
        if (end > visible.length) end = visible.length;
        return truncateRunes(visible.substring(start, end).trim(), 300);
      }
    }
  } on Object {
    // Fall through to "".
  }
  return '';
}

/// True when [resp] is (or redirected to) the login form.
bool isLoginPage(HttpResponseData resp) {
  if (resp.statusCode == 401) return true;
  final stripped =
      resp.url.path.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  if (stripped.endsWith('/login')) return true;
  if ((resp.firstHeader('content-type') ?? '').contains('html')) {
    return resp.text.contains('id="loginButton"');
  }
  return false;
}

/// Where the login form posts to (the button's formaction, else the form's action).
Uri loginPostUrl(HttpResponseData page) {
  final body = page.text;
  final target = RegExp('id="loginButton"[^>]*?formaction="([^"]+)"')
          .firstMatch(body) ??
      RegExp('formaction="([^"]+)"[^>]*?id="loginButton"')
          .firstMatch(body) ??
      RegExp('<form[^>]*id="formlogin"[^>]*action="([^"]+)"')
          .firstMatch(body);
  return page.url.resolve(target != null ? target.group(1)! : 'Login');
}

// -- Transport (injectable; production runs on dart:io) -----------------------

/// One HTTP reply. Header names are lowercased; values keep every
/// `Set-Cookie` (cookies are stored per value, never comma-joined).
class HttpResponseData {
  final int statusCode;
  final Uri url;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;

  HttpResponseData({
    required this.statusCode,
    required this.url,
    Map<String, List<String>>? headers,
    List<int>? bodyBytes,
  })  : headers = {
          for (final e in (headers ?? {}).entries)
            e.key.toLowerCase(): List<String>.of(e.value)
        },
        bodyBytes = bodyBytes ?? [];

  String get text => utf8.decode(bodyBytes, allowMalformed: true);

  String? firstHeader(String name) {
    final values = headers[name.toLowerCase()];
    return (values == null || values.isEmpty) ? null : values.first;
  }
}

/// A single request without automatic redirects (the session follows them
/// by hand to capture cookies at every hop). Throws [ConnectFailure]
/// when DNS + connect fails (the request certainly never left),
/// [SocketException] on later network failure and [TimeoutException]
/// on timeout.
abstract interface class HttpTransport {
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout});

  void close();
}

/// A transport failure raised before any request byte could leave the
/// machine: DNS + connect failed (or the connect timed out). Anything
/// thrown after [DartIoHttpTransport] opened the connection means the
/// request may already have arrived ("maybe sent").
final class ConnectFailure implements IOException {
  /// The connect error from `dart:io` (usually a [SocketException]).
  final Object cause;

  ConnectFailure(this.cause);

  @override
  String toString() => 'ConnectFailure: $cause';
}

/// `dart:io` transport (production).
class DartIoHttpTransport implements HttpTransport {
  final HttpClient _client = HttpClient();
  bool _closed = false;

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    // A connect timeout must also surface as "never sent". Match Python's
    // httpx.Timeout(timeout_s, connect=min(timeout_s, 20.0)).
    final connectTimeout = timeout < const Duration(seconds: 20)
        ? timeout
        : const Duration(seconds: 20);
    _client.connectionTimeout = connectTimeout;
    late final HttpClientRequest request;
    try {
      // DNS + connect: the only phase where a failure means the
      // request certainly never left.
      request = await _client.openUrl(method, url).timeout(connectTimeout);
    } on Object catch (e) {
      throw ConnectFailure(e);
    }
    request.followRedirects = false;
    request.persistentConnection = true;
    for (final entry in (headers ?? {}).entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null && body.isNotEmpty) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response =
        await request.close().timeout(timeout);
    final bytes = await response
        .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
        .timeout(timeout);
    final responseHeaders = <String, List<String>>{};
    response.headers.forEach(
        (name, values) => responseHeaders[name.toLowerCase()] = values);
    return HttpResponseData(
      statusCode: response.statusCode,
      url: url,
      headers: responseHeaders,
      bodyBytes: bytes,
    );
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _client.close(force: true);
    }
  }
}

// -- Session -----------------------------------------------------------------

/// One logged-in Bakaláři web session (cookies, timeouts, re-login).
///
/// Every request checks the cancel predicate first. A reply that lands on
/// the login page means the server dropped the session: read requests log
/// in again and are retried once; [sendOnce] (the excuse post) is
/// never repeated.
class BakalariSession {
  /// Web root (no trailing slash). Cookies are scoped to it.
  final String root;

  final String username;
  final String Function() passwordProvider;
  final bool Function()? isCancelled;
  final void Function(String)? logger;

  double timeoutS;
  bool loggedIn = false;

  final HttpTransport _transport;
  final Map<String, String> _cookies = {};

  BakalariSession(
    String baseUrl,
    this.username,
    this.passwordProvider, {
    this.timeoutS = 60.0,
    String userAgent = '',
    this.isCancelled,
    this.logger,
    HttpTransport? transport,
  })  : root = appRoot(baseUrl),
        _transport = transport ?? DartIoHttpTransport() {
    if (userAgent.isNotEmpty) _userAgent = userAgent;
  }

  String? _userAgent;

  void log(String message) {
    logger?.call(message);
  }

  void close() {
    _transport.close();
  }

  String get host {
    final uri = Uri.tryParse(root);
    final netloc = uri?.host ?? '';
    return netloc.isNotEmpty ? netloc : root;
  }

  Duration get _timeout =>
      Duration(microseconds: (timeoutS * 1e6).round());

  void _storeCookies(HttpResponseData resp) {
    for (final value in resp.headers['set-cookie'] ?? <String>[]) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name.isNotEmpty) {
          _cookies[cookie.name] = cookie.value;
        }
      } on Object {
        continue;
      }
    }
  }
  /// One request; a read is retried once when the connection broke
  /// before any reply (the server dropped an idle kept-alive connection).
  /// `once` requests (the excuse post) are never repeated.
  Future<HttpResponseData> _send(
    String method,
    String path, {
    bool once = false,
    bool followRedirects = true,
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    raiseIfCancelled(isCancelled);
    final url = (path.startsWith('http://') || path.startsWith('https://'))
        ? Uri.parse(path)
        : Uri.parse('$root$path');
    var currentMethod = method;
    var currentUri = url;
    var currentBody = body;
    var currentHeaders = Map<String, String>.of(headers ?? {});
    for (var hop = 0; hop < 20; hop++) {
      final requestHeaders = <String, String>{
        'Accept-Language': 'cs,en;q=0.8',
        if (_userAgent != null && _userAgent!.isNotEmpty)
          'User-Agent': _userAgent!,
        ...currentHeaders,
      };
      if (_cookies.isNotEmpty) {
        requestHeaders['cookie'] = _cookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
      }
      late final HttpResponseData resp;
      try {
        try {
          resp = await _transport.send(
            currentMethod,
            currentUri,
            headers: requestHeaders,
            body: currentBody,
            timeout: _timeout,
          );
          _storeCookies(resp);
        } on IOException catch (e) {
          if (once || !isDroppedReadError(e)) rethrow;
          log('Bakaláři connection dropped (${e.runtimeType}), '
              'retrying once: $currentMethod $path');
          raiseIfCancelled(isCancelled);
          resp = await _transport.send(
            currentMethod,
            currentUri,
            headers: requestHeaders,
            body: currentBody,
            timeout: _timeout,
          );
          _storeCookies(resp);
        }
      } on TimeoutException catch (e) {
        log('Bakaláři request timed out after '
            '${timeoutS.toStringAsFixed(0)} s: $currentMethod $path');
        throw UserError(timeoutUserMessage(), e);
      } on IOException catch (e) {
        log('Bakaláři request failed: $currentMethod $path: '
            '${e.runtimeType}: $e');
        if (e is ConnectFailure) {
          throw UserError(
              t('bak_unreachable', args: {'host': host}), e);
        }
        throw UserError(t('bak_connection_lost'), e);
      }
      if (followRedirects &&
          const {301, 302, 303, 307, 308}
              .contains(resp.statusCode)) {
        final location = resp.firstHeader('location');
        if (location != null && location.isNotEmpty) {
          currentUri = currentUri.resolve(location);
          if (resp.statusCode == 303 ||
              ((resp.statusCode == 301 || resp.statusCode == 302) &&
                  currentMethod != 'GET')) {
            currentMethod = 'GET';
            currentBody = null;
            currentHeaders.remove('content-type');
            currentHeaders.remove('content-length');
          }
          continue;
        }
      }
      return resp;
    }
    throw UserError(t('bak_connection_lost'));
  }

  HttpResponseData _checkStatus(HttpResponseData resp, String method) {
    if (resp.statusCode >= 400 && resp.statusCode != 401) {
      log('Bakaláři answered HTTP ${resp.statusCode}: '
          '$method ${resp.url.path}');
      throw UserError(
          t('bak_server_error', args: {'status': resp.statusCode}));
    }
    return resp;
  }

  /// Logs in with the login form; [UserError] when Bakaláři rejects it.
  Future<void> login() async {
    if (root.startsWith('http://')) {
      log('Warning: Bakaláři URL uses plain http:// — '
          'credentials will travel unencrypted.');
    }
    final page = await _send('GET', '/login');
    if (page.statusCode == 404) {
      throw UserError(t('bak_no_login_page', args: {'host': host}));
    }
    _checkStatus(page, 'GET');
    if (!page.text.contains('id="loginButton"')) {
      final dashboard = page.url.path.toLowerCase().replaceAll(
          RegExp(r'/+$'), '');
      if (dashboard.endsWith('/dashboard')) {
        // The session cookie is still valid: /login went straight to the app.
        loggedIn = true;
        return;
      }
      // Neither the login form nor the app: not a Bakaláři address.
      log('Bakaláři login page not found: GET /login ended at ${page.url}');
      throw UserError(t('bak_no_login_page', args: {'host': host}));
    }
    final fields = <String, String>{};
    for (final field in formFields(page.text, 'formlogin')) {
      fields[field.$1] = field.$2;
    }
    fields['username'] = username;
    fields['password'] = passwordProvider();
    fields['returnUrl'] = fields['returnUrl'] ?? '';
    fields['login'] = '';
    log('Logging in to Bakaláři…');
    final post = formBody(fields.entries
        .map((e) => (e.key, e.value))
        .toList());
    final resp = _checkStatus(
        await _send('POST', loginPostUrl(page).toString(),
            headers: post.headers, body: post.body),
        'POST');
    if (isLoginPage(resp)) {
      loggedIn = false;
      final detail = loginErrorText(resp).isNotEmpty
          ? loginErrorText(resp)
          : 'HTTP ${resp.statusCode}, still on the login page';
      throw UserError(t('bak_login_rejected',
          args: {'detail': truncateRunes(detail, 200)}));
    }
    loggedIn = true;
    log('Logged in to Bakaláři.');
  }

  /// One request in the logged-in session (logs in first when needed).
  Future<HttpResponseData> request(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    if (!loggedIn) await login();
    var resp = await _send(method, path,
        headers: headers, body: body);
    if (isLoginPage(resp)) {
      loggedIn = false;
      log('Bakaláři session expired, logging in again…');
      await login();
      resp = await _send(method, path,
          headers: headers, body: body);
      if (isLoginPage(resp)) {
        loggedIn = false;
        throw UserError(t('bak_login_rejected', args: {
          'detail': 'the session ended right after logging in'
        }));
      }
    }
    return _checkStatus(resp, method);
  }

  /// One request that must never be repeated (the excuse post).
  ///
  /// No re-login, no retry and redirects are not followed: the caller
  /// reads the raw reply. Network failures raise [UserError] with the
  /// transport error as `__cause__` so the caller can tell "never sent"
  /// (connect errors) from "maybe sent".
  Future<HttpResponseData> sendOnce(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    if (!loggedIn) await login();
    return _send(method, path,
        once: true,
        followRedirects: false,
        headers: headers,
        body: body);
  }

  Future<String> getHtml(
    String path, {
    Map<String, String>? headers,
  }) async =>
      (await request('GET', path, headers: headers)).text;

  /// The `data` of a `{success, error, data}` JSON reply (raises on failure).
  Future<Object?> json(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
    Map<String, String>? queryParams,
    Map<String, Object?>? jsonBody,
  }) async {
    var requestPath = path;
    if (queryParams != null && queryParams.isNotEmpty) {
      final base = Uri.parse(path.startsWith('http') ? path : '$root$path');
      final merged = Map<String, String>.of(base.queryParameters)
        ..addAll(queryParams);
      final rebuilt = base.replace(queryParameters: merged).toString();
      requestPath = requestPath.startsWith('http')
          ? rebuilt
          : rebuilt.substring(root.length);
    }
    var requestHeaders = headers;
    var requestBody = body;
    if (jsonBody != null) {
      requestHeaders = {
        ...?requestHeaders,
        'Content-Type': 'application/json',
      };
      requestBody = utf8.encode(jsonEncode(jsonBody));
    }
    final resp = await request(method, requestPath,
        headers: requestHeaders, body: requestBody);
    late final Object? payload;
    try {
      payload = jsonDecode(resp.text);
    } on FormatException catch (e) {
      throw StateError(
          '$path: not a JSON reply (HTTP ${resp.statusCode}): $e');
    }
    if (payload is Map && payload.containsKey('success')) {
      if (payload['success'] != true) {
        throw StateError(
            '$path: ${payload['error'] ?? 'request failed'}');
      }
      return payload['data'];
    }
    return payload;
  }

  /// Runs a DevExpress callback of a page and returns its result HTML.
  Future<String> dxCallback(
    String path,
    String pageHtml,
    String callbackId,
    String param,
  ) async {
    final fields = formFields(pageHtml);
    fields.add(('__CALLBACKID', callbackId));
    fields.add(('__CALLBACKPARAM', 'c0:$param'));
    final post = formBody(fields);
    final resp = await request('POST', path,
        headers: post.headers, body: post.body);
    return dxCallbackResult(resp.text);
  }
}

/// Only a [ConnectFailure] means the excuse post certainly never left:
/// DNS + connect failed before any request byte was written. Anything
/// thrown after [DartIoHttpTransport] opened the connection (read
/// timeouts, resets, ETIMEDOUT on an established connection, …) may
/// already have arrived, so the post must never be repeated.
bool isNeverSentCause(Object? error) => error is ConnectFailure;

/// True when [error] is a dropped-connection / protocol read failure
/// (`HttpException` or `SocketException` after connect, mirroring
/// `httpx.RemoteProtocolError` / `httpx.ReadError`). Excludes
/// [ConnectFailure], [TlsException] / [HandshakeException] /
/// [CertificateException], and unrelated [IOException]s.
bool isDroppedReadError(Object? error) =>
    (error is HttpException || error is SocketException) &&
    error is! ConnectFailure &&
    error is! TlsException;
