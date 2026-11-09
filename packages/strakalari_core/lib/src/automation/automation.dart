// The Strakalari app object: clients, excuse sending, Strava ordering.
//
// Port of strakalari/core/automation.py. This is the safety-critical send
// path: one history coverage check, with the lock held across check,
// submit and write. Navigation clicks are `once` and never retried. An
// unconfirmed submit blocks re-sends until the Komens outbox shows, and
// auto mode never sends when the outbox can't be read (see refresh.dart).
//
// Conventions: `clock.now()` for all "now"s (never `DateTime.now()`),
// `CancelledError` where Python raises `InterruptedError`, `StateError`
// where Python raises `RuntimeError`.
//
// Phase-3 wiring: lunch deadlines and the school calendar live in
// `planning/school_presets.dart` and `lunches/lunch_cutoff.dart` —
// like automation.py's lazy imports of those modules. The hooks default
// to those canonical functions; tests assign fakes (the Dart mirror of
// monkeypatching the module functions).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';

import '../bakalari/client.dart';
import '../lunches/lunch_cutoff.dart' show isLunchOrderOpen;
import '../models.dart';
import '../planning/school_presets.dart'
    show effectiveCalendar, resolveLunchCutoff;
import '../strava/client.dart';
import '../storage/config.dart';
import '../storage/helpers.dart';
import 'audit.dart' as audit;
import 'cancel.dart';
import 'excuse_history.dart';
import '../error_report.dart' show redactValues, secretValues;
import '../i18n.dart';

/// Resolved lunch cutoff `HH:MM` (`school_presets.resolve_lunch_cutoff`,
/// like automation.py's lazy import).
String Function(Map<String, Object?> cfg) resolveLunchCutoffHook =
    (cfg) => resolveLunchCutoff(cfg);

/// Effective free-day set, `clip: false` (`school_presets`
/// `effective_calendar`, like automation.py's lazy import which unpacks
/// the dates set).
Set<DateTime> Function(Map<String, Object?> cfg) effectiveCalendarFreeHook =
    (cfg) => effectiveCalendar(cfg, clip: false).dates;

/// Ordering deadline check (`lunch_cutoff.is_lunch_order_open`, like
/// automation.py's lazy import).
bool Function(DateTime day, DateTime now, String cutoff, Set<DateTime> free)
    isLunchOrderOpenHook = (day, now, cutoff, free) =>
        isLunchOrderOpen(day, now: now, cutoffTime: cutoff, freeDays: free);

/// Python truthiness (non-empty strings stay truthy, `0` is falsy).
bool _pyTruthy(Object? v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  if (v is Iterable) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

int _clampInt(Object? value, int fallback, int min, int max) {
  int parsed;
  if (value is int) {
    parsed = value;
  } else if (value is double) {
    if (value.isNaN || value.isInfinite) return fallback;
    parsed = value.truncate();
  } else if (value is bool) {
    parsed = value ? 1 : 0;
  } else {
    parsed = int.tryParse('${value ?? ''}'.trim()) ?? fallback;
  }
  if (parsed < min) return min;
  if (parsed > max) return max;
  return parsed;
}

/// Python `int(...)` with no clamp; `TypeError`/`ValueError` fall back to 2.
int _strictDelayDays(Object? value) {
  if (value == null) return 2;
  if (value is int) return value;
  if (value is double) {
    if (!value.isFinite) return 2;
    return value.truncate();
  }
  if (value is bool) return value ? 1 : 0;
  return int.tryParse('$value'.trim()) ?? 2;
}

/// First non-empty-ish id (`0`, `false`, `''` and null fall through).
String _firstId(Object? a, Object? b) {
  for (final v in [a, b]) {
    if (v == null || v == false) continue;
    if (v is num && v == 0) continue;
    final s = '$v'.trim();
    if (s.isNotEmpty) return v is String ? v : s;
  }
  return '';
}

/// Menu selection for [day], tolerant to day-key spellings.
///
/// The extractor emits raw keys (`4.9.2026`) while callers may pass the
/// zero-padded form (`04.09.2026`) and vice versa.
Map<String, String> menuSelection(
    Map<String, Map<String, String>> foodDict, Object? day) {
  if (day != null && foodDict[day] != null) {
    return Map<String, String>.of(foodDict[day]!);
  }
  try {
    final want = canonicalDayKey(day);
    for (final entry in foodDict.entries) {
      if (entry.value.isNotEmpty && canonicalDayKey(entry.key) == want) {
        return Map<String, String>.of(entry.value);
      }
    }
  } on Object {
    // Fall through to {} below.
  }
  return <String, String>{};
}

/// `{(date, period)}` from UI ignore keys (`YYYY-MM-DD|period|subject`).
///
/// Tuples (2-lists / records) `(date, period)` pass through. Unparseable
/// keys are dropped.
Set<(DateTime, int)> ignoredPoints(List<Object?>? ignored) {
  final points = <(DateTime, int)>{};
  for (final item in ignored ?? const <Object?>[]) {
    try {
      if (item is (Object?, Object?)) {
        final day = _asDay(item.$1);
        final period = _asPeriod(item.$2);
        if (day != null && period != null) points.add((day, period));
        continue;
      }
      if (item is List && item.length == 2) {
        final day = _asDay(item[0]);
        final period = _asPeriod(item[1]);
        if (day != null && period != null) points.add((day, period));
        continue;
      }
      final parts = '$item'.split('|');
      if (parts.length < 2) continue;
      final day = _strictIsoDay(parts[0].trim());
      final period = int.tryParse(parts[1].trim());
      if (day != null && period != null) points.add((day, period));
    } on Object {
      continue;
    }
  }
  return points;
}

DateTime? _asDay(Object? v) {
  if (v is DateTime) return DateTime(v.year, v.month, v.day);
  if (v is String) {
    final d = _strictIsoDay(v.trim());
    if (d != null) return d;
    try {
      final p = parseDate(v);
      return DateTime(p.year, p.month, p.day);
    } on Object {
      return null;
    }
  }
  return null;
}

int? _asPeriod(Object? v) {
  if (v is int) return v;
  if (v is num && v.isFinite) return v.toInt();
  return int.tryParse('$v'.trim());
}

/// Strict `YYYY-MM-DD` (Python's `strptime(iso, "%Y-%m-%d")`).
DateTime? _strictIsoDay(String text) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (m == null) return null;
  final day = DateTime.tryParse(text);
  if (day == null ||
      day.year != int.parse(m.group(1)!) ||
      day.month != int.parse(m.group(2)!) ||
      day.day != int.parse(m.group(3)!)) {
    return null;
  }
  return DateTime(day.year, day.month, day.day);
}

/// Sets `ordered[day]`, dropping other spellings of the same day.
void storeOrdered(Map<String, String> ordered, String day, String meal) {
  try {
    final want = canonicalDayKey(day);
    for (final key in ordered.keys.toList()) {
      if (key != day && canonicalDayKey(key) == want) ordered.remove(key);
    }
  } on Object {
    // Keep both spellings rather than lose the order.
  }
  ordered[day] = meal;
}

