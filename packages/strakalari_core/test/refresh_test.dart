// Port of the refresh-pipeline tests.
//
// Covers test_refresh_pipeline.py (minus the gemini-fallback case, whose
// SUT is lunch_auto/gemini — phase 3), test_refresh_cancel_keeps_data.py,
// the refresh-owned cases of test_automation_safety.py
// (paused/failed-auto), test_unconfirmed_excuses.py (TestRefreshGate),
// test_strava_low_balance.py (refresh/low-balance half),
// test_session_lock.py (lock primitive usage + ConfigManager merge cases),
// and the low-balance notice. Cases whose SUT is the Flutter UI or another
// phase are NOT here (see the delivery report).
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import '../bin/refresh_dryrun.dart' as refresh_dryrun;
import 'package:strakalari_core/src/automation/audit.dart' as audit;
import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/cancel.dart';
import 'package:strakalari_core/src/automation/refresh.dart';
import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';
import 'package:strakalari_core/src/lunches/gemini.dart';
import 'package:strakalari_core/src/lunches/lunch_auto.dart';
import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/planning/planned_skips.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';
import 'package:strakalari_core/src/strava/client.dart';

import 'fake_bakalari.dart';
import 'parity_cases.dart';
import 'strava_test.dart' as st;

const futureDay = '05.10.2099';
const otherDay = '06.10.2099';

Map<String, Object?> refreshConfig() => {
      'bakalari_url': 'https://bakalari.test',
      'bakalari_username': 'student',
      'strava_username': 'student',
      'strava_canteen_id': '1234',
      'use_strava': true,
      'planned_skips': [
        {'start_date': '2099-10-05', 'end_date': '2099-10-05'}
      ],
    };

/// Minimal planned-skips reader for tests (mirrors
/// `planned_skips.planned_lunch_days` for start/end-date entries).
Set<String> testPlannedLunchDays(Map<String, Object?> cfg) {
  final out = <String>{};
  final stored = cfg['planned_skips'];
  if (stored is! List) return out;
  for (final e in stored) {
    if (e is! Map) continue;
    final s = DateTime.tryParse('${e['start_date'] ?? ''}');
    final en = DateTime.tryParse('${e['end_date'] ?? ''}');
    if (s == null || en == null) continue;
    var d = DateTime(s.year, s.month, s.day);
    final last = DateTime(en.year, en.month, en.day);
    while (!d.isAfter(last)) {
      out.add(
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}');
      d = d.add(const Duration(days: 1));
    }
  }
  return out;
}

/// Gap-fill planner double (mirrors `plan_auto_orders` for the cases the
/// refresh tests exercise: cancelled days get no meal, handled/ordered
/// days are left alone, a broken blacklist orders nothing).
Future<(Map<String, String>, bool)> testPlanAutoOrders(
  Map<String, Map<String, String>> food,
  Map<String, Object?> cfg, {
  List<String> blacklist = const [],
  bool blacklistBroken = false,
  Set<String> cancelledDays = const {},
  Map<String, String> ordered = const {},
  List<String> handled = const [],
  String promptFallback = '',
  RefreshEmit? emit,
}) async {
  if (food.isEmpty) return (<String, String>{}, false);
  if (blacklistBroken) return (<String, String>{}, false);
  final skip = {...cancelledDays, ...handled, ...ordered.keys};
  final orders = <String, String>{};
  for (final day in food.keys) {
    if (skip.contains(day)) continue;
    for (final id in food[day]!.keys) {
      if (!id.contains('&-1&')) {
        orders[day] = id;
        break;
      }
    }
  }
  return (orders, false);
}

/// Minimal handled-days double (mirrors `update_handled_days`: union of
/// previous, ordered and placed days, pruned to the last week, sorted).
List<String> testUpdateHandledDays(
    List<String> previous, Map<String, String> ordered, Set<String> placed,
    [DateTime? today]) {
  final t = today ?? clock.now();
  final day = DateTime(t.year, t.month, t.day);
  final days = {...previous, ...ordered.keys, ...placed};
  final kept = days.where((d) {
    final p = parseCzDate(d);
    return p == null || day.difference(p).inDays <= 7;
  }).toList();
  kept.sort((a, b) {
    final pa = parseCzDate(a) ?? DateTime(9999, 12, 31);
    final pb = parseCzDate(b) ?? DateTime(9999, 12, 31);
    final c = pa.compareTo(pb);
    return c != 0 ? c : a.compareTo(b);
  });
  return kept;
}

/// Fake app (mirrors the FakeApp in test_refresh_pipeline.py).
class FakeApp implements RefreshApp {
  FakeApp(this.calls,
      {this.excuseMode = 'confirm',
      String orderMode = 'confirm',
      this.stravaError,
      this._menu})
      : stravaOrderMode = orderMode;

  final List<Object?> calls;
  @override
  String excuseMode;
  @override
  String stravaOrderMode;
  @override
  bool stravaEnable = true;
  final Object? stravaError;
  final Map<String, Map<String, String>>? _menu;

  @override
  Map<String, Object?> get configData => {};
  @override
  int get goBackWeeks => 4;
  @override
  int get goForwardWeeks => 1;
  @override
  bool get lastOutboxSyncOk => true;
  @override
  int get lastExcuseFailures => 0;
  @override
  Set<String> get lastOrderedDays => {};
  @override
  bool get lastOrderLowBalance => false;
  @override
  List<String> get lastUnfundedDays => const [];
  @override
  Map<String, Object?> get timetableData => {
        '1.9.2099': [
          {'subject': 'M'}
        ]
      };
  @override
  Map<String, double> get absencePercentages => _absence;
  Map<String, double> _absence = {'M': 2.0};
  @override
  Map<String, List<Map<String, Object?>>> get grades => {};
  @override
  Map<String, Map<String, Object?>> get quarterlyMarks => {};
  @override
  Map<String, Object?> get absenceDetails => {};
  @override
  Map<String, String> get subjectDirectory => {};
  @override
  String get absenceError => _absenceError;
  String _absenceError = '';
  @override
  String get gradesError => '';
  @override
  List<Map<String, Object?>>? get substitutionsOrNull => null;
  @override
  DateTime? get sentExcusesFrom => null;
  @override
  Map<Object, Object?> get stableBaseline => {};
  @override
  bool get stableComplete => false;
  @override
  List<Object?> get weekChanges => const [];
  @override
  Set<DateTime> get timetableLoadedWeeks => const {};
  @override
  set historyWeeks(List<DateTime> weeks) {}
  @override
  List<String> get stravaBlacklist => const [];
  @override
  bool get stravaBlacklistBroken => _blacklistBroken;
  bool _blacklistBroken = false;
  @override
  Map<String, Map<String, String>> foodDict = {};
  @override
  Map<String, String> orderedDict = {};
  @override
  set cancelCallback(bool Function()? cb) {}

  @override
  Future<void> fetchBakalariData() async {
    calls.add('bakalari');
  }

