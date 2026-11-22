import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/platform/android/background.dart';
import 'package:app/platform/scheduler_jobs.dart';
import 'package:app/platform/startup.dart';

class _RecordingNotifier implements NotifierBackend {
  final List<(String tag, String body, String? route)> calls = [];

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) {
    calls.add((tag, body, route));
    return true;
  }
}

class _FakeChannel extends AndroidChannel {
  const _FakeChannel();
  @override
  Future<int?> keepAwake([double minutes = 30]) async => 1;
  @override
  Future<void> releaseAwake(int id) async {}
  @override
  Future<bool> scheduleWake(DateTime at) async => true;
  @override
  Future<void> cancelWake() async {}
  @override
  Future<bool> updateBackgroundNotification({
    required String title,
    required String text,
    String sub = '',
    String rows = '',
  }) async =>
      true;
}

class _ScriptedRefreshApp extends Strakalari {
  final Future<void> Function()? onFetchBak;
  final Future<bool> Function(Map<String, String> orders)? onOrder;
  Map<String, Object?> scriptedTimetable;
  Map<String, double> scriptedAbsence;
  Map<String, List<Map<String, Object?>>> scriptedGrades;
  Map<String, Map<String, String>> scriptedFood;
  Map<String, String> scriptedOrdered;
  bool scriptedLowBalance;
  List<String> scriptedUnfunded;

  _ScriptedRefreshApp({
    super.dataDir,
    super.rootDir,
    super.onLog,
    super.configData,
    this.onFetchBak,
    this.onOrder,
    Map<String, Object?>? timetable,
    Map<String, double>? absence,
    Map<String, List<Map<String, Object?>>>? grades,
    Map<String, Map<String, String>>? food,
    Map<String, String>? ordered,
    this.scriptedLowBalance = false,
    this.scriptedUnfunded = const [],
  })  : scriptedTimetable = timetable ??
            {
              '20.11.2026': [
                {'time': '1. (8:00 - 8:45)', 'subject': 'Matematika', 'absent': false}
              ]
            },
        scriptedAbsence = absence ?? {'Matematika': 5.0},
        scriptedGrades = grades ?? {},
        scriptedFood = food ?? {},
        scriptedOrdered = ordered ?? {};

  @override
  Map<String, Object?> get timetableData => scriptedTimetable;

  @override
  Map<String, double> get absencePercentages => scriptedAbsence;

  @override
  Map<String, List<Map<String, Object?>>> get grades => scriptedGrades;

  @override
  Map<String, Map<String, String>> get foodDict => scriptedFood;

  @override
  Map<String, String> get orderedDict => scriptedOrdered;

  @override
  Future<void> fetchBakalariData() async {
    if (onFetchBak != null) await onFetchBak!();
  }

  @override
  Future<int> syncWebExcusesToHistory({int? limit}) async {
    lastOutboxSyncOk = true;
    return 0;
  }

  @override
  Future<void> fetchStravaData() async {}

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    if (onOrder != null) return onOrder!(orders);
    if (scriptedLowBalance) {
      lastOrderedDays = <String>{};
      lastOrderLowBalance = true;
      lastUnfundedDays = List<String>.of(scriptedUnfunded);
      return false;
    }
    lastOrderedDays = orders.keys.toSet();
    for (final e in orders.entries) {
      if (e.value.contains('&-1&')) {
        scriptedOrdered.remove(e.key);
      } else {
        scriptedOrdered[e.key] = e.value;
      }
    }
    return true;
  }

  @override
  Future<int> excusePending() async => 0;
}

