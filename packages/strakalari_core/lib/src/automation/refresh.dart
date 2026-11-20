// The one refresh pipeline: fetch, run auto modes, persist the cache.
//
// Port of strakalari/core/refresh.py. Used by the UI (refresh button +
// in-window scheduler) and by the tray's background scheduler, so both
// behave identically:
//
// 1. Bakaláři: fetch, then pull already-sent web excuses into the local
//    history (before any auto-excuse, so nothing is sent twice).
// 2. Strava: fetch the menu. A failure here is recorded but never discards
//    the Bakaláři data fetched in step 1.
// 3. Auto modes (`auto` only — `confirm`/`dry_run` stay manual):
//    excuses, then lunches (planned-skip days never get a lunch).
// 4. Persist: only good fresh values are merged into the cache. A failed or
//    empty phase keeps the previous cached values; timetables merge
//    day-granular so an unrendered week never deletes known days.
//
// Progress is reported through `emit(key, fmt)` with message keys the
// UI translates; the tray passes no emitter.
//
// Phase-3 wiring: the history needs the school-year start
// (`planning/planner.dart`), the fresh payload needs schedule's
// `baseline_to_dict`, the news need `news.find_news`, and auto lunch
// needs `lunches/lunch_auto.dart` + `planning/planned_skips.dart` —
// like refresh.py's lazy imports of those modules. The hooks below default
// to those canonical functions; tests assign fakes (the Dart mirror of
// monkeypatching the module functions).
import 'package:clock/clock.dart';

import '../bakalari/common.dart';
import '../error_report.dart';
import '../storage/config.dart';
import '../i18n.dart';
import '../models.dart';
import '../storage/cache.dart';
import '../lunches/lunch_auto.dart'
    show
        autoCancelFreeLunchDays,
        cancelHandledKey,
        freeLunchDays,
        handledKey,
        planAutoCancels,
        planAutoOrders,
        stravaAutoCancelEnabled,
        updateCancelHandledDays,
        updateHandledDays;
import '../storage/helpers.dart';
import '../news.dart' show findNews;
import '../planning/planned_skips.dart'
    show plannedLunchDays, wholePlannedLunchDays;
import '../planning/planner.dart' show schoolYearTerms;
import '../planning/schedule.dart' show baselineToDict;
import 'automation.dart';
import 'cancel.dart';
import 'excuse_history.dart' show currentSemesterStart, excuseWindowDays;

/// Emitted progress events: `emit(key, fmt)`.
typedef RefreshEmit = void Function(String key, [Map<String, Object?> fmt]);

/// `scope` values (`all`, `bakalari`, `strava`).
const List<String> refreshScopes = ['all', 'bakalari', 'strava'];

/// First day of the running school year (`planner.school_year_terms`,
/// like refresh.py's `_school_year_start`).
DateTime Function(DateTime today) schoolYearStartHook =
    (today) => schoolYearTerms(today)[0].$2;

/// Serialized stable baseline (`schedule.baseline_to_dict`, like
/// refresh.py's lazy `from .schedule import baseline_to_dict`).
Map<String, Object?> Function(Map<Object, Object?> baseline)
    baselineToDictHook =
    (baseline) => baselineToDict(baseline);

/// `(event, message)` notifications since the previous cache state
/// (`news.find_news`, like refresh.py's `_find_news`).
List<(String, String)> Function(
        Map<String, Object?> previous, Map<String, Object?> fresh,
        DateTime today) findNewsHook = (previous, fresh, today) => [
      for (final e in findNews(previous, fresh, today)) (e.key, e.value)
    ];

/// Auto-mode lunch picks: `(orders, usedGemini)`. Defaults to the real
/// `lunch_auto.planAutoOrders` (async: network/Gemini); tests assign fakes.
Future<(Map<String, String>, bool)> Function(
    Map<String, Map<String, String>> food,
    Map<String, Object?> cfg, {
  List<String> blacklist,
  bool blacklistBroken,
  Set<String> cancelledDays,
  Map<String, String> ordered,
  List<String> handled,
  String promptFallback,
  RefreshEmit? emit,
}) planAutoOrdersHook = planAutoOrders;

/// `DD.MM.YYYY` days off whose lunch should be cancelled
/// (`planned_skips.planned_lunch_days`, like refresh.py's lazy import).
Set<String> Function(Map<String, Object?> cfg) plannedLunchDaysHook =
    (cfg) => plannedLunchDays(cfg);

/// `DD.MM.YYYY` school free days whose ordered lunch should be cancelled.
Set<String> Function(Map<String, Object?> cfg) freeLunchDaysHook =
    (cfg) => freeLunchDays(cfg);

