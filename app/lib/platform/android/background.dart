// Headless background entry point (Android): one `runRefresh`, then exit.
//
// Started without the screen by `RefreshReceiver` (alarm time, reboot, app
// update) in a headless `FlutterEngine`. Two rules keep it safe:
//
// 1. **Never two refreshes at once in one process.** When the UI isolate
//    is alive — it registers its port under [uiIsolatePortName] at
//    startup, see [registerUiRefreshPort] — the job is handed to it and
//    this isolate exits once the UI acknowledged it. A UI that does not
//    acknowledge is gone (closed screen, live process): its mapping is
//    dropped and this isolate runs the job itself, under the session lock
//    (`flock`, per open file, so it also excludes another isolate).
// 2. **Fail loudly, never silently.** Every failure is printed (logcat tag
//    `strakalari` via stdout) and every path but "background running off"
//    ends with the next wake armed (here, or by the UI that took the
//    job), so one bad run never stops the schedule. `backgroundDone` is always reported so
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
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import '../scheduler_jobs.dart';
import 'android_channel.dart';
import 'android_keystore.dart';
import 'android_notifications.dart';

/// Name the UI isolate's refresh port is registered under.
const String uiIsolatePortName = 'strakalari_ui_refresh';

/// How long the background isolate waits for the UI isolate's
/// acknowledgement before it treats the UI as gone.
const Duration uiHandoffAck = Duration(seconds: 5);

/// Registers the UI isolate's refresh port (call once at UI startup).
///
/// A hand-off message is `{'op': 'refresh', 'reply': SendPort}`. The UI
/// answers `'taken'` at once and only then does [onHandOff] (its own
/// scheduler runs the due job), so a living UI never makes the headless
/// side wait and a dead one is noticed within [uiHandoffAck].
///
/// Also persists the background callback handle for headless runs after a
/// reboot. Returns the subscription so the app can cancel it.
Future<StreamSubscription<dynamic>> registerUiRefreshPort(
  ReceivePort port, {
  AndroidChannel channel = const AndroidChannel(),
  Future<void> Function()? onHandOff,
}) async {
  IsolateNameServer.removePortNameMapping(uiIsolatePortName);
  IsolateNameServer.registerPortWithName(port.sendPort, uiIsolatePortName);
  try {
    final handle =
        PluginUtilities.getCallbackHandle(androidBackgroundEntry)?.toRawHandle();
    if (handle != null) {
      await channel.registerBackgroundCallback(handle);
    }
  } on Object catch (e) {
    // Without a stored handle a reboot cannot start headless runs until
    // the app is opened once (the old behavior).
    // ignore: avoid_print
    print('Warning: could not store the background entry ($e).');
  }
  return port.listen((dynamic message) async {
    if (message is! Map || message['reply'] is! SendPort) return;
    (message['reply'] as SendPort).send('taken');
    if (onHandOff == null) return;
    try {
      await onHandOff();
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: background hand-off in the UI isolate failed ($e).');
    }
  });
}

/// The UI isolate is being torn down: a later wake must not hand off to
/// its dead port.
void unregisterUiRefreshPort() {
  IsolateNameServer.removePortNameMapping(uiIsolatePortName);
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
  // Run the F4 one-time move right after `_phoneDataDir()` and BEFORE the
  // `run_in_background` gate (§4.1), so an overnight Play Store update moves
  // safely before the user ever opens the app.
  final layout = await ensureMultiAccountLayout(
    dataDir,
    warmAndroidRootKey: (r) => warmAndroidRootKeyClean(r, channel: channel),
  );
  if (layout.isRegistryFailed) {
    // ignore: avoid_print
    print('Warning: headless run aborted (account registry failed: '
        '${layout.error}).');
    return;
  }
  applyF6ScheduleDefaultsOnce(dataDir, degraded: layout.isDegraded);
  // `run_in_background` off: read from `global.json` once accounts exist
  // (never from the root backup); read root `config.json` only in degraded mode (§4.1).
  Object? runInBgValue;
  try {
    runInBgValue = readHeadlessRunInBackground(dataDir, layout);
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: headless run could not read the config ($e); not running.');
    return;
  }
  if (!backgroundSwitchOn(runInBgValue ?? true)) {
    await channel.cancelWake();
    // ignore: avoid_print
    print('Info: background running off; headless wake ($reason) ignored.');
    return;
  }
  if (await handOffToUi(reason)) return;
  await _runInline(channel, reason, dataDir, layout);
}

