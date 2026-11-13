// The headless wake-up's gates (C-B3): `run_in_background` off, setup not
// finished, no login, not due yet (reboot / app update), a due run and a
// failed run. Python reference: `_register_jobs`, `_phone_background_on`,
// `_schedule_phone_wake`, `_setup_phone_background` (flet_ui/app.py).
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/platform/android/background.dart';
import 'package:app/platform/scheduler_jobs.dart';
import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<MethodCall> calls;
  final now = DateTime(2026, 11, 12, 10, 0, 0);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_bg_');
    setEnvironmentOverride(
        {'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
      calls.add(call);
      if (call.method == 'keepAwake') return 7;
      return call.method == 'scheduleWake' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, null);
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  /// The epoch the last `scheduleWake` asked for, as local time.
  DateTime? armed() {
    final wakes = calls.where((c) => c.method == 'scheduleWake').toList();
    if (wakes.isEmpty) return null;
    final s = (wakes.last.arguments as Map)['epochSeconds'] as double;
    return DateTime.fromMillisecondsSinceEpoch((s * 1000).round());
  }

  /// A finished setup with a login; [spawned] counts refresh starts and
  /// [ok] is the run the refresh records.
  AppState ready(List<String> spawned, {bool ok = true, Map<String, Object?>? config,
      Map<String, Object?>? data}) {
    final state = AppState(configData: config, data: data ?? {})
      ..wizardDismissed = true
      ..demoMode = false;
    state.spawn = (job, name) {
      spawned.add(name);
      if (name == 'strakalari-refresh') {
        state.runs.add({'ok': ok, 'detail': ok ? 'done' : 'boom'});
        state.refreshRunning = false;
      } else {
        state.updateCheckRunning = false;
      }
    };
    return state;
  }

  test('backgroundOffCancelsTheWakeAndNeverRuns', () async {
    final spawned = <String>[];
    final state = ready(spawned, config: {'run_in_background': false});
    final out = await withClock(Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'off');
    expect(calls.map((c) => c.method), ['cancelWake']);
    expect(spawned, isEmpty);
    expect(state.runs, isEmpty);
  });

  test('setupNotFinishedSkipsTheRefreshButKeepsTheSchedule', () async {
    final state = AppState(data: {}); // fresh install: the wizard owns the app
    final spawned = <String>[];
    state.spawn = (job, name) {
      spawned.add(name);
      state.updateCheckRunning = false;
    };
    expect(state.setupPending, isTrue);
    final out = await withClock(Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'ran');
    expect(spawned.where((n) => n == 'strakalari-refresh'), isEmpty);
    expect(armed(), now.add(const Duration(minutes: 60, seconds: 10)));
  });

  test('noLoginSkipsTheRefresh', () async {
    final state = AppState(data: {})
      ..wizardDismissed = true; // demo mode, no credentials
    final spawned = <String>[];
    state.spawn = (job, name) => spawned.add(name);
    final job = await withClock(Clock.fixed(now), () => state.scheduledRefreshJob());
    expect(job, 'skipped (no credentials configured)');
    expect(spawned, isEmpty);
  });

  test('notDueAfterARebootOnlyArmsTheDueTime', () async {
    final spawned = <String>[];
    // Refreshed successfully 10 minutes ago.
    final state = ready(spawned, data: {'last_updated': '12.11.2026 09:50:00'});
    final out = await withClock(Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'not due');
    expect(spawned, isEmpty);
    expect(armed(), DateTime(2026, 11, 12, 10, 50, 10));
    expect(calls.where((c) => c.method == 'updateBackgroundNotification'), isEmpty);
  });

  test('dueRunRefreshesOnceAndArmsTheNextInterval', () async {
    final spawned = <String>[];
    final state = ready(spawned,
        config: {'check_interval_minutes': 30},
        data: {'last_updated': '12.11.2026 09:00:00'});
    final out = await withClock(Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'ran');
    expect(spawned, ['strakalari-refresh', 'strakalari-update-check']);
    expect(armed(), now.add(const Duration(minutes: 30, seconds: 10)));
    // `KeepAwake(minutes=30)` held around the refresh, released after.
    final awake = calls.where((c) => c.method.endsWith('Awake')).toList();
    expect(awake.map((c) => c.method), ['keepAwake', 'releaseAwake']);
    expect((awake.first.arguments as Map)['minutes'], 30.0);
    expect((awake.last.arguments as Map)['id'], 7);
    expect(calls.where((c) => c.method == 'updateBackgroundNotification'), hasLength(1));
  });

  test('failedRunComesBackInFiveMinutes', () async {
    final spawned = <String>[];
    final state = ready(spawned, ok: false);
    final out = await withClock(Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'ran');
    expect(armed(), now.add(const Duration(minutes: 5, seconds: 10)));
  });

  test('fallbackWakeIsArmedBeforeTheJobStarts', () async {
    final spawned = <String>[];
    List<String>? methodsAtRefresh;
    final state = ready(spawned,
        config: {'check_interval_minutes': 30},
        data: {'last_updated': '12.11.2026 09:00:00'});
    final prevSpawn = state.spawn;
    state.spawn = (job, name) {
      if (name == 'strakalari-refresh') {
        methodsAtRefresh = [for (final c in calls) c.method];
      }
      prevSpawn(job, name);
    };
    final out = await withClock(
        Clock.fixed(now), () => runHeadlessTick(state, const AndroidChannel()));
    expect(out, 'ran');
    expect(methodsAtRefresh, isNotNull);
    expect(methodsAtRefresh, contains('scheduleWake'));
    expect(methodsAtRefresh!.indexOf('scheduleWake'),
        lessThan(methodsAtRefresh!.indexOf('keepAwake')));
    expect(calls.where((c) => c.method == 'scheduleWake'), hasLength(2));
    expect(armed(), now.add(const Duration(minutes: 30, seconds: 10)));
  });

  test('switchAndIntervalFollowPythonTruthiness', () {
    expect(backgroundSwitchOn(true), isTrue);
    expect(backgroundSwitchOn(false), isFalse);
    expect(backgroundSwitchOn(null), isFalse);
    expect(backgroundSwitchOn(0), isFalse);
    expect(backgroundSwitchOn(''), isFalse);
    expect(backgroundSwitchOn('no'), isTrue); // bool("no") is True
    expect(checkIntervalMinutes(30), 30.0);
    expect(checkIntervalMinutes('45'), 45.0);
    expect(checkIntervalMinutes(0), 60.0);
    expect(checkIntervalMinutes(null), 60.0);
    expect(checkIntervalMinutes(''), 60.0);
    expect(checkIntervalMinutes(false), 60.0);
    expect(checkIntervalMinutes(0.5), 0.5); // core clamps to 1 later
  });

  test('theHeadlessRunActuallyRunsItsJobs', () async {
    // Found on the phone: a bare AppState only records a spawned job, so
    // the headless refresh never ran and the job waited 30 minutes.
    var ran = false;
    AppState.liveSpawn(() async => ran = true, 'strakalari-refresh');
    await Future<void>.delayed(Duration.zero);
    expect(ran, isTrue);
    final code = File('lib/platform/android/background.dart').readAsStringSync();
    expect(code, contains('AppState()..spawn = AppState.liveSpawn'));
  });
}
