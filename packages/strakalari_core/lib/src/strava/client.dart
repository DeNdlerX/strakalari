// Strava.cz over plain HTTP: login and the menu, through the web app's own
// API.
//
// Port of strakalari/core/strava_client.py.
//
// The Strava web app (app.strava.cz) is a single-page app talking to its
// own JSON endpoints (`/api/login`, `/api/objednavky`, …); this client
// sends the same requests. Ordering lives in [OrderingMixin].
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../automation/cancel.dart';
import '../bakalari/http_session.dart';
import '../error_report.dart';
import '../i18n.dart';
import '../storage/accounts.dart' show requirePerAccountDir;
import '../storage/config.dart';
import '../storage/helpers.dart';
import 'extractors.dart';
import 'ordering.dart';

/// Sent with every request; the same browser identity the app always used.
const String stravaUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0';

/// Error numbers after which the web app drops the session and logs out.
const Set<int> sessionGone = {
  13,
  15,
  10102,
  90,
  1009,
  1010,
  1011,
  1014,
  30,
  10104
};

/// A `{"state": "error"}` reply of the Strava API.
class StravaError implements Exception {
  final Object? number;
  final String message;

  StravaError(this.number, String? message)
      : message = (message ?? '');

  @override
  String toString() =>
      'Strava error $number: $message'.trim();
}

/// The web app origin: `strava.cz` (the login page users know) →
/// `app.strava.cz`.
String apiRoot(Object? url) {
  var raw = '${url ?? ''}'.trim();
  if (raw.isEmpty) raw = 'https://strava.cz';
  if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
    raw = 'https://$raw';
  }
  final parts = Uri.parse(raw);
  // Like Python's `urlsplit(...).netloc.lower()`: authority with port
  // (and userinfo) kept — only the bare hosts map to the web app.
  var authority = parts.host.toLowerCase();
  if (parts.hasPort) authority = '$authority:${parts.port}';
  if (parts.userInfo.isNotEmpty) {
    authority = '${parts.userInfo.toLowerCase()}@$authority';
  }
  if (authority == 'strava.cz' || authority == 'www.strava.cz') {
    authority = 'app.strava.cz';
  }
  return '${parts.scheme}://$authority';
}

/// Strava.cz session: login and the menu (over HTTP, no browser).
///
/// Ordering lives in [OrderingMixin].
class StravaClientBase {
  /// Cooperative cancellation (mirrors BakalariClient; set from
  /// Strakalari.fetch_strava_data before each fetch).
  bool cancelRequested = false;

  /// Optional live predicate (e.g. GUI state) polled alongside the
  /// flag so a cancel issued mid-fetch is honored without re-setting.
  bool Function()? cancelCallback;

  final Map<String, Object?> config;
  final void Function(String)? logger;

  HttpTransport? _transport;
  final bool _ownsTransport;

  late final String stravaUrl;
  late String stravaId;
  late final String stravaUsername;
  late final String stravaPassword;
  late final bool stravaPasswordEncrypted;
  late final bool stravaEnable;

  late final String stravaBlacklist;
  List<String> stravaBlacklistJson = [];
  bool blacklistBroken = false;

  bool loggedIn = false;

  /// Session of the web app: what /api/login returned.
  String sid = '';
  String s5url = '';
  Object? ignoreCert = '';
  Map<String, Object?> user = {};

  /// The raw menu (`{table: [meal]}`) of the last fetch; ordering works
  /// on it.
  Map<String, List<Map<String, Object?>>> menu = {};
  Map<String, Map<String, String>> foodDict = {};
  Map<String, String> orderedDict = {};

  /// The soup of each menu day (not orderable, shown with the meals).
  Map<String, String> soupDict = {};

  /// Order changes made by [OrderingMixin.order] since the last reset.
  /// Lets callers save only when something actually changed.
  int clicksMade = 0;