/// Live re-check that one applied pick still holds. Never raises.
///
/// A day-level deorder (`&-1&`) is verified through the day's meals
/// (none may read ordered) — the control's own label always reads
/// ordered, so it cannot verify itself.
bool selectionHolds(StravaClient client, Map<String, Object?> pick) {
  try {
    final mealId = '${pick['meal_id'] ?? ''}';
    if (mealId.contains('&-1&')) {
      final meals = [
        for (final m in (pick['all_ids'] as List? ?? const []))
          if (!'$m'.contains('&-1&')) m
      ];
      return meals.every((m) => !client.verified(m));
    }
    return client.verified(mealId);
  } on Object {
    return false;
  }
}

/// What `runRefresh` (refresh.dart) needs from the app.
///
/// Python duck-types this (`app: Any`); Dart needs the shape written
/// down. [Strakalari] implements it; tests use fakes.
abstract class RefreshApp {
  Map<String, Object?> get configData;
  int get goBackWeeks;
  int get goForwardWeeks;
  String get excuseMode;
  String get stravaOrderMode;
  bool get stravaEnable;
  bool get lastOutboxSyncOk;
  int get lastExcuseFailures;
  Set<String> get lastOrderedDays;
  bool get lastOrderLowBalance;
  List<String> get lastUnfundedDays;
  Map<String, Object?> get timetableData;
  Map<String, double> get absencePercentages;
  Map<String, List<Map<String, Object?>>> get grades;
  Map<String, Map<String, Object?>> get quarterlyMarks;
  Map<String, Object?> get absenceDetails;
  Map<String, String> get subjectDirectory;
  Map<String, Map<String, String>> get foodDict;
  Map<String, String> get orderedDict;
  Map<Object, Object?> get stableBaseline;
  bool get stableComplete;
  List<Object?> get weekChanges;
  String get absenceError;
  String get gradesError;
  List<Map<String, Object?>>? get substitutionsOrNull;
  DateTime? get sentExcusesFrom;
  Set<DateTime> get timetableLoadedWeeks;
  set historyWeeks(List<DateTime> weeks);
  List<String> get stravaBlacklist;
  bool get stravaBlacklistBroken;
  set cancelCallback(bool Function()? cb);

  Future<void> fetchBakalariData();
  Future<int> syncWebExcusesToHistory();
  Future<void> fetchStravaData();
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source});
  Future<int> excusePending();
}

class Strakalari implements RefreshApp {
  String encoding;
  void Function(String)? onLog;

  late final ConfigManager configManager;
  late final String configFile;
  @override
  Map<String, Object?> get configData => configManager.data;

  late final String bakalariUrl;
  late final String bakalariUsername;
  late final String bakalariPassword;
  late final bool bakalariPasswordEncrypted;
  @override
  late final int goBackWeeks;
  @override
  late final int goForwardWeeks;
  late final int excuseDelayDays;

  late final String stravaUrl;
  late final String stravaId;
  late final String stravaUsername;
  late final String stravaPassword;
  late final bool stravaPasswordEncrypted;
  @override
  late final bool stravaEnable;
  late final String stravaBlacklistPath;

  @override
  late final String excuseMode;
  late final String defaultExcuseSelection;
  @override
  late final String stravaOrderMode;

  late final List<String> lateIncomeExcuses;
  late final List<String> leftSoonExcuses;
  late final List<String> longAbsenceExcuses;
  late final List<String> shortAbsenceExcuses;
  late final String signature;

  late final String alreadyExcusedFile;
  late final String logFile;

  // Settable so tests can script fakes (mirrors `app.bakalari_client = …`).
  BakalariClient? bakalariClient;
  StravaClient? stravaClient;

  bool loggedIn = false;

  /// Cooperative cancellation flag (set by the GUI worker's cancel()).
  bool cancelRequested = false;

  /// Optional live predicate polled by the Bakaláři week loop so a
  /// cancel issued mid-fetch is honored (forwarded to the client).
  @override
  bool Function()? cancelCallback;

  /// True only after the Komens outbox was actually read this run.
  /// The refresh pipeline never auto-excuses without it: the outbox
  /// is the only record of excuses whose submit went unconfirmed.
  @override
  bool lastOutboxSyncOk = false;
  @override
  int lastExcuseFailures = 0;

  /// Days that really changed on the web in the last order run.
  @override
  Set<String> lastOrderedDays = <String>{};

  /// True when Strava refused an order for lack of money.
  @override
  bool lastOrderLowBalance = false;

  /// Days not attempted because the account ran out of money.
  @override
  List<String> lastUnfundedDays = <String>[];
  Map<String, List<Object?>> _orderReport = {
    'skipped': [],
    'succeeded': [],
    'failed': [],
    'unfunded': [],
  };

  List<String>? _logSecretsKey;
  Set<String>? _logSecrets;

  Strakalari({
    String configFile = './config.json',
    this.encoding = 'utf-8',
    this.onLog,
    Map<String, Object?>? configData,
  }) {
    configManager = ConfigManager(configFile, utf8);
    if (configData != null) {
      // Overrides are stored verbatim under canonical names (no
      // aliases, no migration). Secrets still get the same encryption
      // ConfigManager.set applies.
      for (final entry in configData.entries) {
        final k = entry.key;
        final v = entry.value;
        if ((k == 'bakalari_password' ||
                k == 'strava_password' ||
                k == 'gemini_api_key') &&
            v != null &&
            '$v'.isNotEmpty) {
          // Overrides carry plaintext secrets; encrypt them like
          // ConfigManager.set does so the *_encrypted flag stays
          // truthful. Never re-encrypt an already stored ciphertext.
          if (configManager.data['${k}_encrypted'] == true &&
              configManager.data[k] == v) {
            continue;
          }
          configManager.data[k] = encrypt('$v');
          configManager.data['${k}_encrypted'] = true;
        } else {
          configManager.data[k] = v;
        }
      }
    }
    this.configFile = configManager.configPath;
    final data = configManager.data;

    bakalariUrl = '${data['bakalari_url'] ?? ''}';
    bakalariUsername = '${data['bakalari_username'] ?? ''}';
    bakalariPassword = '${data['bakalari_password'] ?? ''}';
    bakalariPasswordEncrypted = data['bakalari_password_encrypted'] == true;
    goBackWeeks = _clampInt(data['go_back_weeks'], 4, 0, 52);
    goForwardWeeks = _clampInt(data['go_forward_weeks'], 1, 0, 8);
    excuseDelayDays = _strictDelayDays(data['excuse_delay_days']);

    stravaUrl = '${data['strava_url'] ?? ''}';
    // Same legacy read-aliases as StravaClient (read-only compat).
    stravaId = _firstId(data['strava_canteen_id'], data['strava_id']);
    final su = data['strava_username'];
    stravaUsername = (su == null || '$su'.isEmpty)
        ? '${data['strava_user'] ?? ''}'
        : '$su';
    stravaPassword = '${data['strava_password'] ?? ''}';
    stravaPasswordEncrypted = data['strava_password_encrypted'] == true;
    final useStrava = data.containsKey('use_strava')
        ? data['use_strava']
        : data['strava_enable'];
    stravaEnable = useStrava == null ? true : _pyTruthy(useStrava);
    stravaBlacklistPath =
        resolvePath('${data['strava_blacklist'] ?? './strava_blacklist.json'}');

    excuseMode = _mode('${data['excuse_mode'] ?? 'confirm'}');
    defaultExcuseSelection =
        '${data['default_excuse_selection'] ?? 'first'}'.toLowerCase();
    stravaOrderMode = _mode('${data['strava_order_mode'] ?? 'confirm'}');

    lateIncomeExcuses = templateTexts(data['late_income_excuses']);
    leftSoonExcuses = templateTexts(data['left_soon_excuses']);
    longAbsenceExcuses = templateTexts(data['long_absence_excuses']);
    shortAbsenceExcuses = templateTexts(data['short_absence_excuses']);
    signature = '${data['your_signature'] ?? ''}';

    alreadyExcusedFile = resolvePath(
        '${data['already_excused_file'] ?? './already_excused_lessons.json'}');
    logFile = resolvePath('${data['log_file'] ?? './log.txt'}');

    // Both services go over plain HTTP (no browser).
    bakalariClient = BakalariClient(data, logger: writeLog);
    stravaClient = StravaClient(data, logger: writeLog);
  }