  @override
  Future<QuickBakalariOutcome> fetchBakalariQuick(
    Map<String, Object?> previousCache,
    DateTime started, {
    required bool inDayWindow,
  }) async {
    calls.add('bakalari_quick');
    return const QuickBakalariOutcome(marksOk: true, feedOk: true, absenceOk: true);
  }

  @override
  Future<int> syncWebExcusesToHistory() async {
    calls.add('sync');
    return 0;
  }

  @override
  Future<int> excusePending() async {
    calls.add('excuse');
    return 1;
  }

  @override
  Future<void> fetchStravaData() async {
    calls.add('strava');
    final err = stravaError;
    if (err != null) throw err;
    foodDict = Map<String, Map<String, String>>.of(_menu ??
        {
          futureDay: {'t1&1&0': 'Kuřecí řízek', 't1&-1&0': 'x'},
          otherDay: {'t2&1&0': 'Guláš', 't2&-1&0': 'x'},
        });
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    calls.add(('order', Map<String, String>.of(orders)));
    orderedDict.addAll(orders);
    return true;
  }
}

/// Gate fake (mirrors _GateApp in test_unconfirmed_excuses.py).
class GateApp implements RefreshApp {
  GateApp({required bool outboxOk}) : _ok = outboxOk;

  final List<Object?> calls = [];
  final bool _ok;

  @override
  Map<String, Object?> get configData => {};
  @override
  int get goBackWeeks => 4;
  @override
  int get goForwardWeeks => 1;
  @override
  String get excuseMode => 'auto';
  @override
  String get stravaOrderMode => 'confirm';
  @override
  bool get stravaEnable => false;
  @override
  bool get lastOutboxSyncOk => _ok;
  @override
  int get lastExcuseFailures => 0;
  @override
  Set<String> get lastOrderedDays => {};
  @override
  bool get lastOrderLowBalance => false;
  @override
  List<String> get lastUnfundedDays => const [];
  @override
  Map<String, Object?> get timetableData => {
        '1.9.2099': [
          {'subject': 'M'}
        ]
      };
  @override
  Map<String, double> get absencePercentages => {'M': 2.0};
  @override
  Map<String, List<Map<String, Object?>>> get grades => {};
  @override
  Map<String, Map<String, Object?>> get quarterlyMarks => {};
  @override
  Map<String, Object?> get absenceDetails => {};
  @override
  Map<String, String> get subjectDirectory => {};
  @override
  String get absenceError => '';
  @override
  String get gradesError => '';
  @override
  List<Map<String, Object?>>? get substitutionsOrNull => null;
  @override
  DateTime? get sentExcusesFrom => null;
  @override
  Map<Object, Object?> get stableBaseline => {};
  @override
  bool get stableComplete => false;
  @override
  List<Object?> get weekChanges => const [];
  @override
  Set<DateTime> get timetableLoadedWeeks => const {};
  @override
  set historyWeeks(List<DateTime> weeks) {}
  @override
  List<String> get stravaBlacklist => const [];
  @override
  bool get stravaBlacklistBroken => false;
  @override
  Map<String, Map<String, String>> get foodDict => {};
  @override
  Map<String, String> get orderedDict => {};
  @override
  set cancelCallback(bool Function()? cb) {}

  @override
  Future<void> fetchBakalariData() async {
    calls.add('bakalari');
  }

  @override
  Future<QuickBakalariOutcome> fetchBakalariQuick(
    Map<String, Object?> previousCache,
    DateTime started, {
    required bool inDayWindow,
  }) async {
    calls.add('bakalari_quick');
    return const QuickBakalariOutcome(marksOk: true, feedOk: true, absenceOk: true);
  }

  @override
  Future<int> syncWebExcusesToHistory() async => 0;

  @override
  Future<int> excusePending() async {
    calls.add('excuse');
    return 0;
  }

  @override
  Future<void> fetchStravaData() async {}

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    return true;
  }
}

/// Low-balance fake (mirrors _LowBalanceApp in test_strava_low_balance.py).
class LowBalanceApp implements RefreshApp {
  LowBalanceApp(this.menuDays);

  final Map<String, Map<String, String>> menuDays;

  @override
  Map<String, Object?> get configData => {};
  @override
  int get goBackWeeks => 4;
  @override
  int get goForwardWeeks => 1;
  @override
  String get excuseMode => 'confirm';
  @override
  String get stravaOrderMode => 'auto';
  @override
  bool get stravaEnable => true;
  @override
  bool get lastOutboxSyncOk => false;
  @override
  int get lastExcuseFailures => 0;
  @override
  Set<String> get lastOrderedDays => _placed;
  Set<String> _placed = {};
  @override
  bool get lastOrderLowBalance => true;
  @override
  List<String> get lastUnfundedDays => _unfunded;
  List<String> _unfunded = [];
  @override
  Map<String, Object?> get timetableData => {};
  @override
  Map<String, double> get absencePercentages => {};
  @override
  Map<String, List<Map<String, Object?>>> get grades => {};
  @override
  Map<String, Map<String, Object?>> get quarterlyMarks => {};
  @override
  Map<String, Object?> get absenceDetails => {};
  @override
  Map<String, String> get subjectDirectory => {};
  @override
  String get absenceError => '';
  @override
  String get gradesError => '';
  @override
  List<Map<String, Object?>>? get substitutionsOrNull => null;
  @override
  DateTime? get sentExcusesFrom => null;
  @override
  Map<Object, Object?> get stableBaseline => {};
  @override
  bool get stableComplete => false;
  @override
  List<Object?> get weekChanges => const [];
  @override
  Set<DateTime> get timetableLoadedWeeks => const {};
  @override
  set historyWeeks(List<DateTime> weeks) {}
  @override
  List<String> get stravaBlacklist => const [];
  @override
  bool get stravaBlacklistBroken => false;
  @override
  Map<String, Map<String, String>> foodDict = {};
  @override
  Map<String, String> orderedDict = {};
  @override
  set cancelCallback(bool Function()? cb) {}

  @override
  Future<void> fetchBakalariData() async {}

  @override
  Future<QuickBakalariOutcome> fetchBakalariQuick(
    Map<String, Object?> previousCache,
    DateTime started, {
    required bool inDayWindow,
  }) async =>
      const QuickBakalariOutcome();

  @override
  Future<int> syncWebExcusesToHistory() async => 0;

  @override
  Future<int> excusePending() async => 0;

  @override
  Future<void> fetchStravaData() async {
    foodDict = Map<String, Map<String, String>>.of(menuDays);
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    final days = orders.keys.toList()
      ..sort((a, b) => parseCzDate(a)!.compareTo(parseCzDate(b)!));
    _placed = {days.first};
    orderedDict[days.first] = orders[days.first]!;
    _unfunded = days.sublist(1);
    return false;
  }
}

/// [FakeApp] with a Strava blacklist (R5 S5).
class BlacklistApp extends FakeApp {
  BlacklistApp(super.calls, this.blacklist, {super.orderMode, super.menu});