/// Reads `run_in_background` for the headless gate: `global.json` once
/// accounts exist, root `config.json` only in degraded mode (§3.4, §4.1).
@visibleForTesting
Object? readHeadlessRunInBackground(
  String rootDir,
  MultiAccountLayoutResult layout,
) {
  if (layout.isReady) {
    final globalPath = resolvePath(globalConfigFile, rootDir);
    if (!File(globalPath).existsSync()) return true;
    final decoded =
        jsonDecode(File(globalPath).readAsStringSync(encoding: utf8));
    if (decoded is Map && decoded.containsKey('run_in_background')) {
      return decoded['run_in_background'];
    }
    return true;
  }
  final cfg = ConfigManager(resolvePath('config.json', rootDir)).data;
  return cfg['run_in_background'];
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

/// Hands the job to the live UI isolate. True when it took the job.
///
/// The engine destroys the UI isolate when the screen is closed while the
/// process (and the name mapping) lives on, and sending to a dead port
/// neither throws nor answers. So no acknowledgement within [ackTimeout]
/// means the UI is gone: the stale mapping is removed and this isolate
/// runs the job itself (the session lock is `flock`, which also separates
/// two isolates of one process).
@visibleForTesting
Future<bool> handOffToUi(String reason, {Duration ackTimeout = uiHandoffAck}) async {
  final ui = IsolateNameServer.lookupPortByName(uiIsolatePortName);
  if (ui == null) return false;
  final reply = ReceivePort();
  try {
    ui.send({'op': 'refresh', 'reason': reason, 'reply': reply.sendPort});
    final answer = await reply.first.timeout(ackTimeout);
    return answer == 'taken';
  } on TimeoutException {
    IsolateNameServer.removePortNameMapping(uiIsolatePortName);
    // ignore: avoid_print
    print('Info: the app screen is gone; running the background job here.');
    return false;
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: background hand-off failed ($e); running it here.');
    return false;
  } finally {
    reply.close();
  }
}

/// `with KeepAwake(minutes=30)` around the scheduled refresh: the phone's
/// screen may be off, so the CPU must stay up until the run is done.
Future<T> androidKeepAwake<T>(Future<T> Function() body,
    {AndroidChannel channel = const AndroidChannel(), double minutes = 30}) async {
  final id = await channel.keepAwake(minutes);
  try {
    return await body();
  } finally {
    if (id != null) await channel.releaseAwake(id);
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

Future<void> _runInline(
  AndroidChannel channel,
  String reason,
  String dataDir,
  MultiAccountLayoutResult layout,
) async {
  // ignore: avoid_print
  print('Info: headless background run ($reason).');
  if (layout.isReady && layout.registry != null) {
    await warmAndroidKeystoreAll(
      dataDir,
      layout.registry!.accounts.map((a) => a.id),
      channel: channel,
    );
  } else {
    try {
      await warmAndroidKeystore(dataDir, channel: channel);
    } on KeyStoreMissing {
      // No Keystore (should not happen on Android): the plain file, like
      // Python without pyjnius.
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: Keystore warm-up failed (${e.runtimeType}: $e).');
    }
  }
  installAndroidBridges(channel, languageOf: () => Strings.lang);
  // The same state the UI builds: its language (core + strings), the
  // refresh worker with its session lock, notifications and run record,
  // and the UI's job runner (a bare AppState only records intent).
  final state = AppState()..spawn = AppState.liveSpawn;
  if (layout.isDegraded) {
    state.rootDir = dataDir;
    state.migrationDegraded = true;
  }
  await runHeadlessTick(state, channel);
}

/// One scheduler tick without the screen: what Python's `_register_jobs`
/// runner and `_setup_phone_background` do when the wake fires.
///
/// The runner is the UI's ([registerJobs]: core's [PeriodicRunner], the
/// two jobs, the result hook); its first run is anchored to the last
/// successful refresh (`_startup_seed`). Not due yet (a reboot, an app update): only the
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
  await state.refreshNetworkKind(channel);
  final runner = registerJobs(state,
      keepAwake: <T>(body) => androidKeepAwake<T>(body, channel: channel));
  if (refreshJob != null) runner.addJob('refresh', refreshJob);

  final now = clock.now();
  var outcome = 'not due';
  try {
    if (!now.isBefore(runner.nextDueAt(now))) {
      // Fallback wake before the job starts: if the process is killed
      // mid-run, the schedule still comes back.
      await _scheduleWakeAt(channel, state.nextScheduledWakeAt(now, now),
          quiet: true);
      await runner.runAllOnce();
      outcome = 'ran';
      // The update check runs on its own; let it finish before the
      // engine goes away (bounded).
      final deadline = clock.now().add(updateWait);
      while (state.updateCheckRunning && clock.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await state.ensurePrimaryWarmed();
      _postStatus(
          state, channel, state.schoolHoursIntervalForCurrentNetwork().toDouble());
      // Also after a skipped or failed run: a new day redraws the widget.
      state.syncAndroidState();
    }
  } finally {
    await _scheduleWake(channel, runner);
  }
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
Future<void> _scheduleWake(AndroidChannel channel, PeriodicRunner runner) =>
    _scheduleWakeAt(channel, runner.nextDueAt(clock.now()));

Future<void> _scheduleWakeAt(AndroidChannel channel, DateTime due,
    {bool quiet = false}) async {
  try {
    // A little after due: the runner must see it as due.
    if (await channel.scheduleWake(due.add(const Duration(seconds: 10))) &&
        !quiet) {
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