  static String _mode(String mode) {
    final m = mode.toLowerCase();
    return (m == 'auto' || m == 'dry_run') ? m : 'confirm';
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

  @override
  Map<String, Object?> get timetableData =>
      bakalariClient?.timetableData ?? <String, Object?>{};

  @override
  Map<Object, Object?> get stableBaseline =>
      bakalariClient?.stableBaseline ?? <Object, Object?>{};

  @override
  bool get stableComplete => bakalariClient?.stableComplete ?? false;

  Map<String, Object?> get stableTimetableData =>
      Map<String, Object?>.of(bakalariClient?.stableTimetableData ?? {});

  @override
  List<Object?> get weekChanges =>
      List<Object?>.of(bakalariClient?.weekChanges ?? []);

  @override
  String get absenceError => bakalariClient?.absenceError ?? '';

  @override
  String get gradesError => bakalariClient?.gradesError ?? '';

  @override
  List<Map<String, Object?>>? get substitutionsOrNull {
    final s = bakalariClient?.substitutions;
    if (s == null) return null;
    return [for (final e in s) Map<String, Object?>.of(e)];
  }

  @override
  DateTime? get sentExcusesFrom => bakalariClient?.sentExcusesFrom;

  @override
  Set<DateTime> get timetableLoadedWeeks =>
      bakalariClient?.timetableLoadedWeeks ?? <DateTime>{};

  @override
  set historyWeeks(List<DateTime> weeks) {
    if (bakalariClient != null) {
      bakalariClient!.historyWeeks = weeks;
    }
  }

  @override
  List<String> get stravaBlacklist =>
      List<String>.of(stravaClient?.stravaBlacklistJson ?? const []);

  @override
  bool get stravaBlacklistBroken =>
      stravaClient?.blacklistBroken ?? false;

  List<Object?> get substitutions =>
      bakalariClient?.substitutions == null
          ? <Object?>[]
          : List<Object?>.of(bakalariClient!.substitutions!);

  @override
  Map<String, Object?> get absenceDetails =>
      Map<String, Object?>.of(bakalariClient?.absenceDetails ?? {});

  @override
  Map<String, String> get subjectDirectory =>
      Map<String, String>.of(bakalariClient?.subjectDirectory ?? {});

  @override
  Map<String, double> get absencePercentages =>
      Map<String, double>.of(bakalariClient?.absencePercentages ?? {});

  @override
  Map<String, List<Map<String, Object?>>> get grades =>
      bakalariClient?.grades ?? <String, List<Map<String, Object?>>>{};

  @override
  Map<String, Map<String, Object?>> get quarterlyMarks =>
      bakalariClient?.quarterlyMarks ?? <String, Map<String, Object?>>{};

  @override
  Map<String, Map<String, String>> get foodDict =>
      stravaClient?.foodDict ?? <String, Map<String, String>>{};

  @override
  Map<String, String> get orderedDict =>
      stravaClient?.orderedDict ?? <String, String>{};

  void close() {
    bakalariClient?.close();
    stravaClient?.close();
  }

  /// `message` with stored passwords / API keys scrubbed out.
  ///
  /// Exception texts can echo a typed secret; `log.txt` is plain text on
  /// disk. The decrypted values are cached per stored ciphertexts, so a
  /// routine line costs a few `contains` checks.
  String _redactLog(String message) {
    try {
      final cfg = configData;
      final key = [
        '${cfg['bakalari_password'] ?? ''}',
        '${cfg['strava_password'] ?? ''}',
        '${cfg['gemini_api_key'] ?? ''}',
      ].join('\x00');
      if (_logSecretsKey == null || _logSecretsKey!.join('\x00') != key) {
        _logSecretsKey = key.split('\x00');
        _logSecrets = secretValues(cfg);
      }
      final secrets = _logSecrets ?? const <String>{};
      return secrets.isEmpty ? message : redactValues(message, secrets);
    } on Object {
      // Fail closed: never write it raw.
      return '(log line withheld: redaction failed)';
    }
  }

  /// Timestamped append to log.txt (rotated past 2 MB); never throws.
  void writeLog(String message) {
    message = _redactLog(message);
    try {
      if (File(logFile).existsSync() &&
          File(logFile).lengthSync() > 2 * 1024 * 1024) {
        final token = tryFileLock('$logFile.lock');
        if (token != null) {
          try {
            final oldLog = '$logFile.old';
            if (File(oldLog).existsSync()) File(oldLog).deleteSync();
            File(logFile).renameSync(oldLog);
          } on FileSystemException {
            // Keep appending; rotation retries next line.
          } finally {
            releaseFileLock(token);
          }
        }
      }
      final now = clock.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
      File(logFile).writeAsStringSync(
          toPlatformNewlines('[$stamp] $message\n\n'),
          mode: FileMode.append, encoding: utf8);
    } on Object catch (e) {
      print('Warning: Could not write to log file: $e');
    }
    final cb = onLog;
    if (cb != null) {
      try {
        cb(message);
      } on Object {
        // Logging must never break a send.
      }
    }
  }

  @override
  Future<void> fetchBakalariData() async {
    final client = bakalariClient;
    if (client == null) return;
    client.cancelRequested = cancelRequested;
    client.cancelCallback = cancelCallback;
    await client.fetchData();
  }

  @override
  Future<void> fetchStravaData() async {
    final client = stravaClient;
    if (stravaEnable && client != null) {
      // Forward cancellation so Zrušit preempts the menu fetch mid-wait.
      client.cancelRequested = cancelRequested;
      client.cancelCallback = cancelCallback;
      await client.fetchData();
    }
  }

  /// Applies `{day: meal_id}` on Strava and records every day's outcome.
  ///
  /// True only when every day went through (or, in `dry_run`, every
  /// pick is on the menu). [lastOrderedDays] lists the days that
  /// really changed on the web, even when another day failed.
  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    lastOrderedDays = <String>{};
    lastOrderLowBalance = false;
    lastUnfundedDays = <String>[];
    _orderReport = {
      'skipped': <Object?>[],
      'succeeded': <Object?>[],
      'failed': <Object?>[],
      'unfunded': <Object?>[],
    };
    var ok = false;
    try {
      ok = await _orderSelected(orders);
    } finally {
      _auditOrders(orders, ok, source);
    }
    return ok;
  }