Future<(String rootDir, String acc2Id)> _setupTwoAccounts(Directory tmp) async {
  final root = tmp.path;
  final layout = await ensureMultiAccountLayout(root);
  expect(layout.isReady, isTrue);

  final c1 = ConfigManager.forAccount(root, 'default');
  c1.set('bakalari_url', 'https://school1.cz');
  c1.set('bakalari_username', 'anna');
  c1.set('bakalari_password', 'pw1');
  c1.set('your_signature', 'Anna');
  c1.set('use_strava', false);
  c1.set('language', 'cs');
  c1.save();
  AccountManager.renameAccount(root, 'default', 'Anna');

  final prov =
      AccountManager.createProvisionalAccount(root, initialWizardStep: -1);
  final acc2Id = prov.account.id;
  final c2 = ConfigManager.forAccount(root, acc2Id);
  c2.set('bakalari_url', 'https://school2.cz');
  c2.set('bakalari_username', 'klara');
  c2.set('bakalari_password', 'pw2');
  c2.set('your_signature', 'Klára');
  c2.set('use_strava', false);
  c2.set('wizard_step', -1);
  c2.save();
  AccountManager.finishAddingAccount(root, acc2Id, fallbackLabel: 'Klára');
  AccountManager.setActiveAccount(root, 'default');
  AccountManager.setPrimaryAccount(root, 'default');
  return (root, acc2Id);
}

