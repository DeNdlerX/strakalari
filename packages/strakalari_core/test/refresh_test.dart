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
import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/cancel.dart';
import 'package:strakalari_core/src/automation/refresh.dart';
import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

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

void main() {
  late Directory tmp;

  final defaultSchoolYear = schoolYearStartHook;
  final defaultBaseline = baselineToDictHook;
  final defaultNews = findNewsHook;
  final defaultPlan = planAutoOrdersHook;
  final defaultPlanned = plannedLunchDaysHook;
  final defaultHandled = updateHandledDaysHook;

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
  });

  tearDown(() {
    schoolYearStartHook = defaultSchoolYear;
    baselineToDictHook = defaultBaseline;
    findNewsHook = defaultNews;
    planAutoOrdersHook = defaultPlan;
    plannedLunchDaysHook = defaultPlanned;
    updateHandledDaysHook = defaultHandled;
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