  void _auditOrders(Map<String, String> orders, bool ok, String source) {
    if (orders.isEmpty) return;
    try {
      final dry = stravaOrderMode == 'dry_run';
      final placed = Set<String>.of(lastOrderedDays);
      final skipped =
          _orderReport['skipped']!.map((d) => '$d').toSet();
      final unfunded =
          _orderReport['unfunded']!.map((d) => '$d').toSet();
      for (final entry in orders.entries) {
        final detail = <String, Object?>{
          'day': entry.key,
          'meal': entry.value,
          'mode': stravaOrderMode,
        };
        late final String outcome;
        if (dry) {
          outcome = ok ? 'dry_run' : 'failed';
        } else if (placed.contains(entry.key)) {
          outcome = 'sent';
        } else if (unfunded.contains(entry.key)) {
          outcome = 'skipped';
          detail['reason'] = 'low_balance';
        } else if (skipped.contains(entry.key)) {
          outcome = 'skipped';
        } else {
          outcome = 'failed';
        }
        final deorder = entry.value.contains('&-1&');
        audit.record('lunch', outcome, source,
            '${entry.key}: ${deorder ? 'cancel lunch' : 'order'}',
            detail: detail);
      }
    } on Object catch (e) {
      // The order result stands.
      writeLog('Warning: could not record the orders in the history: $e');
    }
  }

  Future<bool> _orderSelected(Map<String, String> orders) async {
    if (!stravaEnable || orders.isEmpty || stravaClient == null) {
      return false;
    }
    if (_isCancelled()) {
      writeLog('Strava ordering cancelled by user.');
      return false;
    }
    final isDry = stravaOrderMode == 'dry_run';
    final client = stravaClient!;
    await client.login();
    await client.fetchData();
    if (isDry) {
      writeLog('[Dry-Run] Proposed orders (nothing is sent): $orders');
      var ok = true;
      for (final entry in orders.entries) {
        if (_isCancelled()) {
          writeLog('Strava ordering cancelled by user.');
          ok = false;
          break;
        }
        try {
          final sel = menuSelection(client.foodDict, entry.key);
          if (!sel.containsKey(entry.value)) {
            String? real;
            for (final mid in sel.keys) {
              if (mid.contains('&-1&')) {
                real = mid;
                break;
              }
            }
            if (real != null && entry.value.contains('&-1&')) {
              writeLog('[Dry-Run] ${entry.key}: would use \'$real\'.');
            } else {
              writeLog(
                  '[Dry-Run] ${entry.key}: \'${entry.value}\' is not on the menu, skipping.');
              ok = false;
              continue;
            }
          } else {
            writeLog('[Dry-Run] ${entry.key}: \'${entry.value}\' is on the menu.');
          }
        } on Object catch (e) {
          writeLog(
              '[Dry-Run] ${entry.key}: selection check failed: ${e.runtimeType}: $e');
          ok = false;
        }
      }
      if (ok) {
        writeLog('[Dry-Run] Proposal ready, nothing was saved or sent.');
      }
      return ok;
    }
    client.clicksMade = 0;
    client.insufficientBalance = false;
    final originalOrdered =
        Map<String, String>.of(client.orderedDict);
    late final String cutoff;
    late final Set<DateTime> free;
    try {
      cutoff = resolveLunchCutoffHook(configData);
      free = effectiveCalendarFreeHook(configData);
    } on Object catch (e) {
      // Fail-closed: without a cutoff check no day is verifiably
      // orderable — ordering blind would only produce rejections.
      writeLog(
          'Warning: cutoff check unavailable (${e.runtimeType}), skipping Strava ordering.');
      return false;
    }
    final skipped = _orderReport['skipped']!;
    final succeeded = _orderReport['succeeded']!;
    final failed = _orderReport['failed']!;
    final unfunded = _orderReport['unfunded']!;
    // Cancellations first: they refund money that the meal orders
    // Stage cancellations before orders: deorders free up balance that days
    // after them may need (and never cost any themselves).
    final items = <MapEntry<String, String>>[
      for (final e in orders.entries)
        if (e.value.contains('&-1&')) e,
      for (final e in orders.entries)
        if (!e.value.contains('&-1&')) e,
    ];
    for (final item in items) {
      var day = item.key;
      var mealId = item.value;
      if (_isCancelled()) {
        writeLog('Strava ordering cancelled by user.');
        skipped.add(day);
        break;
      }
      late final DateTime dayDate;
      try {
        final parsed = parseDate(day);
        dayDate = DateTime(parsed.year, parsed.month, parsed.day);
      } on Object {
        writeLog('Skipping order for $day: unparseable date.');
        skipped.add(day);
        continue;
      }
      final now = clock.now();
      final todayDate = DateTime(now.year, now.month, now.day);
      if (dayDate.isBefore(todayDate)) {
        writeLog('Skipping $day: day already passed.');
        skipped.add(day);
        continue;
      }
      try {
        if (!isLunchOrderOpenHook(dayDate, now, cutoff, free)) {
          writeLog('Skipping $day: ordering closed (deadline passed).');
          skipped.add(day);
          continue;
        }
      } on Object {
        // Fail-closed: an uncheckable cutoff must skip the day,
        // never click a meal Strava would reject.
        writeLog('Skipping $day: cutoff check failed.');
        skipped.add(day);
        continue;
      }
      final selection = menuSelection(client.foodDict, day);
      // The GUI synthesizes a deorder id when the menu has no explicit
      // "cancel" element — resolve it to the real one or skip.
      if (!selection.containsKey(mealId)) {
        String? realDeorder;
        for (final mid in selection.keys) {
          if (mid.contains('&-1&')) {
            realDeorder = mid;
            break;
          }
        }
        if (realDeorder != null && mealId.contains('&-1&')) {
          mealId = realDeorder;
        } else {
          if (mealId.contains('&-1&')) {
            writeLog(
                'Skipping deorder for $day: no cancel element on the menu, leaving unchanged.');
          } else {
            writeLog(
                'Skipping order for $day: \'$mealId\' not on the menu.');
          }
          skipped.add(day);
          continue;
        }
      }
      if (client.insufficientBalance && !mealId.contains('&-1&')) {
        // Strava already refused an order for lack of money: every
        // further meal would be refused the same way.
        unfunded.add(day);
        continue;
      }
      final pick = <String, Object?>{
        'day': day,
        'meal_id': mealId,
        'all_ids': selection.keys.toList(),
      };
      writeLog('Ordering lunch for $day: $mealId');
      if (client.order(mealId, pick['all_ids'] as List<Object?>)) {
        succeeded.add(pick);
      } else if (client.insufficientBalance) {
        // Rejected, nothing changed on the web: not a failure to
        // restore, just a day the account could not pay for.
        unfunded.add(day);
      } else {
        String suffix = '';
        try {
          suffix = client.noticeSuffix();
        } on Object {
          suffix = '';
        }
        writeLog(
            'Warning: could not order $mealId for $day, not marking it as ordered.$suffix');
        failed.add(pick);
      }
    }
    if (unfunded.isNotEmpty) {
      lastOrderLowBalance = true;
      lastUnfundedDays = [for (final d in unfunded) '$d'];
      writeLog('Warning: not enough money on the Strava account — not ordered: '
          '${unfunded.join(', ')}. Top up the account and try again.');
    }
    if (client.clicksMade > 0) {
      // Re-check every staged day before saving (fail-closed): a lost
      // one counts as failed.
      for (final pick in succeeded.toList()) {
        if (!selectionHolds(client, pick as Map<String, Object?>)) {
          writeLog(
              'Warning: ${pick['day']}: the selection changed during ordering.');
          succeeded.remove(pick);
          failed.add(pick);
        }
      }
    }
    if (failed.isNotEmpty) {
      // Fail-closed, never partial success: nothing is saved, the
      // staged changes are dropped.
      if (client.clicksMade > 0) {
        try {
          client.restoreOriginal(failed, originalOrdered);
        } on Object catch (e) {
          writeLog('Warning: could not restore the original lunch '
              'selection (${e.runtimeType}: $e) — check Strava.');
        }
      }
      _recordPersisted(client, succeeded.cast<Map<String, Object?>>(),
          originalOrdered);
      final failedDays =
          failed.map((p) => '${(p as Map)['day'] ?? '?'}').join(', ');
      writeLog('Warning: Strava order failed for: $failedDays — nothing was saved; '
          'check the Strava website if unsure.');
      return false;
    }
    if (succeeded.isNotEmpty && client.clicksMade > 0) {
      if (!await client.saveConfirm(
          [for (final p in succeeded) '${(p as Map)['meal_id']}'])) {
        writeLog(
            'Warning: the Strava orders were not confirmed as saved (see above).');
        return false;
      }
    } else if (succeeded.isNotEmpty) {
      writeLog(
          'Strava: the selection already matches the web, nothing to save.');
    }
    for (final p in succeeded.cast<Map<String, Object?>>()) {
      storeOrdered(client.orderedDict, '${p['day']}', '${p['meal_id']}');
      lastOrderedDays.add('${p['day']}');
    }
    if (unfunded.isNotEmpty) {
      return false;
    }
    if (skipped.isNotEmpty) {
      writeLog(
          'Warning: Strava days not ordered: ${skipped.join(', ')}.');
      return false;
    }
    if (succeeded.isEmpty) {
      writeLog('Strava: no meal was selected, nothing to save.');
      return false;
    }
    return true;
  }

