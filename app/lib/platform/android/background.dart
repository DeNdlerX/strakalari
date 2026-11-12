// Headless background entry point (Android): one `runRefresh`, then exit.
//
// Started without the screen by `RefreshReceiver` (alarm time, reboot, app
// update) in a headless `FlutterEngine`. Two rules keep it safe:
//
// 1. **Never two refreshes at once in one process.** A file lock cannot
//    separate two isolates of the *same* process (PLAN.md §3.4 pitfall:
//    POSIX locks are per process). So when the UI isolate is alive — it
//    registers its port under [uiIsolatePortName] at startup, see
//    [registerUiRefreshPort] — the job is handed to it and this isolate
//    exits. Only when no UI isolate answers does this isolate run the
//    refresh itself (then it is alone in the process and the session lock
//    excludes the desktop builds).
// 2. **Fail loudly, never silently.** Every failure is printed (logcat tag
//    `strakalari` via stdout) and the wake is still re-armed, so one bad
//    run never stops the schedule. `backgroundDone` is always reported so
//    the native side releases the wakelock and drops the engine.
//
// What one wake does (mirrors the Python scheduler + phone wiring):
// `run_in_background` off → cancel the wake and stop. Otherwise hand the
// job to a live UI isolate, or: key warm-up → the UI's `AppState` →
// one due tick of core's `PeriodicRunner` (refresh job with its gates,
// the worker's notifications, session lock and run record) → status
// notification + widget + alarm queue → the next wake. Not due (reboot,
// app update) → only the wake for the due time.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import 'android_channel.dart';
import 'android_keystore.dart';
import 'android_notifications.dart';

/// Name the UI isolate's refresh port is registered under.
const String uiIsolatePortName = 'strakalari_ui_refresh';

/// How long the background isolate waits for the UI isolate's answer
/// before running the refresh itself.
const Duration uiHandoffTimeout = Duration(seconds: 30);

/// Registers the UI isolate's refresh port (call once at UI startup, and
/// listen for `{'op': 'refresh', 'reply': SendPort}` messages by running
/// the due refresh and replying `'done'`).
///
/// Also persists the background callback handle for headless runs after a
/// reboot. Returns the subscription so the app can cancel it.
Future<StreamSubscription<dynamic>> registerUiRefreshPort(
  ReceivePort port, {
  AndroidChannel channel = const AndroidChannel(),
  Future<void> Function()? onRefresh,
}) async {
  IsolateNameServer.removePortNameMapping(uiIsolatePortName);
  IsolateNameServer.registerPortWithName(port.sendPort, uiIsolatePortName);
  try {
    final handle =
        PluginUtilities.getCallbackHandle(androidBackgroundEntry)?.toRawHandle();
    if (handle != null) {
      await channel.registerBackgroundCallback(handle);
    }
  } on Object {
    // Best effort: without a stored handle a reboot cannot start headless
    // runs until the app is opened once (the old behavior).
  }
  return port.listen((dynamic message) async {
    // The actual refresh-on-message wiring lives with the UI startup (the
    // app's scheduler owns the jobs); this keeps the port anchor here.
    if (message is! Map || message['reply'] is! SendPort) return;
    final reply = message['reply'] as SendPort;
    if (onRefresh == null) {
      reply.send('deferred');
      return;
    }
    try {
      await onRefresh();
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: background refresh in the UI isolate failed ($e).');
    }
    reply.send('done');
  });
}

/// The headless entry (`RefreshReceiver` boots the engine with the stored
/// callback handle pointing here; keep the `@pragma`, it defeats
/// tree-shaking of a function nothing Dart-side calls).
@pragma('vm:entry-point')
Future<void> androidBackgroundEntry() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = AndroidChannel();
  try {
    await _runHeadless(channel);
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: headless refresh failed (${e.runtimeType}: $e)');
  } finally {
    await channel.backgroundDone();
  }
}

/// Fallback named entry point for engines started without a stored callback
/// handle (fresh install, never opened).
///
/// NOTE: `DartEntrypoint(bundlePath, "backgroundMain")` resolves in the
/// *root* library (`lib/main.dart`), so the UI startup must define it as a
/// one-line trampoline there: `backgroundMain() =>
/// androidBackgroundEntry();` (importing this file). Until then this
/// definition only documents the contract; the handle path above is what
/// runs in practice.
@pragma('vm:entry-point')
Future<void> backgroundMain() => androidBackgroundEntry();