void main() {
  late Directory tmp;
  late _RecordingNotifier rec;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('f4_appstate_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    clearKeyCache();
    clearDataDirCaches();
    resetAccountsModeForTesting();
    rec = _RecordingNotifier();
    notifierBackend = rec;
    Strings.lang = 'cs';
  });

  tearDown(() {
    setEnvironmentOverride(null);
    clearKeyCache();
    clearDataDirCaches();
    resetAccountsModeForTesting();
    notifierBackend = null;
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Lock file may linger briefly on Windows.
    }
  });

  test('Item 6: degradedModeShowsHintAndAbortsWhenMigratedElsewhere', () async {
    final legacy = ConfigManager(resolvePath('config.json', tmp.path));
    legacy.set('bakalari_url', 'https://s.cz');
    legacy.set('bakalari_username', 'u');
    legacy.set('bakalari_password', 'p');
    legacy.save();

    final state = AppState(
      layoutResult: const MultiAccountLayoutResult.degraded('lock busy'),
      rootDir: tmp.path,
    )..spawn = AppState.liveSpawn;

    expect(state.accountsEnabled, isFalse);
    expect(state.migrationDegraded, isTrue);
    expect(state.lastSnackMessage, Strings.get('account_migration_failed'));

    // Simulate another process finishing the move while this process is degraded.
    final other = await ensureMultiAccountLayout(tmp.path);
    expect(other.isReady, isTrue);

    var createAppCalled = false;
    state.createApp = ({onLog, configData}) {
      createAppCalled = true;
      return _ScriptedRefreshApp();
    };
    state.lastSnackMessage = '';
    expect(state.startRefresh('all'), isTrue);
    // Let liveSpawn complete.
    for (var i = 0; i < 40 && state.refreshRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(createAppCalled, isFalse);
    expect(state.lastSnackMessage, Strings.get('account_migrated_elsewhere'));
  });

  test('Item 9: twoAccountsNeverInsideRunRefreshSimultaneously', () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final state = AppState(rootDir: root)..spawn = AppState.liveSpawn;
    final stateHeadless = AppState(rootDir: root)..spawn = AppState.liveSpawn;

    var inFlight = 0;
    var maxInFlight = 0;
    final refreshedDirs = <String>[];

    Strakalari makeApp({
      void Function(String)? onLog,
      Map<String, Object?>? configData,
      String? dataDir,
      String? rootDir,
    }) {
      return _ScriptedRefreshApp(
        dataDir: dataDir,
        rootDir: rootDir,
        onLog: onLog,
        configData: configData,
        onFetchBak: () async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          refreshedDirs.add(dataDir ?? '');
          await Future<void>.delayed(const Duration(milliseconds: 60));
          inFlight--;
        },
      );
    }

    state.createAppForAccount = makeApp;
    stateHeadless.createAppForAccount = makeApp;

    // Fire UI scheduler, tray Refresh All, and headless wake simultaneously!
    await Future.wait<Object?>([
      state.scheduledRefreshJob().catchError((_) => ''),
      state.trayRefreshAll(),
      runHeadlessTick(stateHeadless, const _FakeChannel()),
    ]);

    expect(maxInFlight, 1);
    expect(refreshedDirs, contains(accountDirFor(root, 'default')));
    expect(refreshedDirs, contains(accountDirFor(root, acc2Id)));
  });

  test('Item 10: dueAccountsAutoFailureRetryAndPassBudget', () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final fixedNow = DateTime(2026, 11, 20, 10, 0, 0);

    await withClock(Clock.fixed(fixedNow), () async {
      final refreshed = <String>[];
      var failAcc2Auto = true;

      // Enable Strava + auto cancel/order on acc2 to test auto-phase failure after last_updated.
      // Pin a 60-min interval so the 5-min failure retry below refreshes only B.
      final c2 = ConfigManager.forAccount(root, acc2Id);
      c2.set('check_interval_minutes', 60);
      c2.set('use_strava', true);
      c2.set('strava_canteen_id', '1950');
      c2.set('strava_username', 'klara');
      c2.set('strava_order_mode', 'auto');
      c2.save();

      final state = AppState(rootDir: root)..spawn = AppState.liveSpawn;

      state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
        final isAcc2 = dataDir == accountDirFor(root, acc2Id);
        return _ScriptedRefreshApp(
          dataDir: dataDir,
          rootDir: rootDir,
          onLog: onLog,
          configData: configData,
          food: isAcc2
              ? {
                  '23.11.2026': {'m1': 'Svíčková'}
                }
              : {},
          onFetchBak: () async {
            refreshed.add(isAcc2 ? acc2Id : 'default');
          },
          onOrder: isAcc2
              ? (_) async {
                  if (failAcc2Auto) throw StateError('Strava exploded');
                  return true;
                }
              : null,
        );
      };

      // Pass 1: A succeeds, B saves last_updated then fails in auto_lunch -> JobFailed.
      await expectLater(
        state.scheduledRefreshJob(),
        throwsA(isA<JobFailed>()),
      );
      expect(refreshed, ['default', acc2Id]);
      // B has both last_updated AND scheduled_refresh_failed!
      final cacheA = loadDataCache(dataDir: accountDirFor(root, 'default'));
      final cacheB = loadDataCache(dataDir: accountDirFor(root, acc2Id));
      expect(cacheA[scheduledRefreshFailedKey], isNull);
      expect(cacheB['last_updated'], isNotNull);
      expect(cacheB[scheduledRefreshFailedKey], isNotNull);

      // 5 minutes later (still well within 60-min interval): retry refreshes ONLY B!
      refreshed.clear();
      failAcc2Auto = false;
      await withClock(Clock.fixed(fixedNow.add(const Duration(minutes: 5))),
          () async {
        final outcome = await state.scheduledRefreshJob();
        expect(outcome, 'refresh finished');
        expect(refreshed, [acc2Id]); // A was NOT re-refreshed!
        final cacheBAfter = loadDataCache(dataDir: accountDirFor(root, acc2Id));
        expect(cacheBAfter[scheduledRefreshFailedKey], isNull);
      });

      // Pass budget test: make both accounts due, advance clock past 20 min during A.
      saveDataCache({'last_updated': '19.11.2026 08:00:00'},
          dataDir: accountDirFor(root, 'default'));
      saveDataCache({'last_updated': '19.11.2026 08:00:00'},
          dataDir: accountDirFor(root, acc2Id));
      var nowVal = DateTime(2026, 11, 20, 12, 0, 0);
      refreshed.clear();
      await withClock(Clock(() => nowVal), () async {
        state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
          final isAcc2 = dataDir == accountDirFor(root, acc2Id);
          return _ScriptedRefreshApp(
            dataDir: dataDir,
            rootDir: rootDir,
            onLog: onLog,
            configData: configData,
            onFetchBak: () async {
              refreshed.add(isAcc2 ? acc2Id : 'default');
              // Simulate A taking 21 minutes -> exceeds 20-minute budget.
              nowVal = nowVal.add(const Duration(minutes: 21));
            },
          );
        };
        await expectLater(
          state.scheduledRefreshJob(),
          throwsA(
            isA<JobFailed>().having(
              (e) => e.message,
              'message',
              contains('accounts left for the next run'),
            ),
          ),
        );
        expect(refreshed, ['default']); // B left due for the 5-min retry!
      });
    });
  });

  test('Item 11: sharedResultHandlerNotifiesMarksCancelsLowBalanceAndIsolatesErrors',
      () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final acc2Dir = accountDirFor(root, acc2Id);
    final fixedNow = DateTime(2026, 11, 20, 9, 0, 0);

    // Pre-seed acc2 cache with old grades + ordered lunch on a planned skip day
    // so the background refresh produces both a new mark and an F3 auto-cancel!
    final c2 = ConfigManager.forAccount(root, acc2Id);
    c2.set('use_strava', true);
    c2.set('strava_canteen_id', '1950');
    c2.set('strava_username', 'klara');
    c2.set('strava_order_mode', 'confirm');
    c2.set('strava_auto_cancel_lunches', true);
    c2.set('planned_skips', [
      {
        'start_date': '2026-11-24',
        'end_date': '2026-11-24',
        'template': 'Lékař',
        'cancel_lunch': true,
      }
    ]);
    c2.save();
    saveDataCache({
      'last_updated': '19.11.2026 08:00:00',
      'grades': {
        'Matematika': [
          {'Grade': '2', 'Weight': 1, 'Date': '18.11.2026'}
        ]
      },
      'strava_ordered': {'24.11.2026': 'm1'},
    }, dataDir: acc2Dir);
    // Make default fresh so only acc2 runs.
    saveDataCache({'last_updated': '20.11.2026 08:50:00'},
        dataDir: accountDirFor(root, 'default'));

    await withClock(Clock.fixed(fixedNow), () async {
      final state = AppState(rootDir: root)..spawn = AppState.liveSpawn;
      expect(state.activeAccountId, 'default');

      state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
        return _ScriptedRefreshApp(
          dataDir: dataDir,
          rootDir: rootDir,
          onLog: onLog,
          configData: configData,
          grades: {
            'Matematika': [
              {'Grade': '2', 'Weight': 1, 'Date': '18.11.2026'},
              {'Grade': '1', 'Weight': 2, 'Date': '20.11.2026'},
            ]
          },
          food: {
            '24.11.2026': {
              'm1': 'Guláš',
              '24.11.2026&-1&0': 'Bez oběda',
            }
          },
          ordered: {'24.11.2026': 'm1'},
        );
      };

      final outcome = await state.scheduledRefreshJob();
      expect(outcome, 'refresh finished');

      // Background account Klára notified new_mark + lunch_skipped with [Klára] & ?account=!
      expect(
        rec.calls.any((c) =>
            c.$1 == 'new_mark' &&
            c.$2.startsWith('[Klára] ') &&
            c.$3 == 'marks?account=$acc2Id'),
        isTrue,
        reason: 'calls: ${rec.calls}',
      );
      expect(
        rec.calls.any((c) =>
            c.$1 == 'lunch_skipped' &&
            c.$2.startsWith('[Klára] ') &&
            c.$3 == 'lunches?account=$acc2Id'),
        isTrue,
        reason: 'calls: ${rec.calls}',
      );

      // Low balance on background account: warns once, does NOT fail job, does NOT retry.
      rec.calls.clear();
      c2.set('strava_order_mode', 'auto');
      c2.set('planned_skips', <Object?>[]);
      c2.save();
      saveDataCache({'last_updated': '19.11.2026 08:00:00'}, dataDir: acc2Dir);
      state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
        return _ScriptedRefreshApp(
          dataDir: dataDir,
          rootDir: rootDir,
          onLog: onLog,
          configData: configData,
          food: {
            '25.11.2026': {'m1': 'Řízek'}
          },
          ordered: {},
          scriptedLowBalance: true,
          scriptedUnfunded: const ['25.11.2026'],
        );
      };
      expect(await state.scheduledRefreshJob(), 'refresh finished');
      expect(
        rec.calls.any((c) =>
            c.$1 == 'lunch_skipped' &&
            c.$2.startsWith('[Klára] ') &&
            c.$3 == 'lunches?account=$acc2Id'),
        isTrue,
      );
      expect(
        loadDataCache(dataDir: acc2Dir)[scheduledRefreshFailedKey],
        isNull,
      );

      // Failure isolation: if default fails, acc2 STILL runs in the same pass!
      saveDataCache({'last_updated': '19.11.2026 08:00:00'},
          dataDir: accountDirFor(root, 'default'));
      saveDataCache({'last_updated': '19.11.2026 08:00:00'}, dataDir: acc2Dir);
      final ran = <String>[];
      state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
        final isDef = dataDir == accountDirFor(root, 'default');
        return _ScriptedRefreshApp(
          dataDir: dataDir,
          rootDir: rootDir,
          onLog: onLog,
          configData: configData,
          onFetchBak: () async {
            ran.add(isDef ? 'default' : acc2Id);
            if (isDef) throw const UserError('default server down');
          },
        );
      };
      await expectLater(
          state.scheduledRefreshJob(), throwsA(isA<JobFailed>()));
      expect(ran, ['default', acc2Id]);
    });
  });

  test('Item 13: switchEqualsFreshStateAiDropRoutingAndPrimaryStatusInputs',
      () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final defDir = accountDirFor(root, 'default');
    final acc2Dir = accountDirFor(root, acc2Id);

    // Seed distinct data in Anna (default, primary) and Klára (acc2).
    saveDataCache({
      'last_updated': '20.11.2026 08:00:00',
      'timetable': {
        '20.11.2026': [
          {'time': '1. (8:00 - 8:45)', 'subject': 'Matematika', 'absent': false}
        ]
      },
      'absence': {'Matematika': 10.0},
      'strava_meals': {
        '23.11.2026': {'m1': 'Svíčková'}
      },
      'strava_ordered': {'23.11.2026': 'm1'},
    }, dataDir: defDir);
    saveDataCache({
      'last_updated': '20.11.2026 09:00:00',
      'timetable': {
        '20.11.2026': [
          {'time': '1. (8:00 - 8:45)', 'subject': 'Fyzika', 'absent': false}
        ]
      },
      'absence': {'Fyzika': 2.0},
      'strava_meals': {
        '24.11.2026': {'m2': 'Kuře'}
      },
      'strava_ordered': {'24.11.2026': 'm2'},
    }, dataDir: acc2Dir);

    final state = AppState(rootDir: root)..spawn = AppState.liveSpawn;
    var onChangedHits = 0;
    state.onChanged = () => onChangedHits++;
    final warmed = <String>[];
    state.ensureWarmedFn = (d) async => warmed.add(d);

    // Pollute transient fields on Anna before switching to Klára.
    state.drafts['some_draft'] = 'hello';
    state.marksPredictions['Matematika'] = {'x': 1};
    state.lunchHidden = {'m1'};
    state.showPastCalendar = true;
    state.pendingOrders.add('23.11.2026');
    final savedSched = DateTime(2026, 11, 20, 8, 30);
    state.schedulerLastRun = savedSched;

    // Switch to Klára.
    expect(await state.switchAccount(acc2Id), isTrue);
    expect(warmed, contains(acc2Dir));

    // Build a fresh AppState for Klára and compare field-by-field!
    final fresh = AppState(rootDir: root);
    expect(state.activeAccountId, fresh.activeAccountId);
    expect(state.config.data, fresh.config.data);
    expect(state.data, fresh.data);
    expect(state.orders, fresh.orders);
    expect(state.webOrders, fresh.webOrders);
    expect(state.pendingOrders, fresh.pendingOrders);
    expect(state.drafts, fresh.drafts);
    expect(state.marksPredictions, fresh.marksPredictions);
    expect(state.lunchHidden, fresh.lunchHidden);
    expect(state.showPastCalendar, fresh.showPastCalendar);
    // Allow-list wiring survived!
    expect(state.schedulerLastRun, savedSched);
    expect(onChangedHits, greaterThan(0));

    // Tray pause label shows Klára when >1 account.
    expect(trayStrings(state).pause, contains('Klára'));

    // Primary status inputs while viewing non-primary Klára equal an AppState built for Anna!
    final statusForPrimary = state.backgroundStatusInputs();
    final annaApp = AppState(rootDir: root);
    await annaApp.switchAccount('default');
    final statusFromAnna = annaApp.backgroundStatusInputs();
    expect(statusForPrimary.timetable, statusFromAnna.timetable);
    expect(statusForPrimary.food, statusFromAnna.food);
    expect(statusForPrimary.webOrders, statusFromAnna.webOrders);
    expect(statusForPrimary.pendingExcuses, statusFromAnna.pendingExcuses);
    expect(statusForPrimary.lastUpdated, statusFromAnna.lastUpdated);
    expect(statusForPrimary.accountLabel, 'Anna');
    final builtStatus = buildStatus(
      statusForPrimary,
      fallback: const ('Strakaláři', 'Running'),
      now: DateTime(2026, 11, 20, 8, 5),
    );
    expect(builtStatus.sub, startsWith('Anna'));

    // Event tap for the active non-primary account (Klára) does NOT switch to Anna!
    state.pendingRoute = null;
    await state.applyLaunchRouteAsync('marks?account=$acc2Id');
    expect(state.activeAccountId, acc2Id);
    expect(state.pendingRoute, 'marks');

    // Tap for a deleted/unknown account stays on Klára and opens nothing.
    state.pendingRoute = null;
    await state.applyLaunchRouteAsync('marks?account=acc_deleted00000');
    expect(state.activeAccountId, acc2Id);
    expect(state.pendingRoute, isNull);

    // Status notification tap (no ?account=) switches to primary (Anna)!
    state.pendingRoute = null;
    await state.applyLaunchRouteAsync('today');
    expect(state.activeAccountId, 'default');
    expect(state.pendingRoute, 'today');

    // Busy tap: tap for Klára while Anna is refreshing -> shows account_tap_busy,
    // does NOT open marks on Anna, then switches to Klára once refresh ends!
    final refreshGate = Completer<void>();
    state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) =>
        _ScriptedRefreshApp(
          dataDir: dataDir,
          rootDir: rootDir,
          onFetchBak: () => refreshGate.future,
        );
    state.pendingRoute = null;
    expect(state.startRefresh('bakalari'), isTrue);
    await state.applyLaunchRouteAsync('marks?account=$acc2Id');
    expect(state.activeAccountId, 'default');
    expect(state.pendingRoute, isNull);
    expect(state.lastSnackMessage,
        Strings.format('account_tap_busy', {'name': 'Klára'}));
    refreshGate.complete();
    for (var i = 0; i < 40 && state.activeAccountId != acc2Id; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(state.activeAccountId, acc2Id);
    expect(state.pendingRoute, 'marks');

    // AI pick finishing after switch is dropped (no staging onto new account).
    final aiGate = Completer<(String, Map<String, String>)>();
    state.recommendLunchesFn = (menu, pref, key,
            {model = '', language = 'cs'}) =>
        aiGate.future;
    state.isLunchOrderOpenOverride = (_, [_]) => true;
    expect(state.startAiRecommend(), isTrue);
    // Force-switch to Anna while AI is in flight (simulating race / token check).
    expect(await state.switchAccount('default', force: true), isTrue);
    final pendingBefore = Set<String>.of(state.pendingOrders);
    aiGate.complete(('ok', {'24.11.2026': 'm2'}));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(state.pendingOrders, pendingBefore);
  });

  test('headlessGateReadsGlobalJsonNotRootBackup', () async {
    final legacy = ConfigManager(resolvePath('config.json', tmp.path));
    legacy.set('run_in_background', true);
    legacy.save();

    final layout = await ensureMultiAccountLayout(tmp.path);
    expect(layout.isReady, isTrue);

    // Turn run_in_background OFF in global.json (root config.json still has true!).
    final cfg = ConfigManager.forAccount(tmp.path, 'default');
    cfg.setAndSave('run_in_background', false);

    expect(readHeadlessRunInBackground(tmp.path, layout), isFalse);
  });

  test('schedulerStartupSeedAnchorsToOldestEnabledAccount', () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final defDir = accountDirFor(root, 'default');
    final acc2Dir = accountDirFor(root, acc2Id);

    saveDataCache({'last_updated': '20.11.2026 09:00:00'}, dataDir: defDir);
    saveDataCache({'last_updated': '20.11.2026 07:30:00'}, dataDir: acc2Dir);

    await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0, 0)), () async {
      final state = AppState(rootDir: root);
      expect(schedulerStartupSeed(state), DateTime(2026, 11, 20, 7, 30, 0));

      // Turning off background_refresh on acc2 ignores acc2's older stamp.
      await state.setAccountBackgroundRefresh(acc2Id, false);
      expect(schedulerStartupSeed(state), DateTime(2026, 11, 20, 9, 0, 0));
    });
  });

  test('cancelAddAccountRefusesNonAddingAccountWithClearedCredentials (R6 M2)',
      () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final acc2Dir = accountDirFor(root, acc2Id);

    final state = AppState(rootDir: root);
    expect(await state.switchAccount(acc2Id), isTrue);
    expect(state.activeAccountId, acc2Id);
    expect(state.addingAccount, isFalse);

    // Simulate an existing finished account whose credentials were cleared
    // (setupPending == true, but adding == false).
    state.save({
      'bakalari_username': '',
      'bakalari_password': '',
      'bakalari_password_encrypted': false,
    });
    expect(state.setupPending, isTrue);
    expect(state.addingAccount, isFalse);

    final regBytesBefore =
        File('$root${Platform.pathSeparator}$accountsFile').readAsBytesSync();
    final cfgBytesBefore =
        File('$acc2Dir${Platform.pathSeparator}config.json').readAsBytesSync();

    final printed = <String>[];
    final cancelled = await runZoned(
      () => state.cancelAddAccount(),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );

    expect(cancelled, isFalse);
    expect(printed, isEmpty);
    expect(state.activeAccountId, acc2Id);
    expect(Directory(acc2Dir).existsSync(), isTrue);
    expect(
      File('$acc2Dir${Platform.pathSeparator}config.json').readAsBytesSync(),
      cfgBytesBefore,
    );
    expect(
      File('$root${Platform.pathSeparator}$accountsFile').readAsBytesSync(),
      regBytesBefore,
    );
    final regAfter = AccountRegistry.load(root)!;
    expect(regAfter.accounts.map((a) => a.id).toList(), ['default', acc2Id]);
  });

  test('scheduledRefreshSkipsBackgroundRefreshDisabledAccount (R6 S1)',
      () async {
    final (root, acc2Id) = await _setupTwoAccounts(tmp);
    final defDir = accountDirFor(root, 'default');
    final acc2Dir = accountDirFor(root, acc2Id);

    // Seed both accounts as due (> 60 min old).
    saveDataCache({'last_updated': '20.11.2026 08:00:00'}, dataDir: defDir);
    saveDataCache({'last_updated': '20.11.2026 08:00:00'}, dataDir: acc2Dir);

    final state = AppState(rootDir: root)..spawn = AppState.liveSpawn;
    final refreshedDirs = <String>[];
    state.createAppForAccount = ({onLog, configData, dataDir, rootDir}) {
      return _ScriptedRefreshApp(
        dataDir: dataDir,
        rootDir: rootDir,
        onLog: onLog,
        configData: configData,
        onFetchBak: () async {
          refreshedDirs.add(dataDir ?? '');
        },
      );
    };

    // Disable background_refresh on the second account.
    await state.setAccountBackgroundRefresh(acc2Id, false);

    // Pass 1: both accounts are due, but only the first is refreshed.
    await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0, 0)), () async {
      await state.scheduledRefreshJob();
    });
    expect(refreshedDirs, [defDir]);

    // Tray Refresh All also respects background_refresh: false.
    refreshedDirs.clear();
    await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 5, 0)), () async {
      await state.trayRefreshAll();
    });
    expect(refreshedDirs, [defDir]);

    // Turn background_refresh back ON; once both are due again, both refresh.
    await state.setAccountBackgroundRefresh(acc2Id, true);
    refreshedDirs.clear();
    await withClock(Clock.fixed(DateTime(2026, 11, 20, 12, 0, 0)), () async {
      await state.scheduledRefreshJob();
    });
    expect(refreshedDirs, unorderedEquals([defDir, acc2Dir]));
  });
}