  final List<String> blacklist;

  @override
  List<String> get stravaBlacklist => blacklist;
}

/// [FakeApp] that records the history weeks `runRefresh` hands the client.
class HistoryProbeApp extends FakeApp {
  HistoryProbeApp(super.calls);

  List<DateTime> seenHistoryWeeks = const [];

  @override
  set historyWeeks(List<DateTime> weeks) => seenHistoryWeeks = weeks;
}

void main() {
  late Directory tmp;

  final defaultSchoolYear = schoolYearStartHook;
  final defaultBaseline = baselineToDictHook;
  final defaultNews = findNewsHook;
  final defaultPlan = planAutoOrdersHook;
  final defaultPlanned = plannedLunchDaysHook;
  final defaultHandled = updateHandledDaysHook;
  final defaultFreeDays = freeLunchDaysHook;
  final defaultPlanCancels = planAutoCancelsHook;
  final defaultCancelHandled = updateCancelHandledDaysHook;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('refresh_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    clearKeyCache();
    schoolYearStartHook = (today) => today.month >= 9
        ? DateTime(today.year, 9, 1)
        : DateTime(today.year - 1, 9, 1);
    baselineToDictHook = (_) => <String, Object?>{};
    findNewsHook = (prev, fresh, today) => <(String, String)>[];
    planAutoOrdersHook = testPlanAutoOrders;
    plannedLunchDaysHook = testPlannedLunchDays;
    updateHandledDaysHook = testUpdateHandledDays;
    freeLunchDaysHook = defaultFreeDays;
    planAutoCancelsHook = defaultPlanCancels;
    updateCancelHandledDaysHook = defaultCancelHandled;
  });

  tearDown(() {
    schoolYearStartHook = defaultSchoolYear;
    baselineToDictHook = defaultBaseline;
    findNewsHook = defaultNews;
    planAutoOrdersHook = defaultPlan;
    plannedLunchDaysHook = defaultPlanned;
    updateHandledDaysHook = defaultHandled;
    freeLunchDaysHook = defaultFreeDays;
    planAutoCancelsHook = defaultPlanCancels;
    updateCancelHandledDaysHook = defaultCancelHandled;
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('pipeline', () {
    test('webExcusesSyncBeforeAutoExcuse', () async {
      final calls = <Object?>[];
      await runRefresh(
          FakeApp(calls, excuseMode: 'auto'), refreshConfig());
      expect(calls.indexOf('sync'), lessThan(calls.indexOf('excuse')));
    });

    test('plannedSkipDayNeverAutoOrdered', () async {
      final calls = <Object?>[];
      await runRefresh(
          FakeApp(calls, orderMode: 'auto'), refreshConfig());
      final orders = [
        for (final c in calls)
          if (c is (String, Map<String, String>)) c.$2
      ];
      expect(orders, isNotEmpty);
      expect(orders.first.containsKey(futureDay), isFalse);
      expect(orders.first.containsKey(otherDay), isTrue);
    });

    test('defaultHookOrdersGapDay', () async {
      // The production planner (no Gemini configured): a gap day gets a
      // meal, the planned-skip day gets none.
      planAutoOrdersHook = defaultPlan;
      try {
        final calls = <Object?>[];
        final result = await runRefresh(
            FakeApp(calls, orderMode: 'auto'), refreshConfig());
        final orders = [
          for (final c in calls)
            if (c is (String, Map<String, String>)) c.$2
        ];
        expect(orders, isNotEmpty);
        expect(orders.first.containsKey(futureDay), isFalse);
        expect(orders.first.containsKey(otherDay), isTrue);
        expect(result.lunchesOrdered, 1);
        expect(result.usedGemini, isFalse);
      } finally {
        planAutoOrdersHook = testPlanAutoOrders;
      }
    });

    test('geminiFallbackIsNotAGeminiRun', () async {
      // Gemini offline: the blacklist-filter pick is used and the run does
      // not count as a Gemini run.
      Future<GeminiHttpResponse> offline(
        Uri url, {
        required Map<String, String> headers,
        List<int>? body,
        required Duration timeout,
      }) async {
        throw const SocketException('offline');
      }

      final (orders, used) = await planAutoOrders(
        {
          otherDay: {'t2&1&0': 'Guláš'}
        },
        {
          ...refreshConfig(),
          'gemini_auto_enabled': true,
          'gemini_api_key': 'k',
          'gemini_api_key_encrypted': false,
        },
        geminiTransport: offline,
        geminiSleep: (_) async {},
      );
      expect(used, isFalse);
      expect(orders, {otherDay: 't2&1&0'});
    });

    test('missingHistoryWeeksStepByCalendarDaysLikePython', () async {
      // Real `runRefresh` under the clock on both sides of the Prague DST
      // switches: the history weeks it asks the client for are the ones
      // Python computes (test/parity/dst.json, `missingHistoryWeeks`).
      final cases = loadParityCases('dst')
          .where((c) => c['fn'] == 'missingHistoryWeeks');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final today =
            decodeParityValue((c['args'] as List).first) as DateTime;
        final app = HistoryProbeApp([]);
        await withClock(
            Clock.fixed(DateTime(today.year, today.month, today.day, 9, 30)),
            () => runRefresh(app, refreshConfig()));
        String iso(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        expect([for (final m in app.seenHistoryWeeks) iso(m)],
            [for (final m in c['expected'] as List) m['__date__']],
            reason: iso(today));
      }
    });

    test('brokenBlacklistOrdersNothing', () async {
      final calls = <Object?>[];
      final app = FakeApp(calls, orderMode: 'auto')
        .._blacklistBroken = true;
      await runRefresh(app, refreshConfig());
      expect(
          calls.whereType<(String, Map<String, String>)>(), isEmpty);
    });

    test('stravaFailureKeepsBakalariDataAndReports', () async {
      saveDataCache({
        'strava_meals': {
          '1.1.2099': {'a&1&0': 'old'}
        },
        'last_updated': '01.01.2000 00:00:00',
      });
      final result = await runRefresh(
          FakeApp([], stravaError: StateError('login failed')),
          refreshConfig());
      expect(result.ok, isFalse);
      final cache = loadDataCache();
      expect(cache['absence'], {'M': 2.0});
      expect(cache['strava_meals'], {
        '1.1.2099': {'a&1&0': 'old'}
      });
      expect(cache['last_updated'], '01.01.2000 00:00:00');
    });

    test('trayRefreshPreservesBaselineAndStrava', () async {
      // Port of tests/test_tray_ui_command.py: a refresh with Strava off
      // (and no new stable baseline) keeps the cached menu, orders and
      // baseline. In Flutter the tray's "Refresh now" is the window's own
      // refresh, i.e. this pipeline.
      saveDataCache({
        'timetable': {'d': <Object?>[]},
        'absence': {'M': 1.0},
        'strava_meals': {
          '1.1.2026': {'a&1&0': 'X'}
        },
        'strava_ordered': {'1.1.2026': 'a&1&0'},
        'stable_baseline': {
          'Mon-1': ['Mat']
        },
      }, replace: true);
      final app = FakeApp([])..stravaEnable = false;
      final result = await runRefresh(app, refreshConfig());
      expect(result.ok, isTrue);
      final cache = loadDataCache();
      expect(cache['strava_meals'], {
        '1.1.2026': {'a&1&0': 'X'}
      });
      expect(cache['stable_baseline'], {
        'Mon-1': ['Mat']
      });
    });

    test('emptyMenuKeepsCachedMenu', () async {
      saveDataCache({
        'strava_meals': {
          '1.1.2099': {'a&1&0': 'old'}
        }
      });
      final result =
          await runRefresh(FakeApp([], menu: {}), refreshConfig());
      expect(result.ok, isTrue);
      expect(loadDataCache()['strava_meals'], {
        '1.1.2099': {'a&1&0': 'old'}
      });
    });

    test('stravaStatusTellsWhyTheMenuIsMissing', () async {
      await runRefresh(FakeApp([], menu: {}), refreshConfig());
      expect(loadDataCache()['strava_status'], 'empty');
      await runRefresh(FakeApp([]),
          {...refreshConfig(), 'strava_canteen_id': '', 'strava_username': ''});
      expect(loadDataCache()['strava_status'], 'no_login');
      await runRefresh(FakeApp([]), refreshConfig());
      expect(loadDataCache()['strava_status'], 'ok');
    });

    test('unavailableExtrasSurviveRefresh', () async {
      saveDataCache({
        'absence_details': {
          'M': {'total_hours': 10}
        },
        'subject_directory': {'M': 'Novák'},
        'substitutions': [
          {'day': '1.9.2099'}
        ],
      });
      await runRefresh(FakeApp([]), refreshConfig());
      final cache = loadDataCache();
      expect(cache['absence_details'], {
        'M': {'total_hours': 10}
      });
      expect(cache['subject_directory'], {'M': 'Novák'});
      expect(cache['substitutions'], [
        {'day': '1.9.2099'}
      ]);
    });

    test('failedAbsenceScrapeKeepsLastGoodAbsence', () async {
      saveDataCache({
        'absence': {'M': 7.0}
      });
      final app = FakeApp([]).._absenceError = 'grid did not load';
      app._absence = {};
      await runRefresh(app, refreshConfig());
      expect(loadDataCache()['absence'], {'M': 7.0});
    });
  });

  group('automationSafetyRefresh', () {
    test('pausedRefreshNeverSendsOrOrders', () async {
      final calls = <Object?>[];
      final cfg = {...refreshConfig(), 'automation_paused': true};
      final result = await runRefresh(
          FakeApp(calls, excuseMode: 'auto', orderMode: 'auto'), cfg);
      expect(calls.contains('excuse'), isFalse);
      expect(calls.whereType<(String, Map<String, String>)>(), isEmpty);
      expect(result.automationPaused, isTrue);
      expect(result.bakalariFetched, isTrue);
      expect(result.stravaFetched, isTrue);
    });

    test('failedAutoExcuseIsAnErrorButDataIsFresh', () async {
      final app = _FailingExcuseApp();
      final result = await runRefresh(app, refreshConfig());
      expect(result.excusesSent, 1);
      expect(result.excusesFailed, 2);
      expect(result.automationErrors.map((e) => e.$1), ['auto_excuse']);
      expect(result.automationErrors.first.$2, isA<AutomationError>());
      expect(result.saved.containsKey('last_updated'), isTrue);
    });

    test('failedAutoOrderIsReported', () async {
      final app = _FailingOrderApp();
      final result = await runRefresh(app, refreshConfig());
      expect(
          result.automationErrors.map((e) => e.$1), ['auto_lunch']);
      expect(result.lunchesOrdered, 0);
    });

    test('automationPausedFlagParsing', () {
      expect(automationPaused({'automation_paused': true}), isTrue);
      expect(automationPaused({'automation_paused': 'true'}), isTrue);
      expect(automationPaused({'automation_paused': false}), isFalse);
      expect(automationPaused({}), isFalse);
    });
  });

  group('refreshGate', () {
    test('noAutoExcuseWithoutAnOutboxRead', () async {
      final app = GateApp(outboxOk: false);
      final result = await runRefresh(app, {
        'bakalari_url': 'https://bakalari.test',
        'bakalari_username': 'student',
      });
      expect(app.calls.contains('excuse'), isFalse);
      expect(result.errors.any((e) => e.$1 == 'auto_excuse'), isTrue);
    });

    test('autoExcuseRunsAfterAnOutboxRead', () async {
      final app = GateApp(outboxOk: true);
      await runRefresh(app, {
        'bakalari_url': 'https://bakalari.test',
        'bakalari_username': 'student',
      });
      expect(app.calls.contains('excuse'), isTrue);
    });
  });

  group('cancelKeepsData', () {
    test('cancelAfterFetchKeepsFetchedData', () async {
      var n = 0;
      bool cancel() => ++n > 2;
      final app = _CancelApp();
      await expectLater(
          runRefresh(app, {
            'bakalari_url': 'u',
            'bakalari_username': 's',
            'strava_username': 's',
            'strava_canteen_id': '1',
            'use_strava': true,
          }, isCancelled: cancel),
          throwsA(isA<CancelledError>()));
      final cache = loadDataCache();
      expect(cache['absence'], {'M': 2.0});
      expect(cache.containsKey('strava_meals'), isTrue);
    });
  });

  group('lowBalance', () {
    List<String> days() {
      final start =
          DateTime.now().add(const Duration(days: 30));
      String fmt(DateTime d) =>
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      return [fmt(start), fmt(start.add(const Duration(days: 1))),
          fmt(start.add(const Duration(days: 2)))];
    }

    test('refreshReportsLowBalanceAsItsOwnCase', () async {
      final d = days();
      final menu = {
        d[0]: {'a&1&0': 'Guláš', 'a&2&0': 'Kuře'},
        d[1]: {'b&1&0': 'Řízek', 'b&2&0': 'Rizoto'},
        d[2]: {'c&1&0': 'Polévka', 'c&2&0': 'Těstoviny'},
      };
      final result = await runRefresh(LowBalanceApp(menu), {
        'strava_username': 's',
        'strava_canteen_id': '1',
        'use_strava': true,
      }, scope: 'strava');
      expect(result.lowBalance, isTrue);
      expect(result.onlyLowBalance, isTrue);
      expect(result.automationErrors.first.$2, isA<LowBalanceError>());
      final cache = loadDataCache();
      expect((cache['strava_low_balance'] as Map)['days'], [d[1], d[2]]);
      expect((cache['auto_lunch_handled'] as List).contains(d[0]),
          isTrue);
      expect((cache['auto_lunch_handled'] as List).contains(d[1]),
          isFalse);
    });

    test('lowBalanceNoticeIsClaimedOnceADay', () {
      final today = DateTime(2026, 9, 25);
      expect(claimLowBalanceNotice(today), isTrue);
      expect(claimLowBalanceNotice(today), isFalse);
      expect(claimLowBalanceNotice(today.add(const Duration(days: 1))),
          isTrue);
    });
  });

  group('sessionLock', () {
    test('lockIsExclusiveWithinProcess', () {
      final lock = InterProcessLock('${tmp.path}/session.lock');
      expect(lock.acquire(), isTrue);
      try {
        final second = InterProcessLock('${tmp.path}/session.lock');
        expect(second.acquire(), isFalse);
      } finally {
        lock.release();
      }
      final again = InterProcessLock('${tmp.path}/session.lock');
      expect(again.acquire(), isTrue);
      again.release();
    });

    test('configSaveKeepsOtherProcessEdits', () async {
      final path = '${tmp.path}/config.json';
      final window = ConfigManager(path);
      window.set('theme', 'light');
      window.save();

      final tray = ConfigManager(path);
      tray.set('gemini_last_run', '2026-09-24');
      tray.save();

      window.set('language', 'en');
      window.save();

      final onDisk =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(onDisk['gemini_last_run'], '2026-09-24');
      expect(onDisk['language'], 'en');
      expect(onDisk['theme'], 'light');
      expect(window.get('gemini_last_run'), '2026-09-24');
    });

    test('configSaveOwnEditWinsOnSameKey', () {
      final path = '${tmp.path}/config2.json';
      final a = ConfigManager(path);
      a.save();
      final b = ConfigManager(path);
      b.set('theme', 'light');
      b.save();
      a.set('theme', 'dark');
      a.save();
      final onDisk = File(path).readAsStringSync();
      expect(onDisk.contains('"theme": "dark"'), isTrue);
    });

    test('refreshDryrunSendDayRequiresLocalhost', () async {
      expect(refresh_dryrun.isLoopbackSendUrl('http://127.0.0.1:8080'), isTrue);
      expect(refresh_dryrun.isLoopbackSendUrl('http://localhost:18080/b'), isTrue);
      expect(refresh_dryrun.isLoopbackSendUrl('http://[::1]:8080'), isTrue);
      expect(refresh_dryrun.isLoopbackSendUrl('https://bakalari.school.cz'), isFalse);
      expect(refresh_dryrun.isLoopbackSendUrl('http://192.168.1.10:8080'), isFalse);
      await expectLater(
        refresh_dryrun.main([
          '--url',
          'https://bakalari.school.cz',
          '--send-day',
          '15.09.2026',
        ]),
        throwsArgumentError,
      );
    });
  });

  group('f2SemesterReconciliationAndOutboxCache', () {
    test('reconcilesCurrentSemesterOncePerDayAndKeepsOlderSemesterFrozen',
        () async {
      final cfg = {
        ...refreshConfig(),
        'use_strava': false,
        'go_back_weeks': 4,
        'go_forward_weeks': 1,
      };
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

      // Day 1 Run 1 (2026-11-20): backfills older semester weeks and sets semester_reconciled.
      final app1 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 9, 0)),
          () => runRefresh(app1, cfg, scope: 'bakalari'));
      expect(app1.recordedHistoryRequests.single, isNotEmpty);
      var hist = loadDataCache()[timetableHistoryKey] as Map;
      expect(hist['semester_reconciled'], '2026-11-20');

      // Day 1 Run 2 (same day): historyWeeks is empty.
      final app2 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 15, 0)),
          () => runRefresh(app2, cfg, scope: 'bakalari'));
      expect(app2.recordedHistoryRequests.single, isEmpty);

      // Day 2 Run 1 (2026-11-21): reconciles current-semester weeks outside regular once.
      final app3 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 21, 9, 0)),
          () => runRefresh(app3, cfg, scope: 'bakalari'));
      expect(
          app3.recordedHistoryRequests.single.map(iso).toList()..sort(),
          [
            '2026-08-31',
            '2026-09-07',
            '2026-09-14',
            '2026-09-21',
            '2026-09-28',
            '2026-10-05',
            '2026-10-12',
            '2026-10-19',
          ]);
      hist = loadDataCache()[timetableHistoryKey] as Map;
      expect(hist['semester_reconciled'], '2026-11-21');

      // Day 2 Run 2 (2026-11-21): skipped again.
      final app4 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 21, 14, 0)),
          () => runRefresh(app4, cfg, scope: 'bakalari'));
      expect(app4.recordedHistoryRequests.single, isEmpty);

      // 2nd semester (2027-03-15): seed all prior weeks including sem1; only sem2 reconciles.
      final seededWeeks = <String>[];
      var cur = DateTime(2026, 8, 31);
      while (cur.isBefore(DateTime(2027, 3, 15))) {
        seededWeeks.add(iso(cur));
        cur = addDays(cur, 7);
      }
      saveDataCache({
        timetableHistoryKey: {
          'school_year_start': '2026-09-01',
          'weeks': seededWeeks,
          'semester_reconciled': '2027-03-14',
        },
      });
      final appSem2 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2027, 3, 15, 9, 0)),
          () => runRefresh(appSem2, cfg, scope: 'bakalari'));
      final askedSem2 = appSem2.recordedHistoryRequests.single.map(iso).toList()
        ..sort();
      // 1st semester weeks (< 2027-02-01) stay frozen; regular has 2027-02-22..03-15.
      expect(askedSem2, ['2027-02-01', '2027-02-08', '2027-02-15']);
    });

    test('incompleteSemesterBackfillRetriesMissingWeekAlone', () async {
      final cfg = {
        ...refreshConfig(),
        'use_strava': false,
        'go_back_weeks': 4,
        'go_forward_weeks': 1,
      };
      final skipped = DateTime(2026, 9, 14);
      final app1 = _ReconciliationApp([],
          config: cfg, skipHistoryWeeks: {skipped});
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 9, 0)),
          () => runRefresh(app1, cfg, scope: 'bakalari'));
      var hist = loadDataCache()[timetableHistoryKey] as Map;
      expect(hist['semester_reconciled'], '2026-11-20');
      expect(hist['weeks'], isNot(contains('2026-09-14')));

      // Next run the same day retries only the missing week.
      final app2 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)),
          () => runRefresh(app2, cfg, scope: 'bakalari'));
      expect(app2.recordedHistoryRequests.single, [skipped]);
      hist = loadDataCache()[timetableHistoryKey] as Map;
      expect(hist['semester_reconciled'], '2026-11-20');
      expect(hist['weeks'], contains('2026-09-14'));
    });

    test('persistentlyFailingWeekIsRetriedAloneNotWholeSemester (R4 S2)',
        () async {
      final cfg = {
        ...refreshConfig(),
        'use_strava': false,
        'go_back_weeks': 4,
        'go_forward_weeks': 1,
      };
      final skipped = DateTime(2026, 9, 14);
      final app1 = _ReconciliationApp([],
          config: cfg, skipHistoryWeeks: {skipped});
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 9, 0)),
          () => runRefresh(app1, cfg, scope: 'bakalari'));

      final app2 = _ReconciliationApp([],
          config: cfg, skipHistoryWeeks: {skipped});
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)),
          () => runRefresh(app2, cfg, scope: 'bakalari'));
      expect(app2.recordedHistoryRequests.single, [skipped]);

      // Finish Day 1 cleanly, then verify Day 2 reconciliation also retries
      // only the failing week rather than re-reading the whole semester.
      final app3 = _ReconciliationApp([], config: cfg);
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 11, 0)),
          () => runRefresh(app3, cfg, scope: 'bakalari'));

      final appDay2Run1 = _ReconciliationApp([],
          config: cfg, skipHistoryWeeks: {skipped});
      await withClock(Clock.fixed(DateTime(2026, 11, 21, 9, 0)),
          () => runRefresh(appDay2Run1, cfg, scope: 'bakalari'));

      final appDay2Run2 = _ReconciliationApp([],
          config: cfg, skipHistoryWeeks: {skipped});
      await withClock(Clock.fixed(DateTime(2026, 11, 21, 10, 0)),
          () => runRefresh(appDay2Run2, cfg, scope: 'bakalari'));
      expect(appDay2Run2.recordedHistoryRequests.single, [skipped]);
    });

    test('failedOutboxSyncPreservesPreviousSentExcusesFromAndCache', () async {
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': tmp.path,
        'STRAKALARI_NO_KEYRING': '1',
      });
      saveDataCache({
        sentExcusesFromKey: '2026-08-20',
        outboxDetailsKey: {
          '501': [
            {
              'type': 'pure days',
              'starting_day': '01.09.2026',
              'ending_day': '01.09.2026',
            }
          ]
        },
      });
      final server = FakeBakalari({
        'GET /next/komens.aspx': HttpResponseData(
            statusCode: 500, url: Uri.parse(fakeRoot)),
        'POST /Timetable/GetContentData': (_) => weekContent([
              {
                'day': '20.11.2026',
                'teacher': 'T',
                'subjecttext': 'M',
                'time': '1 (8:00 - 8:45)',
              }
            ]),
        'GET /Absence/Continuous':
            '<script>DatesInformations = ko.mapping.fromJS({"DefaultDateFrom":{"DefaultValue":"2026-09-01T00:00:00+02:00"},"DefaultDateTo":{"DefaultValue":"2026-11-20T00:00:00+01:00"}});</script>',
        'GET /Absence/Continuous/GetAbsenceBySubjects': [
          {'Name': 'M', 'LessonCount': 10, 'Count': 0, 'Percent': 0},
        ],
        'POST /Teaching/Subjects': {'data': <Object?>[]},
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
      });
      final app = Strakalari(
        configFile: '${tmp.path}/config.json',
        configData: {
          ...fakeConfig,
          'bakalari_url': 'https://bakalari.test/login',
          'already_excused_file': '${tmp.path}/history.json',
          'use_strava': false,
          'go_back_weeks': 1,
          'go_forward_weeks': 0,
        },
      );
      app.bakalariClient =
          BakalariClient(app.configManager.data, transport: server);

      final result = await withClock(
          Clock.fixed(DateTime(2026, 11, 20, 10, 0)),
          () => runRefresh(app, app.configData, scope: 'bakalari'));

      expect(result.bakalariFetched, isTrue);
      expect(server.calls('GET', '/next/komens.aspx'), hasLength(1));
      expect(app.lastOutboxSyncOk, isFalse);
      expect(result.saved.containsKey(sentExcusesFromKey), isFalse);
      expect(result.saved.containsKey(outboxDetailsKey), isFalse);
      final cache = loadDataCache();
      expect(cache[sentExcusesFromKey], '2026-08-20');
      expect((cache[outboxDetailsKey] as Map).containsKey('501'), isTrue);
    });
  });

  group('f3AutoCancelLunches', () {
    const plannedDay = '05.10.2099';
    const freeDay = '06.10.2099';
    const partialDay = '07.10.2099';
    const absenceDay = '08.10.2099';
    const keptWholeDay = '09.10.2099';

    setUp(() {
      planAutoOrdersHook = defaultPlan;
      plannedLunchDaysHook = defaultPlanned;
      updateHandledDaysHook = defaultHandled;
    });

    Map<String, Map<String, String>> fourDayMenu() => {
          plannedDay: {'t1&1&0': 'Guláš', 't1&-1&0': 'x'},
          freeDay: {'t2&1&0': 'Řízek', 't2&-1&0': 'x'},
          partialDay: {'t3&1&0': 'Polévka', 't3&-1&0': 'x'},
          absenceDay: {'t4&1&0': 'Rizoto', 't4&-1&0': 'x'},
          keptWholeDay: {'t5&1&0': 'Svíčková', 't5&-1&0': 'x'},
        };

    Map<String, Object?> baseF3Config({String orderMode = 'confirm'}) => {
          ...refreshConfig(),
          'strava_order_mode': orderMode,
          'strava_auto_cancel_lunches': true,
          'user_free_days': ['2099-10-06'],
          'planned_skips': [
            {
              'start_date': '2099-10-05',
              'end_date': '2099-10-05',
              'cancel_lunch': true,
            },
            {
              'start_date': '2099-10-07',
              'end_date': '2099-10-07',
              'start_period': 1,
              'end_period': 2,
            },
            {
              'start_date': '2099-10-09',
              'end_date': '2099-10-09',
              'cancel_lunch': false,
            },
          ],
        };

    test('confirmModeCancelsFreeAndPlannedDaysOnlyNeverPartialOrAbsence',
        () async {
      for (final mode in ['confirm', 'auto']) {
        saveDataCache(<String, Object?>{}, replace: true);
        final calls = <Object?>[];
        final app = FakeApp(calls, orderMode: mode, menu: fourDayMenu())
          ..orderedDict = {
            plannedDay: 't1&1&0',
            freeDay: 't2&1&0',
            partialDay: 't3&1&0',
            absenceDay: 't4&1&0',
            keptWholeDay: 't5&1&0',
          };
        final result = await withClock(
          Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
          () => runRefresh(app, baseF3Config(orderMode: mode), scope: 'strava'),
        );
        expect(result.lunchesCancelled, 2, reason: mode);
        expect(result.autoCancelledDays, {plannedDay, freeDay}, reason: mode);
        expect(
          result.autoCancelledReasons,
          {
            plannedDay: 'planned',
            freeDay: 'free_day',
          },
          reason: mode,
        );
        expect(app.orderedDict[partialDay], 't3&1&0', reason: mode);
        expect(app.orderedDict[absenceDay], 't4&1&0', reason: mode);
        expect(app.orderedDict[keptWholeDay], 't5&1&0', reason: mode);
        final cache = loadDataCache();
        expect((cache[cancelHandledKey] as List).toSet(),
            {plannedDay, freeDay},
            reason: mode);
        if (mode == 'confirm') {
          expect(cache.containsKey(handledKey), isFalse);
        }
      }
    });

    test('multiDayPartialEdgesCancelsOnlyWholeMiddleDay (R5 M1)', () async {
      for (final mode in ['confirm', 'auto']) {
        saveDataCache(<String, Object?>{}, replace: true);
        final calls = <Object?>[];
        final app = FakeApp(
          calls,
          orderMode: mode,
          menu: {
            '05.10.2099': {'t1&1&0': 'Guláš', 't1&-1&0': 'x'},
            '06.10.2099': {'t2&1&0': 'Řízek', 't2&-1&0': 'x'},
            '07.10.2099': {'t3&1&0': 'Polévka', 't3&-1&0': 'x'},
          },
        )..orderedDict = {
            '05.10.2099': 't1&1&0',
            '06.10.2099': 't2&1&0',
            '07.10.2099': 't3&1&0',
          };
        final cfg = <String, Object?>{
          ...refreshConfig(),
          'strava_order_mode': mode,
          'strava_auto_cancel_lunches': true,
          'user_free_days': <String>[],
          'planned_skips': [
            {
              'start_date': '2099-10-05',
              'end_date': '2099-10-07',
              'start_period': 3,
              'end_period': 2,
            },
          ],
        };
        final result = await withClock(
          Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
          () => runRefresh(app, cfg, scope: 'strava'),
        );
        expect(result.lunchesCancelled, 1, reason: mode);
        expect(result.autoCancelledDays, {'06.10.2099'}, reason: mode);
        expect(app.orderedDict['05.10.2099'], 't1&1&0', reason: mode);
        expect(app.orderedDict['06.10.2099'], 't2&-1&0', reason: mode);
        expect(app.orderedDict['07.10.2099'], 't3&1&0', reason: mode);
      }
    });

    test('wholePlannedLunchDaysCoversOnlyWholeDays (R5 M1)', () {
      final cfg = <String, Object?>{
        'planned_skips': [
          {
            'start_date': '2099-10-05',
            'end_date': '2099-10-05',
          },
          {
            'start_date': '2099-10-07',
            'end_date': '2099-10-07',
            'start_period': 1,
            'end_period': 2,
          },
          {
            'start_date': '2099-10-09',
            'end_date': '2099-10-09',
            'cancel_lunch': false,
          },
          {
            'start_date': '2099-10-12',
            'end_date': '2099-10-14',
            'start_period': 3,
            'end_period': 2,
          },
          {
            'start_date': '2099-10-15',
            'end_date': '2099-10-15',
            'start_period': 2,
          },
          {
            'start_date': '2099-10-15',
            'end_date': '2099-10-15',
          },
        ],
      };
      expect(
        wholePlannedLunchDays(cfg),
        {'05.10.2099', '13.10.2099', '15.10.2099'},
      );
    });

    test('allBlacklistedDayIsNotReportedAsCancelled (R5 S5)', () async {
      saveDataCache(<String, Object?>{}, replace: true);
      final calls = <Object?>[];
      // 05.10.: every meal blacklisted, nothing ordered; 06.10.: a normal day.
      final app = BlacklistApp(calls, const ['Guláš'],
          orderMode: 'auto',
          menu: {
            '05.10.2099': {'t1&1&0': 'Guláš', 't1&-1&0': 'x'},
            '06.10.2099': {'t2&1&0': 'Řízek', 't2&-1&0': 'x'},
          });
      final cfg = <String, Object?>{
        ...refreshConfig(),
        'strava_order_mode': 'auto',
        'strava_auto_cancel_lunches': true,
        'user_free_days': <String>[],
        'planned_skips': <Object?>[],
      };
      final result = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(app, cfg, scope: 'strava'),
      );
      final orderCalls =
          calls.whereType<(String, Map<String, String>)>().toList();
      expect(orderCalls, hasLength(1));
      expect(orderCalls.single.$2, {'06.10.2099': 't2&1&0'});
      expect(result.errors, isEmpty);
      expect(result.lunchesOrdered, 1);
      expect(result.lunchesCancelled, 0);
      expect(result.autoCancelledDays, isEmpty);
      expect(loadDataCache().containsKey(cancelHandledKey), isFalse);
    });

    test('disabledSettingCancelsNothingInConfirmOrAutoMode', () async {
      for (final mode in ['confirm', 'auto']) {
        saveDataCache(<String, Object?>{}, replace: true);
        final calls = <Object?>[];
        final app = FakeApp(calls, orderMode: mode, menu: {
          freeDay: {'t2&1&0': 'Řízek', 't2&-1&0': 'x'},
          partialDay: {'t3&1&0': 'Polévka', 't3&-1&0': 'x'},
        })
          ..orderedDict = {freeDay: 't2&1&0'};
        final cfg = {
          ...baseF3Config(orderMode: mode),
          'user_free_days': ['2099-10-06', '2099-10-07'],
          'planned_skips': <Object?>[],
          'strava_auto_cancel_lunches': false,
        };
        final result = await withClock(
          Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
          () => runRefresh(app, cfg, scope: 'strava'),
        );
        expect(result.lunchesCancelled, 0, reason: mode);
        expect(app.orderedDict[freeDay], 't2&1&0', reason: mode);
        if (mode == 'auto') {
          expect(result.lunchesOrdered, 1);
          expect(app.orderedDict[partialDay], 't3&1&0');
        }
      }
    });

    test('automationPausedBlocksAutoCancel', () async {
      final calls = <Object?>[];
      final app = FakeApp(calls, orderMode: 'confirm', menu: fourDayMenu())
        ..orderedDict = {freeDay: 't2&1&0'};
      final cfg = {...baseF3Config(), 'automation_paused': true};
      final result = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(app, cfg, scope: 'strava'),
      );
      expect(result.automationPaused, isTrue);
      expect(result.lunchesCancelled, 0);
      expect(app.orderedDict[freeDay], 't2&1&0');
    });

    test('dryRunSimulatesAutoCancelWithoutRecordingCacheHandled', () async {
      final logs = <String>[];
      final calls = <Object?>[];
      final app = FakeApp(calls, orderMode: 'dry_run', menu: fourDayMenu())
        ..orderedDict = {freeDay: 't2&1&0'};
      final result = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(
          app,
          baseF3Config(orderMode: 'dry_run'),
          scope: 'strava',
          emit: (key, [fmt = const {}]) => logs.add('$key:$fmt'),
        ),
      );
      expect(result.lunchesCancelled, 0);
      expect(result.autoCancelledDays, isEmpty);
      expect(logs.any((l) => l.startsWith('auto_lunch_cancel_dry_run:')), isTrue);
      final cache = loadDataCache();
      expect(cache.containsKey(cancelHandledKey), isFalse);
    });

    test('cancelHandledAndKeptLunchDaysPreventRecancel', () async {
      saveDataCache({
        cancelHandledKey: [freeDay],
      });
      final calls = <Object?>[];
      final app = FakeApp(calls, orderMode: 'confirm', menu: fourDayMenu())
        ..orderedDict = {
          plannedDay: 't1&1&0',
          freeDay: 't2&1&0',
        };
      final result = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(
          app,
          baseF3Config(),
          scope: 'strava',
          keptLunchDays: {plannedDay},
        ),
      );
      expect(result.lunchesCancelled, 0);
      expect(app.orderedDict[freeDay], 't2&1&0');
      expect(app.orderedDict[plannedDay], 't1&1&0');
    });

    test('failedCancelRaisesAutomationError', () async {
      final app = _FailingCancelApp(
        menu: {
          freeDay: {'t2&1&0': 'Řízek', 't2&-1&0': 'x'},
        },
        ordered: {freeDay: 't2&1&0'},
      );
      final logs = <String>[];
      final result = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(
          app,
          {
            ...baseF3Config(),
            'planned_skips': <Object?>[],
          },
          scope: 'strava',
          emit: (key, [fmt = const {}]) => logs.add(key),
        ),
      );
      expect(result.automationErrors, isNotEmpty);
      expect(result.automationErrors.first.$2, isA<AutomationError>());
      expect(logs, contains('auto_lunch_failed'));
    });

    test('endToEndStrakalariFakeStravaCancelsInConfirmAndSkipsSendInDryRun',
        () async {
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': tmp.path,
        'STRAKALARI_NO_KEYRING': '1',
      });
      final dFree = DateTime(2099, 10, 6);
      final transport = st.FakeStravaTransport(
        menu: {
          'table0': [
            st.soup(dFree),
            st.meal(dFree, 1, '1', 'Guláš', count: 1),
            st.meal(dFree, 2, '2', 'Rizoto'),
          ],
        },
      );
      final dryCfg = {
        ...st.testConfig,
        'strava_order_mode': 'dry_run',
        'strava_auto_cancel_lunches': true,
        'user_free_days': ['2099-10-06'],
      };
      final dryApp = Strakalari(
        configFile: '${tmp.path}/cfg_dry.json',
        configData: dryCfg,
      )..stravaClient = StravaClient(dryCfg, transport: transport);

      final dryRes = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(dryApp, dryApp.configData, scope: 'strava'),
      );
      expect(dryRes.ok, isTrue);
      expect(transport.saves, isEmpty);
      var entries =
          audit.recent().where((e) => e['kind'] == 'lunch').toList();
      expect(entries, hasLength(1));
      expect(entries.single['outcome'], 'dry_run');
      expect(entries.single['source'], 'auto');
      expect((entries.single['detail'] as Map)['reason'], 'free_day');
      expect((entries.single['detail'] as Map)['meal'], contains('&-1&'));

      // Live confirm-mode refresh sends the XML cancel through the one path.
      final liveCfg = {
        ...st.testConfig,
        'strava_order_mode': 'confirm',
        'strava_auto_cancel_lunches': true,
        'user_free_days': ['2099-10-06'],
      };
      final liveApp = Strakalari(
        configFile: '${tmp.path}/cfg_live.json',
        configData: liveCfg,
      )..stravaClient = StravaClient(liveCfg, transport: transport);

      final liveRes = await withClock(
        Clock.fixed(DateTime(2099, 10, 1, 9, 0)),
        () => runRefresh(liveApp, liveApp.configData, scope: 'strava'),
      );
      expect(liveRes.ok, isTrue);
      expect(liveRes.lunchesCancelled, 1);
      expect(liveRes.autoCancelledDays, {'06.10.2099'});
      expect(transport.saves, hasLength(1));
      expect(loadDataCache()[cancelHandledKey], ['06.10.2099']);
      entries =
          audit.recent().where((e) => e['kind'] == 'lunch').toList();
      expect(entries.first['outcome'], 'sent');
      expect(entries.first['source'], 'auto');
      expect((entries.first['detail'] as Map)['reason'], 'free_day');
    });
  });
}