/// Auto-cancel lunch picks for ordered lunches on free/planned days.
Map<String, String> Function(
  Map<String, Map<String, String>>? foodData,
  Map<String, Object?>? configData, {
  Iterable<String>? cancelledDays,
  Map<String, String>? ordered,
  Iterable<String>? cancelHandled,
  bool Function(DateTime)? isOpen,
}) planAutoCancelsHook = planAutoCancels;

/// Days whose auto-cancel was already applied or manually overridden.
List<String> Function(
  Iterable<String>? previous,
  Iterable<String>? added, [
  DateTime? today,
]) updateCancelHandledDaysHook = updateCancelHandledDays;

/// Days auto mode must not touch again (`lunch_auto.update_handled_days`,
/// like refresh.py's lazy import).
List<String> Function(
        List<String> previous, Map<String, String> ordered, Set<String> placed,
        [DateTime? today]) updateHandledDaysHook =
    (previous, ordered, placed, [today]) =>
        updateHandledDays(previous, ordered, placed, today);

/// Result of one [runRefresh].
class RefreshResult {
  String scope;
  Map<String, Object?> saved;
  bool bakalariFetched;
  bool stravaFetched;
  int subjects;
  int menuDays;
  int excusesSent;
  int excusesFailed;
  int lunchesOrdered;
  int lunchesCancelled;

  /// True when `automation_paused` kept an `auto` mode from running.
  bool automationPaused;
  Set<String> autoOrderedDays;
  Set<String> autoCancelledDays;
  Map<String, String> autoCancelledReasons;
  bool usedGemini;

  /// True when Strava refused auto orders for lack of money.
  bool lowBalance;

  /// Days auto mode could not order because the account ran out of money.
  List<String> unfundedDays;

  /// (phase, exception) for phases that failed without aborting the run.
  List<(String, Object)> errors;

  /// (notification event, message) for new marks, absences and timetable
  /// changes since the previous refresh.
  List<(String, String)> news;

  RefreshResult({
    this.scope = 'all',
    Map<String, Object?>? saved,
    this.bakalariFetched = false,
    this.stravaFetched = false,
    this.subjects = 0,
    this.menuDays = 0,
    this.excusesSent = 0,
    this.excusesFailed = 0,
    this.lunchesOrdered = 0,
    this.lunchesCancelled = 0,
    this.automationPaused = false,
    Set<String>? autoOrderedDays,
    Set<String>? autoCancelledDays,
    Map<String, String>? autoCancelledReasons,
    this.usedGemini = false,
    this.lowBalance = false,
    List<String>? unfundedDays,
    List<(String, Object)>? errors,
    List<(String, String)>? news,
  })  : saved = saved ?? <String, Object?>{},
        autoOrderedDays = autoOrderedDays ?? <String>{},
        autoCancelledDays = autoCancelledDays ?? <String>{},
        autoCancelledReasons = autoCancelledReasons ?? <String, String>{},
        unfundedDays = unfundedDays ?? <String>[],
        errors = errors ?? <(String, Object)>[],
        news = news ?? <(String, String)>[];

  bool get ok => errors.isEmpty;

  /// Failures of the auto-send / auto-order phases (fail loudly on these).
  List<(String, Object)> get automationErrors => [
        for (final e in errors)
          if (e.$1 == 'auto_excuse' || e.$1 == 'auto_lunch') e
      ];

  /// True when the only automation failure is an empty Strava account.
  ///
  /// That is not a bug and not worth a bug-report popup or an early
  /// retry every 5 minutes: callers warn (at most once a day) instead.
  bool get onlyLowBalance {
    final auto = automationErrors;
    return auto.isNotEmpty &&
        auto.every((e) => e.$2 is LowBalanceError);
  }
}

/// An `auto` phase did not do what it was supposed to.
///
/// A [UserError]: the UI shows its message as-is (no bug-report
/// traceback) — the reason per item is in the log above it.
class AutomationError extends UserError {
  const AutomationError(super.message);
}

/// Strava refused lunch orders: not enough money on the account.
class LowBalanceError extends AutomationError {
  const LowBalanceError(super.message);
}

/// Data-cache key of the "not enough money on Strava" warning: the last
/// detection (`{"at": iso, "days": [...]}` or null once orders go
/// through again) and the day the user was last notified about it.
const String lowBalanceKey = 'strava_low_balance';
const String lowBalanceNotifiedKey = 'strava_low_balance_notified';

/// Data-cache key of the timetable history: which past weeks of the running
/// school year were fetched once (`{"school_year_start": iso, "weeks": [iso
/// Mondays]}`). Those weeks are history — never re-fetched, never excused.
const String timetableHistoryKey = 'timetable_history';