  /// Set by order() when the account has too little money for a meal
  /// (Strava's warning 5005); every further meal order would fail the
  /// same way, so callers stop ordering and tell the user to top up.
  bool insufficientBalance = false;
  String lastNotice = '';
  final List<Map<String, Object?>> pending = [];

  /// Per-account folder for resolving blacklist and decrypting password.
  final String? dataDir;

  /// Fallback root folder when decrypting a migrated password.
  final String? fallbackKeyDir;

  StravaClientBase(Map<String, Object?>? configData,
      {this.logger,
      HttpTransport? transport,
      this.dataDir,
      this.fallbackKeyDir})
      : config = Map<String, Object?>.of(configData ?? {}),
        _transport = transport,
        _ownsTransport = transport == null {
    stravaUrl = '${config['strava_url'] ?? 'https://strava.cz'}';
    // Legacy key aliases (read-only compat: nothing writes strava_id /
    // strava_user / strava_enable anymore; the settings UI uses the
    // canonical strava_canteen_id / strava_username / use_strava keys).
    final rawId =
        '${config['strava_canteen_id'] ?? config['strava_id'] ?? ''}'
            .trim();
    stravaId = rawId;
    stravaUsername =
        '${config['strava_username'] ?? config['strava_user'] ?? ''}';
    stravaPassword = '${config['strava_password'] ?? ''}';
    stravaPasswordEncrypted =
        isEncryptedFlag(config['strava_password_encrypted']);
    final useStrava = config.containsKey('use_strava')
        ? config['use_strava']
        : config['strava_enable'];
    stravaEnable = !(useStrava == false ||
        '${useStrava ?? ''}'.toLowerCase() == 'false');

    stravaBlacklist = resolvePath(
        '${config['strava_blacklist'] ?? './strava_blacklist.json'}',
        requirePerAccountDir(dataDir));
    if (stravaEnable) {
      var blPath = stravaBlacklist;
      if (!File(blPath).existsSync()) {
        final example = examplePathFor(blPath);
        if (File(example).existsSync()) blPath = example;
      }
      if (File(blPath).existsSync()) {
        try {
          final loaded = jsonDecode(
              File(blPath).readAsStringSync(encoding: utf8));
          if (loaded is List) {
            // Never let the example template placeholder govern real
            // filtering (fresh installs may only have the example
            // file; a copied example stays harmless).
            stravaBlacklistJson = [
              for (final kw in loaded)
                if (kw != null &&
                    '$kw'.isNotEmpty &&
                    !looksLikePlaceholder(kw))
                  '$kw'
            ];
          } else {
            log('Warning: strava blacklist is not a JSON list, treating as empty: $stravaBlacklist');
            stravaBlacklistJson = [];
          }
        } on Object catch (e) {
          // Fail closed for automatic ordering: an unreadable
          // blacklist must not silently re-allow banned meals.
          // (Explicit manual picks bypass the blacklist by design.)
          // Only undecodable content is quarantined, never a
          // merely busy file or the shipped example.
          blacklistBroken = true;
          var backup = '';
          if (e is FormatException &&
              File(blPath).absolute.path !=
                  File(examplePathFor(blPath)).absolute.path) {
            backup = quarantineCorruptFile(blPath);
          }
          final hint = backup.isNotEmpty ? ' (preserved at $backup)' : '';
          log('Warning: Could not read strava blacklist: $e$hint');
          stravaBlacklistJson = [];
        }
      }
    }
  }

  void log(String message) {
    logger?.call(message);
  }

  bool _isCancelled() {
    if (cancelRequested) return true;
    final cb = cancelCallback;
    if (cb != null) {
      try {
        return cb();
      } on Object {
        return false;
      }
    }
    return false;
  }

  /// Aborts the run promptly when the user hit Zrušit.
  void raiseIfCancelledNow() {
    raiseIfCancelled(_isCancelled);
  }

  double _seconds(String key, double defaultValue) {
    final raw = config.containsKey(key) ? config[key] : defaultValue;
    final value =
        raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (value == null || !value.isFinite || value <= 0) {
      return defaultValue;
    }
    return value;
  }