  /// Records the succeeded days of a failed run that are web truth.
  ///
  /// A failed run saves nothing (the staged changes are dropped), so
  /// only days that already held the pick before the run count as
  /// ordered. Never raises except [CancelledError].
  void _recordPersisted(StravaClient client,
      List<Map<String, Object?>> succeeded, Map<String, String> original) {
    if (succeeded.isEmpty) return;
    var immediate = client.clicksMade == 0;
    if (!immediate) {
      try {
        // No save button (immediate-save frontend): staged clicks
        // persisted at once.
        immediate = !client.findSaveButton();
      } on CancelledError {
        rethrow;
      } on Object {
        immediate = false;
      }
    }
    for (final pick in succeeded) {
      final day = '${pick['day']}';
      final meal = '${pick['meal_id']}';
      if (immediate || original[day] == meal) {
        storeOrdered(client.orderedDict, day, meal);
        lastOrderedDays.add(day);
      }
    }
    if (lastOrderedDays.isNotEmpty) {
      final held = lastOrderedDays.toList()..sort();
      writeLog('Strava: these days already held the wanted lunch: '
          '${held.join(', ')}.');
    }
  }

  /// Loads the already-excused history, tolerating missing/corrupt files.
  ///
  /// Returns `(normalized_history, history_path)`. A missing file
  /// falls back to the `.example.json` template minus its demo rows.
  /// Raises [StateError] when the file exists but cannot be read right
  /// now (locked) — callers must then neither send nor write.
  ///
  /// Public like Python's `_load_history` (tests drive the
  /// corrupt/busy cases directly).
  (List<Map<String, Object?>>, String) loadHistory() => _loadHistoryImpl();