/// Data-cache key: first day of the range Komens → Odeslané listed on the
/// last sync (ISO date) — bounds the excuse window in the UI.
const String sentExcusesFromKey = 'sent_excuses_from';

/// Data-cache key: how the last Strava fetch went — "ok", "no_login" (the
/// canteen number or username is not saved) or "empty" (logged in, but no
/// menu came back). Lets an empty lunches page say why instead of a bare
/// "refresh". A failed fetch leaves it as it was (the error is shown).
const String stravaStatusKey = 'strava_status';

/// Runs one refresh on an already constructed [Strakalari] app.
///
/// Raises on a Bakaláři failure (nothing is saved then) and
/// [CancelledError] on cancel. Strava and auto-mode failures are
/// recorded in `result.errors` / the log and never lose fetched data.
Future<RefreshResult> runRefresh(
  RefreshApp app,
  Map<String, Object?>? configData, {
  String scope = 'all',
  Iterable<String>? cancelledLunchDays,
  Iterable<String>? keptLunchDays,
  bool Function()? isCancelled,
  RefreshEmit? emit,
  String lunchPrompt = '',
  DateTime? now,
}) async {
  final cfg =
      configData is Map<String, Object?> ? configData : <String, Object?>{};
  final effectiveScope =
      refreshScopes.contains(scope) ? scope : 'all';
  final started = now ?? clock.now();
  final result = RefreshResult(scope: effectiveScope);

  void emitSafe(String key, [Map<String, Object?> fmt = const {}]) {
    if (emit == null) return;
    try {
      emit(key, fmt);
    } on Object {
      // Progress must never break a refresh.
    }
  }

  void checkCancel() {
    if (isCancelled != null && isCancelled()) {
      throw const CancelledError();
    }
  }

  final (hasBak, hasStrava) = hasValidCredentials(cfg);
  final fresh = <String, Object?>{};
  try {
    await _fetchPhases(app, effectiveScope, hasBak, hasStrava, fresh,
        result, emitSafe, checkCancel);
    checkCancel();
    await _autoPhases(app, cfg, fresh, result, emitSafe, isCancelled,
        cancelledLunchDays, keptLunchDays, lunchPrompt);
  } on CancelledError {
    // Cancelled after (part of) the fetch: keep what already arrived
    // (and any auto order that went through) instead of dropping it.
    // No global stamp — the run was not complete.
    if (fresh.isNotEmpty) {
      emitSafe('saving_cache');
      _persist(app, cfg, fresh, started);
    }
    rethrow;
  }

  // -- 4. Persist -------------------------------------------------------
  emitSafe('saving_cache');
  final fetchedAny = result.bakalariFetched || result.stravaFetched;
  final fetchErrors = [
    for (final e in result.errors)
      if (e.$1 != 'auto_excuse' && e.$1 != 'auto_lunch') e
  ];
  if (effectiveScope == 'all' &&
      fetchedAny &&
      fetchErrors.isEmpty) {
    // The global stamp only moves on complete full refreshes, so a
    // partial or failed run never makes stale data look fresh.
    final s = started;
    String two(int n) => n.toString().padLeft(2, '0');
    fresh['last_updated'] =
        '${two(s.day)}.${two(s.month)}.${s.year} '
        '${two(s.hour)}:${two(s.minute)}:${two(s.second)}';
  }
  if (result.bakalariFetched) {
    // Before the save below: the cache still holds the previous state.
    result.news = _findNews(fresh, started);
  }
  _persist(app, cfg, fresh, started);
  result.saved = fresh;
  return result;
}

/// What this run brought since the cached state. Never raises.
List<(String, String)> _findNews(
    Map<String, Object?> fresh, DateTime started) {
  try {
    final today =
        DateTime(started.year, started.month, started.day);
    return findNewsHook(loadDataCache(), fresh, today);
  } on Object catch (exc) {
    // News must never fail a refresh.
    print('Warning: could not compare with the previous data: $exc');
    return <(String, String)>[];
  }
}

/// Merges [fresh] into the data cache (timetables day-granular).
void _persist(RefreshApp app, Map<String, Object?> cfg,
    Map<String, Object?> fresh, DateTime started) {
  if (fresh['timetable'] is Map) {
    Map<String, Object?>? previous;
    try {
      final loaded = loadDataCache()['timetable'];
      previous = loaded is Map ? _strMap(loaded) : null;
    } on Object {
      previous = null;
    }
    final back = _goBackWeeks(app, cfg);
    final startedDate =
        DateTime(started.year, started.month, started.day);
    final windowStart = [
      addDays(startedDate, -(back * 7 + 7)),
      // The running school year stays: it is the timetable history.
      _schoolYearStart(startedDate),
    ].reduce((a, b) => a.isBefore(b) ? a : b);
    fresh['timetable'] = mergeTimetableDays(
        previous, _strMap(fresh['timetable'] as Map),
        windowStart: windowStart);
  }
  if (fresh.isNotEmpty) {
    saveDataCache(fresh);
  }
}