class _ReconciliationApp extends FakeApp {
  _ReconciliationApp(
    super.calls, {
    this.skipHistoryWeeks = const {},
    this.config = const {},
  });

  final Set<DateTime> skipHistoryWeeks;
  final Map<String, Object?> config;
  List<DateTime> requestedHistory = [];
  List<List<DateTime>> recordedHistoryRequests = [];
  Set<DateTime> _loaded = {};

  @override
  Map<String, Object?> get configData => config;

  @override
  Set<DateTime> get timetableLoadedWeeks => _loaded;

  @override
  set historyWeeks(List<DateTime> weeks) {
    requestedHistory = List<DateTime>.of(weeks);
    recordedHistoryRequests.add(List<DateTime>.of(weeks));
  }

  @override
  Future<void> fetchBakalariData() async {
    await super.fetchBakalariData();
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final thisMonday = addDays(today, -(today.weekday - 1));
    final regular = {
      for (final off in weekOffsets(goBackWeeks, goForwardWeeks))
        addDays(thisMonday, off * 7),
    };
    _loaded = {
      for (final m in {...regular, ...requestedHistory})
        if (!skipHistoryWeeks.contains(m)) DateTime(m.year, m.month, m.day),
    };
  }
}

/// App whose auto-excuse phase partially fails.
class _FailingExcuseApp extends FakeApp {
  _FailingExcuseApp() : super([], excuseMode: 'auto');

