import 'dart:convert';
import 'dart:io';

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
            state.lastSnackMessage = Str.t('ai_already_running');
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
}

class _CallbackNotifier implements NotifierBackend {
  final void Function(String tag, String body) onNotify;
  _CallbackNotifier(this.onNotify);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    onNotify(tag, body);
    return true;
  }
}
