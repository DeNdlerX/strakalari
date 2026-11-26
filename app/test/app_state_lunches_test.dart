import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/lunches/lunches_live.dart';
import 'package:app/features/lunches/lunches_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/widgets/overlays.dart';

class _SendOrdersApp extends Strakalari {
  final List<Map<String, String>> calls;

  _SendOrdersApp(this.calls)
      : super(configData: {'strava_order_mode': 'confirm'});

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    calls.add(Map<String, String>.of(orders));
    return true;
  }

  @override
  void close() {}
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_app_lunches_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    allowMissingKeyStoreForTesting = true;
    clearKeyCache();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    allowMissingKeyStoreForTesting = false;
    clearKeyCache();
    notifierBackend = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('test_ai_recommend (AppState)', () {
    const food = {
      '16.09.2026': {'a&1&0': 'Kureci rizek', 'a&2&0': 'Veprova pecene'},
      '17.09.2026': {'b&1&0': 'Rybi file', 'b&2&0': 'Sunkove koleno'},
    };

    Future<AppState> runAiState(bool Function(String day) cutoffOpen) async {
      final state = AppState(data: {
        'absence': {'M': 1.0},
        'strava_meals': {
          '16.09.2026': Map<String, String>.of(food['16.09.2026']!),
          '17.09.2026': Map<String, String>.of(food['17.09.2026']!),
        },
      });
      state.demoMode = false;
      state.recommendLunchesFn = (
        foodData,
        pref,
        apiKey, {
        model = 'gemini-3.8-flash',
        language = 'cs',
      }) async =>
          ('', {'16.09.2026': 'a&1&0', '17.09.2026': 'b&1&0'});
      state.isLunchOrderOpenOverride = (day, [now]) => cutoffOpen(day);
      Future<void>? job;
      state.spawn = (fn, name) {
        job = fn();
      };
      expect(state.startAiRecommend(), isTrue);
      await job;
      return state;
    }

    test('workerReportsClosedDaysSeparately', () async {
      final state = await runAiState((day) => day != '16.09.2026');
      expect(state.orders, {'17.09.2026': 'b&1&0'});
      final lastLog = state.logLines.last;
      expect(lastLog, contains(Strings.get('to_send')));
      expect(lastLog, contains(Strings.get('lunch_closed_count')));
      expect(lastLog, isNot(contains(Strings.get('skipped_reason'))));
    });

    test('workerSaysClosedWhenEverythingIsPastCutoff', () async {
      final state = await runAiState((day) => false);
      expect(state.orders, isEmpty);
      expect(state.logLines.last, contains(Strings.get('lunch_order_closed')));
    });

    test('recommendRespectsSkipAndMarksPending', () async {
      final state = AppState(
        configData: {'gemini_api_key': 'AIza-test'},
        data: {
          'absence': {'M': 1.0},
          'strava_meals': {
            '07.09.2026': {'m1': 'Kureci', 'm2': 'Vepro'},
            '08.09.2026': {'m3': 'Ryba', 'm4': 'Testoviny'},
          },
        },
      );
      state.demoMode = false;
      state.cancelledLunches = {'07.09.2026'};
      state.isLunchOrderOpenOverride = (day, [now]) => true;
      state.recommendLunchesFn = (
        foodData,
        pref,
        apiKey, {
        model = 'gemini-3.8-flash',
        language = 'cs',
      }) async =>
          ('', {'07.09.2026': 'm1', '08.09.2026': 'm3'});
      Future<void>? job;
      state.spawn = (fn, name) {
        job = fn();
      };
      final view = LunchesView(
        controller: lunchControllerFor(state),
        onRecommend: () async {
          state.startAiRecommend();
          await job;
        },
      );
      await view.recommend();
      expect(state.aiRunning, isFalse);
      expect(
        state.logLines.any(
            (line) => line.contains('AI') || line.contains('K odeslání')),
        isTrue,
      );
      expect(state.orders.containsKey('07.09.2026'), isFalse);
      expect(state.orders['08.09.2026'], 'm3');
      expect(state.pendingOrders, contains('08.09.2026'));
    });

    test('recommendBusyGuardSnacksInsteadOfRerunning', () async {
      SnackLog.clear();
      final state = AppState(configData: {'gemini_api_key': 'AIza-test'});
      state.aiRunning = true;
      final view = LunchesView(
        controller: lunchControllerFor(state),
        onRecommend: () async {
          if (!state.startAiRecommend()) {
            state.lastSnackMessage = Strings.get('ai_already_running');
          }
        },
      );
      expect(state.startAiRecommend(), isFalse);
      await view.recommend();
      expect(view.controller.aiRunning, isTrue);
    });
  });

  group('test_strava_blacklist_edits', () {
    late AppState state;
    late File path;

    setUp(() {
      path = File('${tmp.path}/strava_blacklist.json');
      state = AppState();
      state.blacklistPathOverride = () => path.path;
    });

    test('addRefusesOnCorruptFile', () {
      const original = '["vepřové", "houby", "játra",]';
      path.writeAsStringSync(original, encoding: utf8);
      expect(state.addBlacklistWord('ryba'), isFalse);
      expect(path.readAsStringSync(encoding: utf8), original);
      expect(state.blacklistEditError, isNotEmpty);
    });

    test('removeRefusesOnNonList', () {
      path.writeAsStringSync('{"houby": 1}', encoding: utf8);
      expect(state.removeBlacklistWord('houby'), isFalse);
      expect(jsonDecode(path.readAsStringSync(encoding: utf8)), {'houby': 1});
    });

    test('addAndRemoveKeepExistingWords', () {
      path.writeAsStringSync('["houby", "játra"]', encoding: utf8);
      expect(state.addBlacklistWord('ryba'), isTrue);
      expect(
        jsonDecode(path.readAsStringSync(encoding: utf8)),
        ['houby', 'játra', 'ryba'],
      );
      expect(state.removeBlacklistWord('houby'), isTrue);
      expect(
        jsonDecode(path.readAsStringSync(encoding: utf8)),
        ['játra', 'ryba'],
      );
    });

    test('addToMissingFileCreatesIt', () {
      expect(state.addBlacklistWord('ryba'), isTrue);
      expect(jsonDecode(path.readAsStringSync(encoding: utf8)), ['ryba']);
    });
  });

  group('test_lunch_auto_user_choice (AppState)', () {
    final future = DateTime.now().add(const Duration(days: 30));
    final day1 = fmtDay(future);
    final day2 = fmtDay(future.add(const Duration(days: 1)));

    test('restartDoesNotResurrectMealOnPlannedDay', () {
      final iso = fmtIso(future);
      saveDataCache({
        'strava_ordered': {day1: 'a&1&0'},
        'strava_meals': {
          day1: {'a&1&0': 'Guláš', 'a&2&0': 'Kuře', 'a&-1&0': 'x'},
        },
      });
      final st = AppState(configData: {
        'planned_skips': [
          {'start_date': iso, 'end_date': iso},
        ],
      });
      expect(st.cancelledLunches, contains(day1));
      expect(st.orders.containsKey(day1), isFalse);
      expect(st.webOrders[day1], 'a&1&0');
    });

    test('sendOnlyTransmitsPendingPicks', () async {
      final state = AppState(data: {
        'absence': {'M': 1.0},
      });
      state.demoMode = false;
      state.isLunchOrderOpenOverride = (day, [now]) => true;
      Future<void> Function()? captured;
      state.spawn = (job, name) {
        captured = job;
      };
      state.orders
        ..clear()
        ..addAll({day1: 'a&1&0', day2: 'b&2&0'});
      state.webOrders = {day1: 'a&1&0'};
      state.pendingOrders
        ..clear()
        ..add(day2);
      final calls = <Map<String, String>>[];
      state.createApp = ({onLog, configData}) => _SendOrdersApp(calls);
      expect(state.submitOrders(), isTrue);
      await captured!();
      expect(calls, [
        {day2: 'b&2&0'},
      ]);
    });
  });

  group('hidden meals follow the menu', () {
    const day = '08.12.2027';
    const next = '09.12.2027';

    test('avoidedAllergensAreHiddenFromTheStart', () {
      saveDataCache({
        'absence': {'M': 1.0},
        'strava_ordered': <String, Object?>{},
        'strava_meals': {
          day: {
            'table1&1&0': 'oběd 1 - Řízek(01, 07 )',
            'table1&2&0': 'oběd 2 - Rizoto',
            'table1&-1&0': 'x',
          },
        },
      });
      final st = AppState(configData: {
        'strava_allergens': [7],
      });
      expect(st.demoMode, isFalse);
      expect(st.lunchHidden, {'table1&1&0'});
    });

    test('aNewDayMovesHiddenMealsAndStagedPicksToTheNewIds', () {
      saveDataCache({
        'absence': {'M': 1.0},
        'strava_ordered': <String, Object?>{},
        'strava_meals': {
          day: {
            'table1&1&0': 'oběd 1 - Řízek(01, 07 )',
            'table1&2&0': 'oběd 2 - Rizoto',
            'table1&-1&0': 'x',
          },
        },
      });
      final st = AppState(configData: {
        'use_strava': true,
        'strava_allergens': [7],
      });
      st.isLunchOrderOpenOverride = (d, [now]) => true;
      expect(st.orderLunch(day, 'table1&2&0'), isTrue);
      // A day later the same day is the menu's first table.
      saveDataCache({
        'strava_meals': {
          day: {
            'table0&1&0': 'oběd 1 - Řízek(01, 07 )',
            'table0&2&0': 'oběd 2 - Rizoto',
            'table0&-1&0': 'x',
          },
          next: {
            'table1&1&0': 'oběd 1 - Guláš',
            'table1&2&0': 'oběd 2 - Kuře(07 )',
            'table1&-1&0': 'x',
          },
        },
      });
      st.reloadCache();
      expect(st.lunchHidden, {'table0&1&0', 'table1&2&0'});
      expect(st.orders[day], 'table0&2&0');
      expect(st.pendingOrders, contains(day));
      expect(st.lunchSubmitPayload(), {day: 'table0&2&0'});
    });
  });

  group('test_lunch_cutoff (AppState)', () {
    test('stateRejectsClosedDayAndFiltersSubmit', () {
      final state = AppState(data: {});
      state.isLunchOrderOpenOverride = (day, [now]) => day != '08.09.2026';
      expect(state.orderLunch('08.09.2026', 'm1'), isFalse);
      expect(state.orders.containsKey('08.09.2026'), isFalse);
      state.orders['08.09.2026'] = 'm1';
      state.pendingOrders.add('08.09.2026');
      expect(state.submitOrders(), isFalse);
      expect(state.orders['08.09.2026'], 'm1');
      expect(state.pendingOrders, contains('08.09.2026'));
    });
  });

  group('test_lunch_day_keys (AppState)', () {
    test('cachedOrdersUseCanonicalDayKeys', () {
      saveDataCache({
        'absence': {'M': 1.0},
        'strava_ordered': {'4.9.2026': 't&1&0', '5.9.2026': 't&2&0'},
      });
      final state = AppState();
      state.cancelledLunches = {'04.09.2026'};
      state.orders.clear();
      state.reloadCache();
      expect(state.orders, {'05.09.2026': 't&2&0'});
      expect(state.webOrders, {'04.09.2026': 't&1&0', '05.09.2026': 't&2&0'});
    });

    test('recordWebOrdersDropsOtherSpellings', () {
      saveDataCache({
        'strava_ordered': {'4.9.2026': 'old', '6.9.2026': 'x'},
      });
      final state = AppState();
      state.recordWebOrders({'04.09.2026': 'new'});
      final saved = loadDataCache()['strava_ordered'];
      expect(saved, {'6.9.2026': 'x', '04.09.2026': 'new'});
    });
  });

  group('test_strava_low_balance (AppState)', () {
    test('uiLowBalanceIsAWarningNotAnError', () {
      final notified = <String>[];
      final state = AppState(configData: {
        'notifications': {'lunch_skipped': true},
      });
      notifierBackend = _CallbackNotifier((tag, body) => notified.add(tag));
      state.warnLowBalance('no money');
      state.warnLowBalance('no money');
      expect(notified, ['lunch_skipped']);
    });
  });

  group('f3AutoCancelLunches (AppState)', () {
    test('manualWebPickRecordsCancelHandledAndSurvivesRestart', () {
      withClock(Clock.fixed(DateTime(2099, 10, 1, 9, 0)), () {
        final cfg = {
          'use_strava': true,
          'planned_skips': [
            {
              'start_date': '2099-10-06',
              'end_date': '2099-10-06',
              'cancel_lunch': true,
            },
          ],
        };
        saveDataCache({
          'strava_ordered': {'06.10.2099': ''},
        });
        final s1 = AppState(configData: cfg);
        expect(s1.cancelledLunches, contains('06.10.2099'));

        // User manually picks a real meal on Strava for that planned day.
        s1.recordWebOrders({'6.10.2099': 'm&1&0'});
        expect(s1.cancelledLunches, isNot(contains('06.10.2099')));
        expect(loadDataCache()[cancelHandledKey], ['06.10.2099']);

        // Across app restart, the manual pick is NOT resurrected into cancelledLunches.
        final s2 = AppState(configData: cfg);
        expect(s2.cancelledLunches, isNot(contains('06.10.2099')));
        expect(s2.orders['06.10.2099'], 'm&1&0');
      });
    });

    test('planningSkipOrAddingFreeDayClearsCancelHandledAfterSave', () {
      withClock(Clock.fixed(DateTime(2099, 10, 1, 9, 0)), () {
        saveDataCache({
          cancelHandledKey: ['06.10.2099', '07.10.2099', '08.10.2099'],
          'strava_ordered': {
            '06.10.2099': 'm1&1&0',
            '07.10.2099': 'm2&1&0',
            '08.10.2099': 'm3&1&0',
          },
          'strava_meals': {
            '06.10.2099': {'m1&1&0': 'Guláš', 'm1&-1&0': 'x'},
            '07.10.2099': {'m2&1&0': 'Řízek', 'm2&-1&0': 'x'},
            '08.10.2099': {'m3&1&0': 'Ryba', 'm3&-1&0': 'x'},
          },
        });
        final state = AppState(configData: {'use_strava': true})
          ..isLunchOrderOpenOverride = (_, [_]) => true;

        // Failed save must roll back and leave cancelHandledKey untouched.
        final lock = InterProcessLock('${state.config.configPath}.lock');
        expect(lock.acquire(), isTrue);
        try {
          expect(
            state.planCustomSkip(
              '2099-10-06',
              '2099-10-06',
              null,
              null,
              'reason',
              cancelLunch: true,
            ),
            isFalse,
          );
          expect(loadDataCache()[cancelHandledKey],
              ['06.10.2099', '07.10.2099', '08.10.2099']);
        } finally {
          lock.release();
        }

        // Successful planCustomSkip clears 06.10.2099 from cancelHandledKey.
        expect(
          state.planCustomSkip(
            '2099-10-06',
            '2099-10-06',
            null,
            null,
            'reason',
            cancelLunch: true,
          ),
          isTrue,
        );
        expect(loadDataCache()[cancelHandledKey], ['07.10.2099', '08.10.2099']);

        // planEntries clears 08.10.2099 after save succeeds.
        expect(
          state.planEntries([
            {
              'start_date': '2099-10-08',
              'end_date': '2099-10-08',
              'template': 'reason',
              'cancel_lunch': true,
            },
          ]),
          1,
        );
        expect(loadDataCache()[cancelHandledKey], ['07.10.2099']);

        // Adding a free day via AppState.save clears 07.10.2099 too.
        expect(
          state.save({
            'user_free_days': ['2099-10-07'],
          }),
          isTrue,
        );
        expect(loadDataCache()[cancelHandledKey], isEmpty);
      });
    });

    test('filterAndAiRecommendSkipFreeDays', () async {
      await withClock(Clock.fixed(DateTime(2026, 9, 1, 9, 0)), () async {
        saveDataCache({
          'absence': {'M': 1.0},
          'strava_meals': {
            '16.09.2026': {'a&1&0': 'Kuřecí řízek', 'a&-1&0': 'x'},
            '17.09.2026': {'b&1&0': 'Rybí filé', 'b&-1&0': 'x'},
          },
        });
        final state = AppState(configData: {
          'use_strava': true,
          'user_free_days': ['2026-09-16'],
        })
          ..demoMode = false
          ..isLunchOrderOpenOverride = (_, [_]) => true;

        state.applyFoodFilter('');
        expect(state.orders.containsKey('16.09.2026'), isFalse);
        expect(state.orders['17.09.2026'], 'b&1&0');

        state.orders.clear();
        state.pendingOrders.clear();
        state.recommendLunchesFn = (
          foodData,
          pref,
          apiKey, {
          model = 'gemini-3.8-flash',
          language = 'cs',
        }) async =>
            ('', {'16.09.2026': 'a&1&0', '17.09.2026': 'b&1&0'});
        Future<void>? job;
        state.spawn = (fn, name) {
          job = fn();
        };
        expect(state.startAiRecommend(), isTrue);
        await job;
        expect(state.orders.containsKey('16.09.2026'), isFalse);
        expect(state.orders['17.09.2026'], 'b&1&0');

        // With automatic lunch cancelling turned off, filter and AI stage
        // meals on free days again (R5 S3).
        state.config.set('strava_auto_cancel_lunches', false);
        state.orders.clear();
        state.pendingOrders.clear();
        state.applyFoodFilter('');
        expect(state.orders['16.09.2026'], 'a&1&0');
        expect(state.orders['17.09.2026'], 'b&1&0');

        state.orders.clear();
        state.pendingOrders.clear();
        expect(state.startAiRecommend(), isTrue);
        await job;
        expect(state.orders['16.09.2026'], 'a&1&0');
        expect(state.orders['17.09.2026'], 'b&1&0');
      });
    });

    test('refreshAutoCancelsFreeDaysRespectsKeptLunchAndFiresNotification',
        () async {
      await withClock(Clock.fixed(DateTime(2099, 10, 1, 9, 0)), () async {
        final savedLang = Strings.lang;
        Strings.lang = 'en';
        addTearDown(() => Strings.lang = savedLang);

        final notifications = <(String, String)>[];
        notifierBackend =
            _CallbackNotifier((tag, body) => notifications.add((tag, body)));

        final cfg = <String, Object?>{
          'use_strava': true,
          'strava_username': 'student',
          'strava_canteen_id': '1234',
          'strava_order_mode': 'confirm',
          'strava_auto_cancel_lunches': true,
          'user_free_days': ['2099-10-06', '2099-10-07'],
          'notifications': {'lunch_skipped': true, 'refresh_done': false},
        };
        saveDataCache({
          'absence': {'M': 1.0},
          'strava_meals': {
            '06.10.2099': {'a&1&0': 'Guláš', 'a&-1&0': 'x'},
            '07.10.2099': {'b&1&0': 'Řízek', 'b&-1&0': 'x'},
          },
          'strava_ordered': {
            '06.10.2099': 'a&1&0',
            '07.10.2099': 'b&1&0',
          },
        });
        final state = AppState(configData: cfg);
        // Keep 07.10.2099 locally as a newly picked meal in pendingOrders;
        // 06.10.2099 has a planner-staged cancel that auto-cancel completes and clears.
        state.stageLunchCancel({
          'start_date': '2099-10-06',
          'end_date': '2099-10-06',
        });
        expect(state.cancelledLunches, contains('06.10.2099'));
        expect(state.pendingOrders, contains('06.10.2099'));
        state.orders['07.10.2099'] = 'b&2&0';
        state.pendingOrders.add('07.10.2099');

        Future<void>? job;
        state.spawn = (fn, name) {
          job = fn();
        };
        state.createApp = ({onLog, configData}) => _F3RefreshApp(
              cfg,
              food: {
                '06.10.2099': {'a&1&0': 'Guláš', 'a&-1&0': 'x'},
                '07.10.2099': {'b&1&0': 'Řízek', 'b&2&0': 'Sýr', 'b&-1&0': 'x'},
              },
              ordered: {
                '06.10.2099': 'a&1&0',
                '07.10.2099': 'b&1&0',
              },
            );

        expect(state.startRefresh('strava'), isTrue);
        await job;

        expect(state.pendingOrders.contains('06.10.2099'), isFalse);
        expect(state.pendingOrders.contains('07.10.2099'), isTrue);
        expect('${state.runs.last['detail']}',
            contains(Strings.format('auto_lunch_cancelled', {'n': 1})));
        final skipNotif =
            notifications.where((n) => n.$1 == 'lunch_skipped').toList();
        expect(skipNotif, hasLength(1));
        expect(skipNotif.single.$2, contains('6. 10. 2099'));
        expect(skipNotif.single.$2,
            contains(Strings.get('lunch_cancel_reason_free_day')));
      });
    });

    test('refreshAutoCancelMultipleDaysFormatsPluralNotification', () async {
      await withClock(Clock.fixed(DateTime(2099, 10, 1, 9, 0)), () async {
        final savedLang = Strings.lang;
        Strings.lang = 'cs';
        addTearDown(() => Strings.lang = savedLang);

        final notifications = <(String, String)>[];
        notifierBackend =
            _CallbackNotifier((tag, body) => notifications.add((tag, body)));

        final cfg = <String, Object?>{
          'use_strava': true,
          'strava_username': 'student',
          'strava_canteen_id': '1234',
          'strava_order_mode': 'confirm',
          'strava_auto_cancel_lunches': true,
          'user_free_days': ['2099-10-06', '2099-10-07'],
          'notifications': {'lunch_skipped': true},
        };
        final state = AppState(configData: cfg);
        Future<void>? job;
        state.spawn = (fn, name) {
          job = fn();
        };
        state.createApp = ({onLog, configData}) => _F3RefreshApp(
              cfg,
              food: {
                '06.10.2099': {'a&1&0': 'Guláš', 'a&-1&0': 'x'},
                '07.10.2099': {'b&1&0': 'Řízek', 'b&-1&0': 'x'},
              },
              ordered: {
                '06.10.2099': 'a&1&0',
                '07.10.2099': 'b&1&0',
              },
            );

        expect(state.startRefresh('strava'), isTrue);
        await job;

        final skipNotif =
            notifications.where((n) => n.$1 == 'lunch_skipped').toList();
        expect(skipNotif, hasLength(1));
        expect(skipNotif.single.$2, contains('6. 10. 2099'));
        expect(skipNotif.single.$2, contains('7. 10. 2099'));
        expect(skipNotif.single.$2, contains('2'));
      });
    });
  });
}

class _F3RefreshApp extends Strakalari {
  final Map<String, Map<String, String>> foodDictData;
  final Map<String, String> _ordered;

  _F3RefreshApp(
    Map<String, Object?> cfg, {
    required Map<String, Map<String, String>> food,
    required Map<String, String> ordered,
  })  : foodDictData = food,
        _ordered = Map<String, String>.of(ordered),
        super(configData: cfg);

  @override
  Map<String, Map<String, String>> get foodDict => foodDictData;

  @override
  Map<String, String> get orderedDict => _ordered;

  @override
  Future<void> fetchStravaData() async {}

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    nextCancelReasons = const {};
    lastOrderedDays = Set<String>.of(orders.keys);
    _ordered.addAll(orders);
    return true;
  }

  @override
  void close() {}
}

class _CallbackNotifier implements NotifierBackend {
  final void Function(String tag, String body) onNotify;
  _CallbackNotifier(this.onNotify);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) {
    onNotify(tag, body);
    return true;
  }
}