  String get _root => apiRoot(stravaUrl);

  // -- HTTP ---------------------------------------------------------------

  void close() {
    if (_ownsTransport) {
      try {
        _transport?.close();
      } on Object catch (e) {
        log(describeSwallowed('closing the Strava HTTP session', e));
      }
    }
    _transport = null;
    loggedIn = false;
  }

  /// One API call as the web app makes it (JSON text body); the parsed
  /// reply.
  ///
  /// Retried once when the connection broke before any reply (a dropped
  /// kept-alive connection) — except `once` calls (the save).
  Future<Object?> _post(String path, Map<String, Object?> body,
      {required bool once}) async {
    raiseIfCancelledNow();
    final timeoutS = _seconds('page_load_timeout_s', 60.0);
    final timeout =
        Duration(milliseconds: (timeoutS * 1000).round());
    final payload = utf8.encode(jsonEncode(body));
    Future<HttpResponseData> attempt() {
      final transport = _transport ??= DartIoHttpTransport();
      return transport.send('POST', Uri.parse('$_root$path'),
          headers: {
            'Content-Type': 'text/plain;charset=UTF-8',
            'User-Agent': stravaUserAgent,
            'Accept-Language': 'cs,en;q=0.8',
          },
          body: payload,
          timeout: timeout);
    }

    late final HttpResponseData resp;
    try {
      try {
        resp = await attempt();
      } on IOException catch (e) {
        if (once || !isDroppedReadError(e)) rethrow;
        log('Strava connection dropped (${e.runtimeType}), retrying once: $path');
        raiseIfCancelledNow();
        resp = await attempt();
      }
    } on TimeoutException {
      log('Strava request timed out after ${timeoutS.toStringAsFixed(0)} s: $path');
      throw UserError(timeoutUserMessage());
    } on IOException catch (e) {
      if (e is ConnectFailure && e.isTimeout) {
        // `httpx.ConnectTimeout` is a `TimeoutException` in Python.
        log('Strava request timed out after ${timeoutS.toStringAsFixed(0)} s: $path');
        throw UserError(timeoutUserMessage());
      }
      log('Strava request failed: $path: ${e.runtimeType}: $e');
      // Only a failed connect is "unreachable" (`httpx.ConnectError`).
      if (e is ConnectFailure) {
        throw UserError(t('strava_unreachable'));
      }
      throw UserError(t('strava_connection_lost'));
    }
    if (!((resp.statusCode >= 200 && resp.statusCode < 300) ||
        resp.statusCode == 555)) {
      log('Strava answered HTTP ${resp.statusCode}: $path');
      throw UserError(
          t('strava_server_error', args: {'status': resp.statusCode}));
    }
    try {
      return jsonDecode(resp.text);
    } on FormatException {
      throw StravaError(resp.statusCode, 'not a JSON reply');
    }
  }

  /// [_post] that raises [StravaError] on an error reply and logs in
  /// again once when Strava dropped the session ([relogin]; without it
  /// the call is also never repeated on a broken connection).
  Future<Object?> callApi(String path, Map<String, Object?> body,
      {bool relogin = true}) async {
    final reply = await _post(path, body, once: !relogin);
    if (reply is Map && reply['state'] == 'error') {
      final number = reply['number'];
      if (relogin && sessionGone.contains(number)) {
        log('Strava session expired ($number), logging in again…');
        loggedIn = false;
        await login();
        return callApi(path, {...body, 'sid': sid}, relogin: false);
      }
      throw StravaError(number, '${reply['message'] ?? ''}');
    }
    return reply;
  }

  Map<String, Object?> sessionBody({String urlKey = 'url'}) => {
        'cislo': stravaId,
        'sid': sid,
        urlKey: s5url,
        'lang': 'CZ',
        'ignoreCert': ignoreCert,
      };

  // -- Login and menu -------------------------------------------------------