Future<void> _runHeadless(AndroidChannel channel) async {
  final reason = await channel.takeHeadlessReason();
  final dataDir = await _phoneDataDir();
  // `run_in_background` off: Python stops the service and cancels the
  // wake (`_setup_phone_background` → `stop_background`). A reboot, an
  // app update or an old alarm must not start automation behind the
  // user's back, nor arm a new wake.
  Map<String, Object?> cfg;
  try {
    cfg = ConfigManager('$dataDir/config.json').data;
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: headless run could not read the config ($e); not running.');
    return;
  }
  if (!backgroundSwitchOn(cfg['run_in_background'] ?? true)) {
    await channel.cancelWake();
    // ignore: avoid_print
    print('Info: background running off; headless wake ($reason) ignored.');
    return;
  }
  if (await _handOffToUi(channel, reason)) return;
  await _runInline(channel, reason, dataDir);
}

/// The phone's data folder, set as `STRAKALARI_DATA_DIR` for core.
Future<String> _phoneDataDir() async {
  final support = await getApplicationSupportDirectory();
  final dataDir = '${support.path}/data';
  await Directory(dataDir).create(recursive: true);
  // PLAN.md rule 2: the phone keeps its data in
  // `getApplicationSupportDirectory()/data` (what Flet set as
  // `FLET_APP_STORAGE_DATA`). The override is merged over the real
  // environment so nothing else loses its variables.
  setEnvironmentOverride({
    ...Platform.environment,
    'STRAKALARI_DATA_DIR': dataDir,
  });
  return dataDir;
}