int _goBackWeeks(RefreshApp app, Map<String, Object?> cfg) {
  final fromApp = app.goBackWeeks;
  final raw = fromApp != 0 ? fromApp : cfg['go_back_weeks'];
  if (raw is int) return raw < 0 ? 0 : raw;
  if (raw is double && raw.isFinite) {
    return raw.truncate() < 0 ? 0 : raw.truncate();
  }
  if (raw is bool) return raw ? 1 : 4;
  final parsed = int.tryParse('${raw ?? ''}'.trim());
  if (parsed == null) return 4;
  return parsed < 0 ? 0 : parsed;
}

DateTime _schoolYearStart(DateTime today) {
  final start = schoolYearStartHook(today);
  return DateTime(start.year, start.month, start.day);
}

/// Past school-year Mondays neither in the history nor in the regular window.
List<DateTime> _missingHistoryWeeks(RefreshApp app,
    Map<String, Object?> cfg, DateTime today, Set<DateTime> done) {
  final yearStart = _schoolYearStart(today);
  final thisMonday = addDays(today, -(today.weekday - 1));
  var forward = app.goForwardWeeks;
  if (forward == 0) {
    final raw = cfg['go_forward_weeks'];
    forward = raw is int
        ? raw
        : int.tryParse('${raw ?? 1}'.trim()) ?? 1;
  }
  if (forward < 0) forward = 0;
  final back = _goBackWeeks(app, cfg);
  final regular = {
    for (final off in weekOffsets(back, forward))
      addDays(thisMonday, off * 7)
  };
  final firstMonday = addDays(yearStart, -(yearStart.weekday - 1));
  final missing = <DateTime>[];
  var monday = firstMonday;
  while (monday.isBefore(thisMonday)) {
    if (!regular.contains(monday) && !done.contains(monday)) {
      missing.add(monday);
    }
    monday = addDays(monday, 7);
  }
  return missing;
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _semesterFloorMonday(DateTime today, DateTime yearStart) {
  final sem = currentSemesterStart(today);
  final rolling = addDays(today, -excuseWindowDays);
  var floor = sem.isBefore(rolling) ? sem : rolling;
  if (floor.isBefore(yearStart)) floor = yearStart;
  return addDays(floor, -(floor.weekday - 1));
}

/// Adds the past weeks this run loaded to the stored timetable history.
void _recordHistoryWeeks(
  RefreshApp app,
  Map<String, Object?> fresh,
  DateTime today,
  Set<DateTime> done,
) {
  final yearStart = _schoolYearStart(today);
  final firstMonday = addDays(yearStart, -(yearStart.weekday - 1));
  final thisMonday = addDays(today, -(today.weekday - 1));
  final loaded = {
    for (final m in app.timetableLoadedWeeks)
      if (!m.isBefore(firstMonday) && m.isBefore(thisMonday))
        DateTime(m.year, m.month, m.day)
  };
  fresh[timetableHistoryKey] = <String, Object?>{
    'school_year_start': _isoDate(yearStart),
    'weeks': [
      for (final m in {...done, ...loaded}) _isoDate(m)
    ]..sort(),
    'semester_reconciled': _isoDate(today),
  };
}

/// Good fresh Bakaláři values only; failed parts are left out.
Map<String, Object?> _bakalariPayload(RefreshApp app) {
  final payload = <String, Object?>{
    'timetable': Map<String, Object?>.of(app.timetableData),
  };
  final absence = app.absencePercentages;
  if (absence.isNotEmpty || app.absenceError == '') {
    payload['absence'] = Map<String, double>.of(absence);
  }
  final grades = app.grades;
  if (grades.isNotEmpty || app.gradesError == '') {
    payload['grades'] = {
      for (final e in grades.entries) e.key: e.value
    };
    // Read from the same page, so it is exactly as fresh as the grades.
    payload['quarterly_marks'] = Map<String, Map<String, Object?>>.of(
        app.quarterlyMarks);
  }
  final substitutions = app.substitutionsOrNull;
  if (substitutions != null) {
    payload['substitutions'] = substitutions;
  }
  final details = app.absenceDetails;
  if (details.isNotEmpty) {
    payload['absence_details'] = Map<String, Object?>.of(details);
  }
  final directory = app.subjectDirectory;
  if (directory.isNotEmpty) {
    payload['subject_directory'] = Map<String, String>.of(directory);
  }
  Map<String, Object?> baseline = const {};
  try {
    baseline = baselineToDictHook(app.stableBaseline);
  } on Object {
    baseline = const {};
  }
  // Only a scraped "Stálý" view is ever stored; a failed scrape keeps
  // the last scraped baseline in the cache.
  if (baseline.isNotEmpty && app.stableComplete) {
    payload['stable_baseline'] = baseline;
    payload['stable_baseline_source'] = 'scraped';
  }
  return payload;
}

String _firstLine(Object exc) {
  final text = '$exc'.trim();
  if (text.isEmpty) return exc.runtimeType.toString();
  final first = text.split('\n').first;
  return first.length > 200 ? first.substring(0, 200) : first;
}

Future<void> _fetchPhases(
    RefreshApp app,
    String scope,
    bool hasBak,
    bool hasStrava,
    Map<String, Object?> fresh,
    RefreshResult result,
    RefreshEmit emit,
    void Function() checkCancel) async {
  // -- 1. Bakaláři ------------------------------------------------------
  if (scope == 'all' || scope == 'bakalari') {
    if (!hasBak) {
      emit('bakalari_skipped_log');
    } else {
      checkCancel();
      final now = clock.now();
      final today = DateTime(now.year, now.month, now.day);
      final yearStart = _schoolYearStart(today);
      final (done, reconciledOn) = _historyState(yearStart);
      final todayIso = _isoDate(today);
      final floorMonday = _semesterFloorMonday(today, yearStart);
      final effectiveDone = reconciledOn == todayIso
          ? done
          : {for (final m in done) if (m.isBefore(floorMonday)) m};
      final missing =
          _missingHistoryWeeks(app, app.configData, today, effectiveDone);
      app.historyWeeks = missing;
      if (missing.isNotEmpty) {
        emit('timetable_history_log', {'n': missing.length});
      }
      emit('fetching_bakalari');
      await app.fetchBakalariData();
      final payload = _bakalariPayload(app);
      emit('baseline_log', {
        'slots': app.stableBaseline.length,
        'changes': app.weekChanges.length,
      });
      final hasTimetable = payload['timetable'] is Map &&
          (payload['timetable'] as Map).isNotEmpty;
      final hasAbsence = payload['absence'] is Map &&
          (payload['absence'] as Map).isNotEmpty;
      if (hasTimetable || hasAbsence) {
        fresh.addAll(payload);
        result.bakalariFetched = true;
        result.subjects =
            (payload['absence'] as Map?)?.length ?? 0;
        _recordHistoryWeeks(app, fresh, today, effectiveDone);
        emit('bakalari_done_log', {'n': result.subjects});
      } else {
        emit('refresh_empty_warn');
      }
      try {
        await app.syncWebExcusesToHistory();
      } on CancelledError {
        rethrow;
      } on Object catch (exc) {
        emit('excuse_sync_failed', {'err': _firstLine(exc)});
      }
      if (app.lastOutboxSyncOk) {
        final outboxFrom = app.sentExcusesFrom;
        if (outboxFrom != null) {
          fresh[sentExcusesFromKey] = _isoDate(outboxFrom);
        }
        if (app is Strakalari) {
          final detailsCache = app.outboxDetailsCache;
          if (detailsCache != null) {
            fresh[outboxDetailsKey] = detailsCache;
          }
        }
      }
    }
  }
  // -- 2. Strava --------------------------------------------------------
  if (scope == 'all' || scope == 'strava') {
    if (!app.stravaEnable) {
      emit('strava_disabled_skip');
    } else if (!hasStrava) {
      emit('strava_skipped_log');
      fresh[stravaStatusKey] = 'no_login';
    } else {
      checkCancel();
      emit('fetching_menu');
      try {
        await app.fetchStravaData();
      } on CancelledError {
        rethrow;
      } on Object catch (exc) {
        result.errors.add(('strava', exc));
        emit('strava_fetch_failed', {'err': _firstLine(exc)});
        return;
      }
      final food = Map<String, Map<String, String>>.of(app.foodDict);
      if (food.isNotEmpty) {
        fresh['strava_meals'] = food;
        fresh['strava_ordered'] =
            Map<String, String>.of(app.orderedDict);
        result.stravaFetched = true;
        result.menuDays = food.length;
        fresh[stravaStatusKey] = 'ok';
        emit('strava_done_log', {'n': food.length});
      } else {
        fresh[stravaStatusKey] = 'empty';
        emit('strava_menu_empty');
      }
    }
  }
}

/// Mondays already in the timetable history of this school year, plus the
/// `YYYY-MM-DD` date of the last daily current-semester reconciliation.
(Set<DateTime>, String) _historyState(DateTime yearStart) {
  Map<String, Object?> stored = const {};
  try {
    final loaded = loadDataCache()[timetableHistoryKey];
    if (loaded is Map) stored = _strMap(loaded);
  } on Object {
    stored = const {};
  }
  if (stored['school_year_start'] != _isoDate(yearStart)) {
    return (<DateTime>{}, ''); // first run, or a new school year
  }
  final done = <DateTime>{};
  final weeks = stored['weeks'];
  if (weeks is List) {
    for (final raw in weeks) {
      final day = DateTime.tryParse('$raw');
      if (day == null) continue;
      if ('$raw'.length != 10) continue;
      done.add(DateTime(day.year, day.month, day.day));
    }
  }
  final reconciled = stored['semester_reconciled'];
  final reconciledOn = reconciled is String ? reconciled : '';
  return (done, reconciledOn);
}

Future<void> _autoPhases(
    RefreshApp app,
    Map<String, Object?> cfg,
    Map<String, Object?> fresh,
    RefreshResult result,
    RefreshEmit emit,
    bool Function()? isCancelled,
    Iterable<String>? cancelledLunchDays,
    Iterable<String>? keptLunchDays,
    String lunchPrompt) async {
  // -- 3. Auto modes ----------------------------------------------------
  final paused = automationPaused(cfg);
  var wantsExcuse =
      result.bakalariFetched && app.excuseMode == 'auto';
  var wantsLunchOrder =
      result.stravaFetched && app.stravaOrderMode == 'auto';
  var wantsLunchCancel =
      result.stravaFetched && stravaAutoCancelEnabled(cfg);
  if (paused && (wantsExcuse || wantsLunchOrder || wantsLunchCancel)) {
    result.automationPaused = true;
    emit('automation_paused_log');
    wantsExcuse = wantsLunchOrder = wantsLunchCancel = false;
  }

  if (wantsExcuse && app.lastOutboxSyncOk == false) {
    // The outbox is the only record of submits the site never
    // confirmed: without reading it, a re-send could duplicate one.
    wantsExcuse = false;
    result.errors
        .add(('auto_excuse', AutomationError(t('auto_excuse_outbox_unknown'))));
    emit('auto_excuse_outbox_unknown');
  }

  if (wantsExcuse) {
    emit('auto_excuse_log');
    try {
      app.cancelCallback = isCancelled;
      result.excusesSent = await app.excusePending();
      result.excusesFailed = app.lastExcuseFailures;
      if (result.excusesSent > 0) {
        emit('auto_excuses_sent', {'n': result.excusesSent});
      }
      if (result.excusesFailed > 0) {
        throw AutomationError(
            t('auto_excuses_failed', args: {'n': result.excusesFailed}));
      }
    } on CancelledError {
      rethrow;
    } on Object catch (exc) {
      result.errors.add(('auto_excuse', exc));
      emit('auto_excuse_failed', {'err': _firstLine(exc)});
    }
  }

  if (wantsLunchOrder || wantsLunchCancel) {
    await _autoLunch(
      app,
      cfg,
      fresh,
      result,
      emit,
      cancelledLunchDays,
      keptLunchDays,
      lunchPrompt,
      autoOrder: wantsLunchOrder,
      autoCancel: wantsLunchCancel,
    );
  }
}

/// Auto-mode lunch orders and automatic cancellations on free/planned days.
Future<void> _autoLunch(
    RefreshApp app,
    Map<String, Object?> cfg,
    Map<String, Object?> fresh,
    RefreshResult result,
    RefreshEmit emit,
    Iterable<String>? cancelledLunchDays,
    Iterable<String>? keptLunchDays,
    String lunchPrompt, {
    required bool autoOrder,
    required bool autoCancel,
}) async {
  List<String> handled = <String>[];
  if (autoOrder) {
    emit('auto_lunch_log');
    try {
      final raw = loadDataCache()[handledKey];
      handled = raw is List ? [for (final h in raw) '$h'] : <String>[];
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: could not read $handledKey from cache: $e');
      handled = <String>[];
    }
  }
  List<String> cancelHandled = <String>[];
  try {
    final raw = loadDataCache()[cancelHandledKey];
    cancelHandled = raw is List ? [for (final h in raw) '$h'] : <String>[];
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: could not read $cancelHandledKey from cache: $e');
    cancelHandled = <String>[];
  }
  final effectiveCancelHandled = <String>{
    for (final d in cancelHandled) canonicalDayKey(d),
    for (final d in keptLunchDays ?? const <String>[]) canonicalDayKey(d),
  };
  final orderedBefore = Map<String, String>.of(app.orderedDict);
  var placed = <String>{};
  // True when the run ended before showing whether money was short.
  var balanceUnknown = false;
  try {
    final plannedDays = {
      for (final d in plannedLunchDaysHook(cfg)) canonicalDayKey(d),
      for (final d in cancelledLunchDays ?? const <String>[])
        canonicalDayKey(d),
    };
    final wholePlannedDays = {
      for (final d in wholePlannedLunchDays(cfg)) canonicalDayKey(d),
    };
    final cancelPlannedDays = plannedDays.intersection(wholePlannedDays);
    final freeDays = autoCancelFreeLunchDays(cfg, freeLunchDaysHook(cfg));
    final allCancelled = plannedDays.union(freeDays);
    final cancelTargets = cancelPlannedDays.union(freeDays);
    // When both flags apply to the same day, 'planned' explains the explicit skip.
    final cancelReasons = <String, String>{
      for (final d in freeDays) d: 'free_day',
      for (final d in cancelPlannedDays) d: 'planned',
    };
    final food = Map<String, Map<String, String>>.of(app.foodDict);
    final deorders = autoCancel
        ? planAutoCancelsHook(
            food,
            cfg,
            cancelledDays: cancelTargets,
            ordered: orderedBefore,
            cancelHandled: effectiveCancelHandled,
          )
        : <String, String>{};
    late Map<String, String> orders;
    var usedGemini = false;
    if (autoOrder) {
      final (plannedOrders, geminiUsed) = await planAutoOrdersHook(
        food,
        cfg,
        blacklist: List<String>.of(app.stravaBlacklist),
        blacklistBroken: app.stravaBlacklistBroken,
        cancelledDays: allCancelled,
        ordered: orderedBefore,
        handled: handled,
        promptFallback: lunchPrompt,
        emit: (key, [fmt = const <String, Object?>{}]) => emit(key, fmt),
      );
      usedGemini = geminiUsed;
      orders = Map<String, String>.of(plannedOrders);
      // planAutoOrdersHook keeps its legacy signature; filter out any
      // cancellations it produced for days disabled, partial, or already handled.
      orders.removeWhere((day, mealId) {
        if (!mealId.contains('&-1&')) return false;
        final canon = canonicalDayKey(day);
        if (!cancelTargets.contains(canon)) return true;
        return !autoCancel || effectiveCancelHandled.contains(canon);
      });
      orders.addAll(deorders);
    } else {
      if (deorders.isEmpty) return;
      emit('auto_lunch_cancel_log');
      orders = Map<String, String>.of(deorders);
    }
    result.usedGemini = usedGemini;
    if (orders.isEmpty) {
      if (autoOrder) emit('auto_lunch_none');
      return;
    }
    final appliedReasons = <String, String>{
      for (final e in orders.entries)
        if (e.value.contains('&-1&'))
          e.key: cancelReasons[canonicalDayKey(e.key)] ?? 'planned',
    };
    if (app is Strakalari) {
      app.nextCancelReasons = appliedReasons;
    }
    final isDry = app.stravaOrderMode == 'dry_run';
    if (await app.stravaOrderSelected(orders, source: 'auto')) {
      if (isDry) {
        final cancelCount =
            orders.values.where((v) => v.contains('&-1&')).length;
        if (cancelCount > 0) {
          emit('auto_lunch_cancel_dry_run', {'n': cancelCount});
        }
      } else {
        placed = orders.keys.toSet();
        final orderedPlaced = <String>{
          for (final d in placed)
            if (!(orders[d] ?? '').contains('&-1&')) d,
        };
        final cancelledPlaced = <String>{
          for (final d in placed)
            if ((orders[d] ?? '').contains('&-1&')) d,
        };
        fresh['strava_ordered'] = Map<String, String>.of(app.orderedDict);
        if (autoOrder) fresh[lowBalanceKey] = null; // orders go through again
        result.autoOrderedDays = Set<String>.of(orderedPlaced);
        result.lunchesOrdered = orderedPlaced.length;
        result.autoCancelledDays = Set<String>.of(cancelledPlaced);
        result.lunchesCancelled = cancelledPlaced.length;
        result.autoCancelledReasons = {
          for (final d in cancelledPlaced)
            if (appliedReasons.containsKey(d)) d: appliedReasons[d]!,
        };
        if (orderedPlaced.isNotEmpty) {
          emit('auto_lunch_sent', {'n': orderedPlaced.length});
        }
        if (cancelledPlaced.isNotEmpty) {
          emit('auto_lunch_cancelled', {'n': cancelledPlaced.length});
          fresh[cancelHandledKey] =
              updateCancelHandledDaysHook(cancelHandled, cancelledPlaced);
        }
      }
    } else {
      placed = isDry ? <String>{} : Set<String>.of(app.lastOrderedDays);
      final orderedPlaced = <String>{
        for (final d in placed)
          if (!(orders[d] ?? '').contains('&-1&')) d,
      };
      final cancelledPlaced = <String>{
        for (final d in placed)
          if ((orders[d] ?? '').contains('&-1&')) d,
      };
      if (placed.isNotEmpty) {
        // Partial: what went through is web truth all the same.
        fresh['strava_ordered'] = Map<String, String>.of(app.orderedDict);
        result.autoOrderedDays = Set<String>.of(orderedPlaced);
        result.lunchesOrdered = orderedPlaced.length;
        result.autoCancelledDays = Set<String>.of(cancelledPlaced);
        result.lunchesCancelled = cancelledPlaced.length;
        result.autoCancelledReasons = {
          for (final d in cancelledPlaced)
            if (appliedReasons.containsKey(d)) d: appliedReasons[d]!,
        };
        if (cancelledPlaced.isNotEmpty) {
          fresh[cancelHandledKey] =
              updateCancelHandledDaysHook(cancelHandled, cancelledPlaced);
        }
      }
      final unfunded = List<String>.of(app.lastUnfundedDays);
      if (app.lastOrderLowBalance && unfunded.isNotEmpty) {
        result.lowBalance = true;
        result.unfundedDays = unfunded;
        fresh[lowBalanceKey] = {
          'at': _isoStamp(clock.now()),
          'days': _sortedDays(unfunded.toSet()),
        };
        if (orders.length - placed.length - unfunded.length <= 0) {
          // Nothing else went wrong: an empty account, not a bug.
          throw LowBalanceError(
              t('strava_low_balance', args: {'n': unfunded.length}));
        }
      }
      throw AutomationError(t(
          autoOrder ? 'auto_orders_failed' : 'auto_cancels_failed',
          args: {
            'n': orders.length - placed.length,
            'total': orders.length,
          }));
    }
  } on CancelledError {
    balanceUnknown = true;
    rethrow;
  } on Object catch (exc) {
    // AutomationError is raised above after a finished order run; any
    // other error (login, page) ended the run before that.
    balanceUnknown = exc is! AutomationError;
    result.errors.add(('auto_lunch', exc));
    emit('auto_lunch_failed', {'err': _firstLine(exc)});
  } finally {
    if (autoOrder) {
      if (!result.lowBalance && !balanceUnknown) {
        // Nothing was refused for lack of money this run (topped up, or
        // the days were ordered elsewhere): the warning is over.
        fresh[lowBalanceKey] = null;
      }
      try {
        fresh[handledKey] = updateHandledDaysHook(
            handled,
            app.orderedDict.isNotEmpty ? app.orderedDict : orderedBefore,
            placed);
      } on Object catch (e) {
        // The handled list is a hint; never fail a refresh on it.
        // ignore: avoid_print
        print('Warning: could not update $handledKey: $e');
      }
    }
  }
}

/// True when the user paused all automatic sending and ordering.
bool automationPaused(Map<String, Object?>? configData) {
  final value = (configData ?? {})['automation_paused'];
  if (value is bool) return value;
  if (value == null) return false;
  return ['true', '1', 'yes']
      .contains('$value'.trim().toLowerCase());
}

/// Remembers ([days]) or clears (null) the low-balance warning. Never raises.
void recordLowBalance([Iterable<String>? days]) {
  try {
    if (days == null) {
      saveDataCache({lowBalanceKey: null});
    } else {
      saveDataCache({
        lowBalanceKey: {
          'at': _isoStamp(clock.now()),
          'days': _sortedDays(Set<String>.of(days)),
        }
      });
    }
  } on Object {
    // The warning is a hint; never fail on it.
  }
}

/// True at most once per day: whether to notify about an empty account.
///
/// The scheduler retries every interval, and one toast per run would nag
/// all day about the same unpaid lunches. Shared by the tray and the
/// window through the data cache. Never raises.
bool claimLowBalanceNotice([DateTime? today]) {
  final now = today ?? clock.now();
  final stamp =
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  try {
    if (loadDataCache()[lowBalanceNotifiedKey] == stamp) {
      return false;
    }
    saveDataCache({lowBalanceNotifiedKey: stamp});
  } on Object {
    // Claiming is best-effort.
  }
  return true;
}

/// String-keyed copy of a decoded JSON map.
Map<String, Object?> _strMap(Map<dynamic, dynamic> value) =>
    value.map((k, v) => MapEntry('$k', v as Object?));

/// Calendar sort key for `DD.MM.YYYY` days (plain strings sort 01.12
/// before 30.11).
List<String> _sortedDays(Set<String> days) {
  final parsed = <(DateTime, String)>[];
  for (final d in days) {
    parsed.add((parseCzDate(d) ?? DateTime(9999, 12, 31), d));
  }
  parsed.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return [for (final p in parsed) p.$2];
}

String _isoStamp(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-'
      '${two(now.month)}-${two(now.day)}T'
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}