  String _plainPassword() {
    if (isEncryptedFlag(stravaPasswordEncrypted)) {
      final password = decryptStrict(stravaPassword,
          dataDir: dataDir, fallbackKeyDir: fallbackKeyDir);
      if (password == null) {
        throw UserError(t('strava_password_undecryptable'));
      }
      return password;
    }
    return stravaPassword;
  }

  /// Logs in with the canteen id, username and password.
  Future<void> login() async {
    raiseIfCancelledNow();
    if (stravaId.trim().isEmpty) {
      throw UserError(t('strava_missing_canteen'));
    }
    if (stravaUsername.trim().isEmpty) {
      throw UserError(t('strava_missing_user'));
    }
    if (stravaPassword.trim().isEmpty) {
      throw UserError(t('strava_missing_password'));
    }
    if (apiRoot(stravaUrl).startsWith('http://')) {
      log('Warning: Strava URL uses plain http:// — credentials will travel unencrypted.');
    }
    final reply = await _post('/api/login', {
      'cislo': stravaId,
      'jmeno': stravaUsername,
      'heslo': _plainPassword(),
      'zustatPrihlasen': false,
      'environment': 'W',
      'lang': 'CZ',
    }, once: false);
    if (reply is! Map ||
        reply['state'] == 'error' ||
        reply['sid'] == null) {
      loggedIn = false;
      final detail = reply is Map ? '${reply['message'] ?? ''}' : '';
      final number = reply is Map ? reply['number'] : '';
      log('Strava login rejected ($number): $detail');
      if (detail.trim().isNotEmpty) {
        throw UserError(t('strava_login_rejected',
            args: {'detail': detail.trim().substring(0, detail.trim().length > 200 ? 200 : detail.trim().length)}));
      }
      throw UserError(t('strava_login_failed'));
    }
    sid = '${reply['sid']}';
    s5url = '${reply['s5url'] ?? ''}';
    stravaId = '${reply['cislo'] ?? stravaId}';
    ignoreCert = reply.containsKey('ignoreCert') ? reply['ignoreCert'] : '';
    final uzivatel = reply['uzivatel'];
    user = uzivatel is Map ? uzivatel.cast<String, Object?>() : {};
    loggedIn = true;
    log('Logged in to Strava.');
  }

  /// Loads the menu; returns `foodDict` + `orderedDict`.
  Future<Map<String, Object?>> fetchData() async {
    raiseIfCancelledNow();
    if (!loggedIn) await login();
    pending.clear();
    Object? reply;
    try {
      reply = await callApi('/api/objednavky',
          {...sessionBody(urlKey: 's5url'), 'konto': 0, 'podminka': ''});
    } on CancelledError {
      rethrow;
    } on UserError {
      rethrow;
    } on StravaError catch (e) {
      log('Strava menu did not load: $e');
      throw UserError(t('strava_menu_failed',
          args: {'detail': e.message.isNotEmpty ? e.message : '${e.number}'}));
    }
    menu = {
      for (final (key, meals) in menuTables(reply))
        key: [
          for (final m in meals)
            Map<String, Object?>.from(m as Map)
        ]
    };
    final (food, ordered) = menuFromReply(reply);
    foodDict = food;
    orderedDict = ordered;
    soupDict = soupsFromReply(reply);
    if (foodDict.isEmpty) {
      // Never serve the previous menu as fresh: downstream refresh
      // paths treat an empty menu as a failed fetch and keep the
      // last good cache instead of overwriting it.
      log('Warning: Strava menu is empty — showing no menu, not stale data.');
    } else if (orderedDict.isEmpty) {
      log('Strava menu loaded, no meal is ordered on any listed day.');
    }
    return {'foodDict': foodDict, 'orderedDict': orderedDict};
  }
}

/// Strava.cz session: login and the menu (over HTTP, no browser).
///
/// Ordering lives in [OrderingMixin].
class StravaClient extends StravaClientBase with OrderingMixin {
  StravaClient(super.configData,
      {super.logger, super.transport, super.dataDir, super.fallbackKeyDir});
}