  @override
  Future<int> excusePending() async {
    calls.add('excuse');
    return 1;
  }

  @override
  int get lastExcuseFailures => 2;
}

/// App whose auto-order phase fails.
class _FailingOrderApp extends FakeApp {
  _FailingOrderApp() : super([]) {
    stravaOrderMode = 'auto';
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    return false;
  }
}

/// App whose auto-cancel phase fails in confirm mode.
class _FailingCancelApp extends FakeApp {
  _FailingCancelApp({
    required Map<String, Map<String, String>> menu,
    required Map<String, String> ordered,
  }) : super([], orderMode: 'confirm', menu: menu) {
    orderedDict = Map<String, String>.of(ordered);
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    return false;
  }
}

/// Cancel-after-fetch app (mirrors the _App in
/// test_refresh_cancel_keeps_data.py): cancel fires after both fetches.
class _CancelApp extends LowBalanceApp {
  _CancelApp()
      : super({
          '05.10.2099': {'t1&1&0': 'x'}
        });

  @override
  String get excuseMode => 'confirm';
  @override
  String get stravaOrderMode => 'confirm';
  @override
  Map<String, Object?> get timetableData => {
        '1.9.2099': [
          {'subject': 'M'}
        ]
      };
  @override
  Map<String, double> get absencePercentages => {'M': 2.0};
  @override
  Future<void> fetchStravaData() async {
    foodDict = {
      '05.10.2099': {'t1&1&0': 'x'}
    };
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    return true;
  }

  @override
  Set<String> get lastOrderedDays => {};
  @override
  bool get lastOrderLowBalance => false;
  @override
  List<String> get lastUnfundedDays => const [];
}