  (List<Map<String, Object?>>, String) _loadHistoryImpl() {
    final historyFilepath = alreadyExcusedFile;
    var history = <Map<String, Object?>>[];
    var readPath = historyFilepath;
    if (FileSystemEntity.typeSync(readPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final example = examplePathFor(historyFilepath);
      if (File(example).existsSync()) readPath = example;
    }
    if (FileSystemEntity.typeSync(readPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      try {
        final loaded = jsonDecode(
            File(readPath).readAsStringSync(encoding: utf8));
        final list = loaded is List ? loaded : <Object?>[];
        history = [
          for (final h in list)
            if (h is Map) Map<String, Object?>.from(h)
        ];
        if (readPath != historyFilepath) {
          history = [
            for (final h in history)
              if (!isDemoHistoryItem(h)) h
          ];
        }
      } on FormatException catch (e) {
        final backup = readPath == historyFilepath
            ? quarantineCorruptFile(readPath)
            : '';
        final hint =
            backup.isNotEmpty ? ' (corrupt file preserved at $backup)' : '';
        writeLog(
            'Warning: Could not read excuse history, starting fresh: $e$hint');
        history = <Map<String, Object?>>[];
      } on FileSystemException catch (e) {
        // Busy (locked), not corrupt: never quarantine it.
        throw StateError('Excuse history is not readable right now: $e');
      }
    }
    history = [for (final h in history) normalizeHistoryItem(h)];
    return (history, historyFilepath);
  }

  /// Merges excuses already sent on the web into the local history.
  ///
  /// Returns the number of newly added entries. A failed sync (the
  /// client returns null = unknown) changes nothing and returns 0;
  /// [CancelledError] propagates on cancel. [lastOutboxSyncOk] tells
  /// a successful read (even an empty one) from a failed one.
  /// A successful read also settles unconfirmed submits.
  @override
  Future<int> syncWebExcusesToHistory({int? limit}) async {
    lastOutboxSyncOk = false;
    if (_isCancelled()) return 0;
    final client = bakalariClient;
    if (client == null) return 0;
    var capped = limit ?? 100;
    try {
      final raw = configData['sent_excuses_limit'];
      if (limit == null && raw != null) {
        capped = raw is int
            ? raw
            : int.tryParse('$raw'.trim()) ?? 100;
      }
    } on Object {
      capped = 100;
    }
    client.cancelRequested = cancelRequested;
    client.cancelCallback = cancelCallback;
    late final List<Map<String, Object?>>? discovered;
    try {
      discovered = await client.fetchSentExcuses(limit: capped);
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      writeLog(
          'Warning: sent-excuse sync failed: ${e.runtimeType}: $e');
      return 0;
    }
    if (discovered == null) return 0; // unknown, not "nothing sent"
    final guard = HistoryLock(alreadyExcusedFile);
    if (!await guard.acquire()) {
      writeLog('Warning: excuse history is busy, web sync postponed.');
      return 0;
    }
    var added = 0;
    var addedRows = const <Object?>[];
    try {
      await guard.scope(() async {
        late final List<Map<String, Object?>> history;
        late final String historyFilepath;
        try {
          final loaded = _loadHistoryImpl();
          history = loaded.$1;
          historyFilepath = loaded.$2;
        } on Object catch (e) {
          writeLog('Warning: $e — web sync postponed.');
          return;
        }
        final merged = mergeSentExcuses(history, discovered);
        if (merged.$2 > 0) {
          try {
            atomicWriteJson(historyFilepath, merged.$1, encoding: utf8);
          } on Object catch (e) {
            writeLog(
                'Warning: Failed to write history file: ${e.runtimeType}: $e');
            return;
          }
          added = merged.$2;
          addedRows =
              merged.$1.sublist(merged.$1.length - merged.$2);
        }
        lastOutboxSyncOk = true;
        _settleUnconfirmed(
            merged.$1, client.sentExcusesFrom);
      });
    } finally {
      guard.release();
    }
    if (added == 0) return 0;
    // One hour-based web message expands to three history entries
    // (income + soon + days and hours); report distinct messages.
    final messages = <String>{
      for (final item in addedRows)
        if (item is Map)
          storedKeys.sublist(1).map((k) => '${item[k]}').join('|')
    };
    writeLog('Added ${messages.length} excuse(s) already sent on the web '
        'to the history.');
    return added;
  }

  /// Drops unconfirmed submits the freshly read outbox settled.
  ///
  /// Runs under the history lock, right after a successful outbox read.
  /// Never raises: an unsettled row just keeps blocking its re-send.
  void _settleUnconfirmed(
      List<Object?> history, DateTime? outboxFrom) {
    try {
      final pending = loadUnconfirmed(alreadyExcusedFile, utf8);
      if (pending.isEmpty) return;
      final (stillOpen, confirmed, notSent) = resolveUnconfirmed(
          pending, history, outboxFrom);
      if (confirmed.isEmpty && notSent.isEmpty) return;
      saveUnconfirmed(alreadyExcusedFile, stillOpen, utf8);
      for (final entry in confirmed) {
        writeLog('Unconfirmed excuse found in the Komens outbox — it was sent: '
            '${baseExcuse(entry)}');
      }
      for (final entry in notSent) {
        writeLog('Unconfirmed excuse is not in the Komens outbox — it was NOT sent '
            'and may be sent again: ${baseExcuse(entry)}');
      }
    } on Object catch (e) {
      writeLog(
          'Warning: could not settle unconfirmed excuses: ${e.runtimeType}: $e');
    }
  }

  /// Excuses one absence (the Today one-click flow).
  ///
  /// True when the absence is excused afterwards — freshly sent, already
  /// covered by the history, or (`dry_run`) the form was filled
  /// without sending; callers must check `excuse_mode == "dry_run"`
  /// and never treat that as sent.
  Future<bool> excuseSingle(Map<String, Object?> excuse,
      [String? customText]) async {
    final outcome = await sendExcuseOutcome(excuse, customText);
    return outcome == 'sent' ||
        outcome == 'covered' ||
        outcome == 'dry_run';
  }

  /// Manual send of one excuse: `sent` / `covered` / `dry_run` /
  /// `unconfirmed` (submitted, the site never confirmed) / `skipped`
  /// (an earlier unconfirmed submit blocks it) / `failed`.
  Future<String> sendExcuseOutcome(Map<String, Object?> excuse,
      [String? customText]) async {
    return sendExcuse(excuse, customText, source: 'manual');
  }

  /// Fills (and unless [fillOnly] submits) the Bakaláři excuse form.
  Future<bool> _submit(Map<String, Object?> excuse, String? customText,
      {required bool fillOnly}) async {
    final client = bakalariClient!;
    final type = '${excuse['type']}';
    if (type == 'pure days') {
      return fillOnly
          ? client.fillExcuseForm(
              '${excuse['starting_day']}', '${excuse['ending_day']}',
              null, null, customText, true, type)
          : client.executeExcuse(
              '${excuse['starting_day']}', '${excuse['ending_day']}',
              null, null, customText, true, type);
    }
    if (type == 'income' || type == 'soon') {
      final lesson = excuse['starting_lesson'];
      return fillOnly
          ? client.fillExcuseForm(
              '${excuse['starting_day']}', '${excuse['starting_day']}',
              lesson, lesson, customText, false, type)
          : client.executeExcuse(
              '${excuse['starting_day']}', '${excuse['starting_day']}',
              lesson, lesson, customText, false, type);
    }
    if (type == 'days and hours') {
      return fillOnly
          ? client.fillExcuseForm(
              '${excuse['starting_day']}', '${excuse['ending_day']}',
              excuse['starting_lesson'], excuse['ending_lesson'],
              customText, false, type)
          : client.executeExcuse(
              '${excuse['starting_day']}', '${excuse['ending_day']}',
              excuse['starting_lesson'], excuse['ending_lesson'],
              customText, false, type);
    }
    writeLog(
        'Warning: unknown excuse type $type, skipping (no submit).');
    return false;
  }

  /// Sends one excuse unless the history already covers it.
  ///
  /// Returns `"sent"`, `"covered"`, `"dry_run"`, `"unconfirmed"`,
  /// `"skipped"` or `"failed"`; every outcome is also appended to the
  /// automation history. The history check, the submit and the history
  /// write run under one lock, so concurrent senders (UI clicks, auto
  /// refresh, tray) can never excuse the same absence twice.
  ///
  /// Public like Python's `_send_excuse` (tests drive this level, which
  /// is also what [excusePending] sends through).
  Future<String> sendExcuse(Map<String, Object?> excuse,
      String? customText, {String source = 'manual'}) async {
    final outcome = await _sendExcuseInner(excuse, customText);
    try {
      audit.record('excuse', outcome, source,
          audit.describeExcuse(excuse),
          detail: {'type': excuse['type'], 'mode': excuseMode});
    } on Object catch (e) {
      // The send result stands.
      writeLog('Warning: could not record the excuse in the history: $e');
    }
    return outcome;
  }

  Future<String> _sendExcuseInner(
      Map<String, Object?> excuse, String? customText) async {
    final client = bakalariClient;
    if (client == null) {
      writeLog(
          'Warning: Bakaláři client not available, excuse not sent.');
      return 'failed';
    }
    if (excuseMode == 'dry_run') {
      writeLog('[Dry-Run] Preparing the excuse (not sending): $excuse');
      late final bool filled;
      try {
        filled = await _submit(excuse, customText, fillOnly: true);
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        writeLog(
            '[Dry-Run] Preparing the excuse failed: ${e.runtimeType}: $e');
        return 'failed';
      }
      if (filled) {
        writeLog('[Dry-Run] Excuse prepared, nothing was sent.');
      }
      return filled ? 'dry_run' : 'failed';
    }
    final guard = HistoryLock(alreadyExcusedFile);
    if (!await guard.acquire()) {
      writeLog(
          'Warning: another excuse is being sent right now — try again later.');
      return 'failed';
    }
    try {
      return await guard.scope(() async {
        late final List<Map<String, Object?>> history;
        late final String historyFilepath;
        try {
          final loaded = _loadHistoryImpl();
          history = loaded.$1;
          historyFilepath = loaded.$2;
        } on Object catch (e) {
          writeLog('Warning: $e — not sending (duplicate check impossible).');
          return 'failed';
        }
        if (excuseCovered(excuse, history)) {
          writeLog('Already excused, not sending again: $excuse');
          return 'covered';
        }
        late final List<Map<String, Object?>> unconfirmed;
        try {
          unconfirmed = loadUnconfirmed(historyFilepath, utf8);
        } on FileSystemException catch (e) {
          writeLog('Warning: unconfirmed excuses not readable ($e) — '
              'not sending (duplicate check impossible).');
          return 'failed';
        }
        if (unconfirmedBlocks(excuse, unconfirmed)) {
          writeLog('Not sending: an earlier submit of this absence was never confirmed '
              'and may have gone out. The next refresh checks the Komens outbox '
              'and releases it if nothing arrived: $excuse');
          return 'skipped';
        }
        writeLog('Attempting to excuse: $excuse');
        client.lastSubmitUncertain = false;
        late final bool success;
        try {
          await client.login();
          success = await _submit(excuse, customText, fillOnly: false);
        } on CancelledError {
          if (client.lastSubmitUncertain) {
            _recordUnconfirmed(historyFilepath, unconfirmed, excuse);
          }
          rethrow;
        } on Object catch (e, st) {
          writeLog('Exception while excusing $excuse: '
              '${e.runtimeType}: $e\n$st');
          success = false;
        }
        if (!success) {
          if (client.lastSubmitUncertain == true) {
            return _recordUnconfirmed(
                historyFilepath, unconfirmed, excuse);
          }
          writeLog(
              'Warning: excuse NOT sent (the form did not confirm): $excuse');
          return 'failed';
        }
        for (final e in historyEntries(excuse)) {
          if (!history.any((h) => jsonEquals(h, e))) history.add(e);
        }
        try {
          atomicWriteJson(historyFilepath, history, encoding: utf8);
          writeLog('Successfully excused and saved to disk.');
        } on Object catch (e) {
          // Sent, but the duplicate guard does not know it yet: the
          // next web sync re-imports it from the Komens outbox.
          writeLog('Warning: excuse was SENT but the history file could not be '
              'written (${e.runtimeType}: $e); it will be re-synced '
              'from the web on the next refresh.');
        }
        return 'sent';
      });
    } finally {
      guard.release();
    }
  }

  /// Remembers a submit that may have gone out. Returns `"unconfirmed"`.
  ///
  /// Called under the history lock. If the sidecar cannot be written
  /// the excuse goes into the history instead: never re-sending a real
  /// absence is recoverable (the user excuses it by hand), a duplicate
  /// excuse is not.
  String _recordUnconfirmed(String historyFilepath,
      List<Map<String, Object?>> unconfirmed, Map<String, Object?> excuse) {
    writeLog('Warning: the excuse submit was NOT confirmed — it may or may not have been '
        'sent. It will not be sent again until the Komens outbox shows: $excuse');
    try {
      saveUnconfirmed(historyFilepath,
          [...unconfirmed, unconfirmedEntry(excuse)], utf8);
    } on Object catch (e) {
      writeLog('Warning: could not record the unconfirmed excuse (${e.runtimeType}: '
          '$e); marking it as sent to rule out a duplicate.');
      try {
        final (history, path) = _loadHistoryImpl();
        for (final e in historyEntries(excuse)) {
          if (!history.any((h) => jsonEquals(h, e))) history.add(e);
        }
        atomicWriteJson(path, history, encoding: utf8);
      } on Object catch (e2) {
        writeLog(
            'Warning: history write failed too (${e2.runtimeType}: $e2).');
      }
    }
    return 'unconfirmed';
  }

  /// Pending excuses for [excusePending].
  ///
  /// Instance seam so tests can stub the pending list (mirrors
  /// monkeypatching `Strakalari.generate_excuses` in Python).
  List<Map<String, Object?>> pendingExcuses() {
    // Lessons the user ignored in the UI ("excused elsewhere") must
    // never be auto-sent: a second excuse cannot be taken back.
    final ignoredRaw = configData['ignored_excuses'];
    final ignored = ignoredRaw is List ? ignoredRaw : <Object?>[];
    return generateExcuses(Map<String, Object?>.of(timetableData),
        delayDays: excuseDelayDays,
        ignored: ignored,
        notBefore: excuseWindowStart(
            _todayDate(), bakalariClient?.sentExcusesFrom));
  }

  /// Sends every pending excuse (`auto` mode). Returns the number sent.
  ///
  /// `confirm` mode never sends from here — excuses are confirmed one
  /// by one in the UI. `dry_run` fills each form without sending.
  @override
  Future<int> excusePending() async {
    lastExcuseFailures = 0;
    if (excuseMode == 'confirm') {
      writeLog('Excuse mode is \'confirm\' — automatic sending skipped.');
      return 0;
    }
    var sent = 0;
    final pending = pendingExcuses();
    for (final excuse in pending) {
      if (_isCancelled()) {
        writeLog('Excusing cancelled by the user.');
        break;
      }
      final outcome = await sendExcuse(
          excuse, defaultExcuseText(excuse),
          source: 'auto');
      if (outcome == 'sent') {
        sent += 1;
      } else if (outcome == 'failed' || outcome == 'unconfirmed') {
        lastExcuseFailures += 1;
      }
    }
    return sent;
  }

  DateTime _todayDate() {
    final now = clock.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// The configured default excuse text for one excuse.
  String defaultExcuseText(Map<String, Object?> excuse) {
    final type = '${excuse['type']}';
    final start = excuse['starting_day'];
    final end = excuse['ending_day'];
    if (type == 'pure days') {
      final range = start == end ? '$start' : '$start – $end';
      return formatExcuseTemplate(
          _defaultTemplate(longAbsenceExcuses),
          dateStr: range,
          signatureStr: signature);
    }
    if (type == 'income' || type == 'soon') {
      final templates =
          type == 'soon' ? leftSoonExcuses : lateIncomeExcuses;
      return formatExcuseTemplate(_defaultTemplate(templates),
          dateStr: '$start',
          lessonsStr: '${excuse['starting_lesson']}',
          signatureStr: signature);
    }
    final first = excuse['starting_lesson'];
    final last = excuse['ending_lesson'];
    final lessons =
        first == last ? '$first.' : '$first. – $last.';
    return formatExcuseTemplate(
        _defaultTemplate(shortAbsenceExcuses),
        dateStr: '$start',
        lessonsStr: lessons,
        signatureStr: signature);
  }

  /// Picks the default excuse template honoring the selection mode.
  ///
  /// `mode` is "first" (default) or "random". Blank templates are
  /// skipped; returns "" when none is left.
  static String pickTemplate(List<Object?> templates,
      [String mode = 'first']) {
    final usable = [
      for (final t in templates)
        if ('$t'.trim().isNotEmpty) '$t'
    ];
    if (usable.isEmpty) return '';
    if (mode.toLowerCase() == 'random' && usable.length > 1) {
      return usable[Random().nextInt(usable.length)];
    }
    return usable.first;
  }

  String _defaultTemplate(List<String> templates) =>
      pickTemplate(templates, defaultExcuseSelection);

  /// Pending excuses for unexcused absences older than [delayDays].
  ///
  /// [notBefore] (a date) drops older days entirely: they lie outside
  /// the excuse window (see [excuseWindowStart]).
  ///
  /// [ignored] holds UI ignore keys (`YYYY-MM-DD|period|subject`)
  /// or `(date, period)` tuples: those lessons count as excused
  /// elsewhere — never excused again, and they break full-day ranges.
  static List<Map<String, Object?>> generateExcuses(
      Map<String, Object?> rawData,
      {int delayDays = 2,
      DateTime? overrideToday,
      List<Object?>? ignored,
      DateTime? notBefore}) {
    final ignoredPts = ignoredPoints(ignored);
    final todayParam = overrideToday ?? clock.now();
    // Compare plain dates: a datetime cutoff keeps the time-of-day, so
    // the same absence flips included/excluded depending on run hour.
    final todayDate =
        DateTime(todayParam.year, todayParam.month, todayParam.day);
    final cutoffDate = addDays(todayDate, -delayDays);
    final cleanedDays = <DateTime, Map<int, String>>{};
    // Dates that need no excuse themselves but must break a consecutive
    // full-day chain (fully excused days) or downgrade it to partial
    // (days mixing excused and absent lessons).
    final blockedDays = <DateTime>{};

    for (final entry in rawData.entries) {
      late final DateTime parsed;
      try {
        final p = parseDate(entry.key);
        parsed = DateTime(p.year, p.month, p.day);
      } on Object {
        continue;
      }
      if (parsed.isAfter(cutoffDate)) continue;
      if (notBefore != null) {
        final nb = DateTime(notBefore.year, notBefore.month, notBefore.day);
        if (parsed.isBefore(nb)) continue;
      }
      final dayLessons = <int, String>{};
      var hasNonAbsent = false;
      final lessons = entry.value;
      if (lessons is! List) {
        continue;
      }
      for (final raw in lessons) {
        if (raw is! Map) continue;
        final lesson = Map<String, Object?>.from(raw);
        // Malformed rows (no teacher/subject/period) are skipped: they
        // cannot be merged into a range safely, so under-excusing one
        // malformed row beats over-excusing the wrong lessons.
        if ('${lesson['teacher'] ?? ''}'.isEmpty ||
            '${lesson['subject'] ?? ''}'.isEmpty) {
          continue;
        }
        // Cancelled lessons ("Odpadá" / "Zrušeno") and class events need no
        // excuse and prove no attendance — keep them neutral so they neither
        // trigger new excuses nor break/merge full-day ranges.
        if ('${lesson['status'] ?? ''}' == 'cancelled' ||
            isClassEvent(lesson) ||
            isCancelNotice(lesson['notice'])) {
          continue;
        }
        final lessonNum = extractLessonNum(lesson['time']);
        if (lessonNum == null) continue;
        if (ignoredPts.isNotEmpty) {
          // Same period derivation as the UI task keys
          // (Lesson.fromLegacy): explicit "period" first.
          var keyPeriod = lessonNum;
          if (lesson['period'] != null) {
            keyPeriod = int.tryParse('${lesson['period']}'.trim()) ??
                lessonNum;
          }
          if (ignoredPts.contains((parsed, keyPeriod)) ||
              ignoredPts.contains((parsed, lessonNum))) {
            hasNonAbsent = true;
            continue;
          }
        }
        // Same classifier as the UI task list (models.absenceKind).
        final kind =
            absenceKind(lesson['absenceType'], lesson['absencetext']);
        if (kind == 'excused') {
          hasNonAbsent = true;
          continue;
        }
        const statusByKind = {
          'absent': 'absent',
          'late': 'income',
          'soon': 'soon',
          'early': 'soon',
        };
        final status = statusByKind[kind] ?? 'present';
        const priority = {'absent': 3, 'income': 2, 'soon': 2, 'present': 1};
        final current = dayLessons[lessonNum];
        if (current == null ||
            (priority[status] ?? 0) > (priority[current] ?? 0)) {
          dayLessons[lessonNum] = status;
        }
      }
      if (dayLessons.isNotEmpty) {
        final sorted = Map<int, String>.fromEntries(
            dayLessons.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)));
        cleanedDays[parsed] = sorted;
        if (hasNonAbsent) blockedDays.add(parsed);
      } else if (hasNonAbsent) {
        // Fully excused (or otherwise non-actionable) day: nothing to
        // excuse, but it still breaks a full-day chain.
        blockedDays.add(parsed);
      }
    }

    final excuses = <Map<String, Object?>>[];
    final consecutiveFullDays = <DateTime>[];
    DateTime? prevDate;

    void flushFullDays() {
      if (consecutiveFullDays.isEmpty) return;
      String fmt(DateTime d) =>
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      final start = fmt(consecutiveFullDays.first);
      final end = fmt(consecutiveFullDays.last);
      excuses.add({
        'type': 'pure days',
        'starting_day': start,
        'ending_day': end,
      });
      consecutiveFullDays.clear();
    }

    final allDays = {...cleanedDays.keys, ...blockedDays}.toList()
      ..sort((a, b) => a.millisecondsSinceEpoch
          .compareTo(b.millisecondsSinceEpoch));
    for (final day in allDays) {
      // A gap in the data means no school that day (weekend, holiday,
      // untaught day) — it must end a full-day chain instead of being
      // silently bridged into one over-long excuse range.
      if (consecutiveFullDays.isNotEmpty &&
          prevDate != null &&
          daysBetween(prevDate, day) > 1) {
        flushFullDays();
      }
      prevDate = day;
      final dayLessons = cleanedDays[day] ?? <int, String>{};
      if (dayLessons.isEmpty) {
        // Fully excused day: nothing to do, but the chain ends here.
        flushFullDays();
        continue;
      }
      final statuses = dayLessons.values.toList();
      String fmtDay(DateTime d) =>
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      if (!blockedDays.contains(day) &&
          statuses.every((s) => s == 'absent')) {
        // Consecutive school days only: any gap in the data (weekend,
        // holiday — flushed above) or any present/excused school day
        // ends the range, so multi-day excuses never span days off.
        consecutiveFullDays.add(day);
      } else {
        flushFullDays();
        final dayStr = fmtDay(day);
        // groupby by status, preserving lesson order.
        var i = 0;
        final items = dayLessons.entries.toList();
        while (i < items.length) {
          final status = items[i].value;
          var j = i;
          while (j < items.length && items[j].value == status) {
            j++;
          }
          final group = items.sublist(i, j);
          i = j;
          if (status == 'income' || status == 'soon') {
            for (final e in group) {
              excuses.add({
                'type': status,
                'starting_day': dayStr,
                'ending_day': dayStr,
                'starting_lesson': e.key,
                'ending_lesson': e.key,
              });
            }
          } else if (status == 'absent') {
            var sub = <int>[];
            void flushSub() {
              if (sub.isEmpty) return;
              excuses.add({
                'type': 'days and hours',
                'starting_day': dayStr,
                'ending_day': dayStr,
                'starting_lesson': sub.first,
                'ending_lesson': sub.last,
              });
              sub = <int>[];
            }

            for (final e in group) {
              if (sub.isNotEmpty && e.key != sub.last + 1) {
                flushSub();
              }
              sub.add(e.key);
            }
            flushSub();
          }
        }
      }
    }
    flushFullDays();
    return excuses;
  }

  Future<(bool, String)> checkBakalariLogin() async {
    if (bakalariUrl.isEmpty || bakalariUsername.isEmpty) {
      return (false, t('test_bak_missing'));
    }
    try {
      await bakalariClient?.login();
      return (true, t('test_bak_ok'));
    } on Object catch (e) {
      return (false, t('test_bak_failed', args: {'err': e}));
    }
  }

  Future<(bool, String)> checkStravaLogin() async {
    if (stravaId.isEmpty || stravaUsername.isEmpty) {
      return (false, t('test_strava_missing'));
    }
    try {
      await stravaClient?.login();
      return (true, t('test_strava_ok'));
    } on Object catch (e) {
      return (false, t('test_strava_failed', args: {'err': e}));
    }
  }
}

/// Module-level shortcut (mirrors Python's `generate_excuses` alias).
List<Map<String, Object?>> generateExcuses(Map<String, Object?> rawData,
        {int delayDays = 2,
        DateTime? overrideToday,
        List<Object?>? ignored,
        DateTime? notBefore}) =>
    Strakalari.generateExcuses(rawData,
        delayDays: delayDays,
        overrideToday: overrideToday,
        ignored: ignored,
        notBefore: notBefore);