/// Python `bool(value)` for the `run_in_background` switch.
bool backgroundSwitchOn(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// Python `float(get("check_interval_minutes", 60) or 60)` (the runner's
/// interval; core clamps it to at least 1). A string Python's `float()`
/// would reject falls back to 60 instead of raising.
double checkIntervalMinutes(Object? raw) {
  if (raw == null || raw == false || raw == 0 || raw == '') return 60.0;
  if (raw == true) return 1.0;
  if (raw is num) return raw.toDouble();
  final parsed = double.tryParse('$raw'.trim());
  return (parsed == null || parsed == 0) ? 60.0 : parsed;
}

/// Hands the job to the live UI isolate. True when it took the job.
Future<bool> _handOffToUi(AndroidChannel channel, String reason) async {
  final ui = IsolateNameServer.lookupPortByName(uiIsolatePortName);
  if (ui == null) return false;
  final reply = ReceivePort();
  try {
    ui.send({'op': 'refresh', 'reason': reason, 'reply': reply.sendPort});
    final answer = await reply.first.timeout(uiHandoffTimeout);
    return answer == 'done';
  } on TimeoutException {
    // The UI isolate is alive but did not answer: do NOT run inline (two
    // refreshes at once in one process). The next armed wake retries.
    // ignore: avoid_print
    print('Warning: UI isolate did not take the background refresh; '
        'leaving it to the next wake.');
    return true;
  } on Object {
    return false; // dead port: run inline below
  } finally {
    reply.close();
  }
}

/// Core's phone seams (notifications, widget + alarm queue) over
/// [channel]. Both the UI isolate and a headless run call this.
void installAndroidBridges(AndroidChannel channel, {String Function()? languageOf}) {
  notifierBackend = AndroidNotifications(channel, languageOf);
  wakeupPhoneBridge = _ChannelWakeupBridge(channel);
}

/// `WakeupPhoneBridge` over the background isolate's channel.
///
/// Core's bridge is synchronous while the channel is async, so the calls
/// are fire-and-forget and report "accepted" (like the toast backends core
/// falls back from). Each headless run is a fresh isolate, so core's
/// change-dedup in `syncAndroid` starts empty and every run pushes once.
class _ChannelWakeupBridge implements WakeupPhoneBridge {
  final AndroidChannel channel;

  const _ChannelWakeupBridge(this.channel);

  @override
  bool updateTimetableWidget(String widgetJson) {
    channel.updateTimetableWidget(widgetJson);
    return true;
  }

  @override
  bool setWakeupAlarms(String queueJson, String channelName, String dismiss) {
    channel.setWakeupAlarms(
        queueJson: queueJson, channelName: channelName, dismissLabel: dismiss);
    return true;
  }
}

Future<void> _runInline(AndroidChannel channel, String reason, String dataDir) async {
  // ignore: avoid_print
  print('Info: headless background run ($reason).');
  try {
    await warmAndroidKeystore(dataDir, channel: channel);
  } on KeyStoreMissing {
    // No Keystore (should not happen on Android): the plain file, like
    // Python without pyjnius.
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: Keystore warm-up failed (${e.runtimeType}: $e).');
  }
  installAndroidBridges(channel, languageOf: () => Strings.lang);
  // The same state the UI builds: its language (core + strings), the
  // refresh worker with its session lock, notifications and run record.
  final state = AppState();
  await runHeadlessTick(state, channel);
}

/// One scheduler tick without the screen: what Python's `_register_jobs`
/// runner and `_setup_phone_background` do when the wake fires.
///
/// The runner is core's [PeriodicRunner] with the UI's two jobs and its
/// result hook; its first run is anchored to the last successful refresh
/// (`_startup_seed`). Not due yet (a reboot, an app update): only the
/// wake for the due time is armed. Due: one run (the refresh job keeps
/// its gates: setup not finished, a refresh running, no login), then the
/// status notification, widget and alarms, and the next wake from the
/// runner's own timer (a failed run comes back in ~5 minutes).
/// Returns `'off'`, `'not due'` or `'ran'`.
@visibleForTesting
Future<String> runHeadlessTick(
  AppState state,
  AndroidChannel channel, {
  Job? refreshJob,
  Duration updateWait = const Duration(seconds: 60),
}) async {
  if (!backgroundSwitchOn(state.get('run_in_background', true))) {
    await channel.cancelWake();
    return 'off';
  }
  final interval = checkIntervalMinutes(state.get('check_interval_minutes', 60));
  DateTime? seed;
  try {
    seed = startupSeed(state.data);
  } on Object {
    seed = null;
  }
  final runner = PeriodicRunner(
    intervalMinutes: interval,
    lastRun: seed,
    onResult: (result) {
      // Scheduler heartbeat, then the failure report (`_on_result`).
      state.schedulerLastRun = clock.now();
      if (!result.ok && !result.reported) {
        state.scheduledJobFailed(result.name, result.error);
      }
    },
  );
  if (seed != null) state.schedulerLastRun = seed;
  runner.addJob('refresh', refreshJob ?? () => state.scheduledRefreshJob());
  runner.addJob(
      'update',
      () => state.startUpdateCheck()
          ? 'update check started'
          : 'update check busy');

  final now = clock.now();
  var outcome = 'not due';
  if (!now.isBefore(nextDue(runner.lastRun, runner.intervalMinutes, now))) {
    await runner.runAllOnce();
    outcome = 'ran';
    // The update check runs on its own; let it finish before the
    // engine goes away (bounded).
    final deadline = clock.now().add(updateWait);
    while (state.updateCheckRunning && clock.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _postStatus(state, channel, interval);
    // Also after a skipped or failed run: a new day redraws the widget.
    state.syncAndroidState();
  }
  await _scheduleWake(channel, runner);
  return outcome;
}

/// Posts the overview notification like the UI's `StatusNotifier`.
void _postStatus(AppState state, AndroidChannel channel, double interval) {
  try {
    final minutes = interval.toInt() < 1 ? 1 : interval.toInt();
    final notifier = StatusNotifier(
      state.backgroundStatusInputs,
      (_) => true,
      () => (
        Strings.get('bg_notif_title'),
        Strings.format('bg_notif_text', {'n': minutes}),
      ),
    );
    final content = notifier.current();
    if (content == null) return;
    unawaited(channel.updateBackgroundNotification(
      title: content.title,
      text: content.text,
      sub: content.sub,
      rows: content.rowsJson(),
    ));
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: status sync failed (${e.runtimeType}: $e)');
  }
}

/// `_schedule_phone_wake`: the alarm for the runner's next due run.
Future<void> _scheduleWake(AndroidChannel channel, PeriodicRunner runner) async {
  try {
    final due = nextDue(runner.lastRun, runner.intervalMinutes, clock.now());
    // A little after due: the runner must see it as due.
    if (await channel.scheduleWake(due.add(const Duration(seconds: 10)))) {
      // ignore: avoid_print
      print('Info: next background check at '
          '${due.hour.toString().padLeft(2, '0')}:'
          '${due.minute.toString().padLeft(2, '0')}.');
    }
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: could not schedule the next wake-up ($e)');
  }
}
