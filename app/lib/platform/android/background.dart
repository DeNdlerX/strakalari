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
// What one run does (mirrors the Python scheduler + phone wiring):
// key warm-up → session lock → one `runRefresh` → event notifications →
// status notification + widget + alarm queue sync → re-arm the next wake.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:strakalari_core/strakalari_core.dart';

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
  if (await _handOffToUi(channel, reason)) return;
  await _runInline(channel, reason);
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

Future<void> _runInline(AndroidChannel channel, String reason) async {
  // ignore: avoid_print
  print('Info: headless background run ($reason).');
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

  try {
    await warmAndroidKeystore(dataDir, channel: channel);
  } on KeyStoreMissing {
    // No Keystore (should not happen on Android): the plain file, like
    // Python without pyjnius.
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: Keystore warm-up failed (${e.runtimeType}: $e).');
  }
  installAndroidBridges(channel);

  final ran = await withSessionLockAsync((held) async {
    if (!held) {
      // Another process (a desktop build) holds the session: skip, keep
      // the schedule by re-arming below.
      // ignore: avoid_print
      print('Info: background refresh skipped (session locked elsewhere).');
      return false;
    }
    final app = Strakalari(configFile: '$dataDir/config.json');
    try {
      final result = await runRefresh(app, app.configData);
      for (final news in result.news) {
        try {
          final prefs = app.configData['notifications'];
          notify(news.$1, news.$2,
              prefs is Map ? prefs.cast<String, Object?>() : null);
        } on Object {
          // A notification must never break the run.
        }
      }
      final cfg = Map<String, Object?>.of(app.configData);
      await _syncPhone(cfg, channel, pendingExcuses: result.excusesFailed);
      return true;
    } finally {
      app.close();
    }
  });
  await _rearm(channel, ran);
}

/// Pushes the status notification (the widget data and the alarm queue go
/// through core's `syncAndroid`). Best effort each, like Python.
Future<void> _syncPhone(
  Map<String, Object?> cfg,
  AndroidChannel channel, {
  int pendingExcuses = 0,
}) async {
  final now = clock.now();
  final cache = loadDataCache();
  Map<String, Object?> mapOf(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : {};
  final timetable = mapOf(cache['timetable']);

  syncAndroid(
    timetable.isEmpty ? null : timetable,
    config: cfg,
    stableBaseline: _stableBaseline(),
    now: now,
  );

  try {
    final age = cacheAge(cache);
    final inputs = StatusInputs(
      timetable: timetable,
      food: mapOf(cache['strava_meals']),
      webOrders: mapOf(cache['strava_ordered']),
      config: cfg,
      stableBaseline: _stableBaseline(),
      pendingExcuses: pendingExcuses,
      lastUpdated: age == null ? null : now.subtract(age),
    );
    final lang = getLanguage() == 'en' ? 'en' : 'cs';
    final content =
        buildStatus(inputs, now: now, fallback: ('Strakaláři', ''), lang: lang);
    await channel.updateBackgroundNotification(
      title: content.title,
      text: content.text,
      sub: content.sub,
      rows: content.rowsJson(),
    );
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: status sync failed (${e.runtimeType}: $e)');
  }
}

/// The stable baseline in record-key form, or null when unavailable
/// (the widget and the alarms then use the cached weeks only).
Map<(int, int), Object?>? _stableBaseline() {
  try {
    final cache = loadDataCache();
    final raw = cache['stable_baseline'];
    if (raw is! Map) return null;
    return {
      for (final entry in raw.entries)
        (
          int.parse('${entry.key}'.split('|').first),
          int.parse('${entry.key}'.split('|').last)
        ): entry.value,
    };
  } on Object {
    return null;
  }
}

/// Arms the next wake (even when this run was skipped or failed, so one
/// bad run never stops the schedule). Mirrors the UI wiring: the next due
/// refresh plus a few seconds.
Future<void> _rearm(AndroidChannel channel, bool ran) async {
  try {
    final now = clock.now();
    Map<String, Object?> cfg;
    try {
      final support = await getApplicationSupportDirectory();
      cfg = ConfigManager('${support.path}/data/config.json').data;
    } on Object {
      cfg = <String, Object?>{};
    }
    final raw = cfg['check_interval_minutes'];
    final interval = raw is num ? raw.toDouble() : 60.0;
    // This run just covered `now` (skipped runs: the other holder did).
    final due = nextDue(now, interval, now).add(const Duration(seconds: 10));
    await channel.scheduleWake(due);
    // ignore: avoid_print
    print('Info: background run ${ran ? 'done' : 'skipped'}; '
        'next wake ${due.toIso8601String()}.');
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: could not re-arm the wake (${e.runtimeType}: $e)');
  }
}
