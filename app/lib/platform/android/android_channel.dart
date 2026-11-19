// MethodChannel client for the Android platform side (`strakalari/android`).
//
// One method per function in `strakalari/core/android.py` (same names, same
// argument names), so the Dart port maps one-to-one. Off Android every call
// reports failure, exactly like the Python no-ops; nothing throws for a
// missing backend (a refresh must never die on a notification).
//
// Owned by the Android platform port (phase 8). The app registers the
// backends built on this channel at startup (see android_keystore.dart and
// android_notifications.dart); the headless entry point lives in
// background.dart.
import 'dart:async';

import 'package:flutter/services.dart';

/// The channel the Java side serves (`StrakalariChannel`).
const String androidChannelName = 'strakalari/android';

/// Python's `print(f"Warning: {what} ({type(exc).__name__}: {exc})")`
/// (or without the type name where android.py leaves it out).
void _warn(String what, PlatformException e, {required bool typed}) {
  final detail = e.message ?? e.code;
  // ignore: avoid_print
  print('Warning: $what (${typed ? 'PlatformException: ' : ''}$detail)');
}

/// Typed client for the `strakalari/android` MethodChannel.
class AndroidChannel {
  /// The UI isolate's channel (the background isolate builds its own).
  static const MethodChannel channel = MethodChannel(androidChannelName);

  final MethodChannel _channel;

  /// Wraps [_channel]; defaults to the shared UI-isolate channel.
  const AndroidChannel([this._channel = channel]);

  /// True inside the Android app once the Java side answers.
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<int> sdkInt() async {
    try {
      return await _channel.invokeMethod<int>('sdkInt') ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  /// Shows a notification (a tap opens the app on [route]). True when posted.
  Future<bool> notify({
    required String title,
    required String text,
    required String channelName,
    String route = 'today',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('notify', {
            'title': title,
            'text': text,
            'channelName': channelName,
            'route': route,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('notification failed', e, typed: true);
      return false;
    }
  }

  /// Reads and clears any pending route from a cold-start notification or
  /// widget tap (null when launched normally).
  Future<String?> takeLaunchRoute() async {
    try {
      final raw = await _channel.invokeMethod<String>('takeLaunchRoute');
      if (raw == null) return null;
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Listens for warm notification or widget taps delivered via `onNewIntent`.
  void setLaunchRouteHandler(void Function(String route)? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openRoute') {
        final raw = call.arguments;
        if (raw is String && raw.trim().isNotEmpty) {
          handler(raw.trim());
        }
      }
    });
  }

  Future<bool> notificationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('notificationsEnabled') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Shows Android 13+'s "allow notifications?" prompt when it applies.
  Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on MissingPluginException {
      // No backend: nothing to ask through.
    } on PlatformException catch (e) {
      _warn('could not ask for the notification permission', e, typed: false);
      // Must never break a job.
    }
  }

  /// Opens the system's notification settings for this app.
  Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
      // Ignore.
    } on PlatformException catch (e) {
      _warn('could not open the notification settings', e, typed: false);
      // Ignore.
    }
  }

  /// Starts (or updates) the background service. [texts]: the ongoing
  /// notification's `title`/`text`/`sub`/`rows`/`channel` and the reboot
  /// reminder's `boot_title`/`boot_text`/`events_channel`.
  Future<bool> startBackground(Map<String, String> texts) async {
    try {
      return await _channel.invokeMethod<bool>(
              'startBackground', {'texts': texts}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not start the background service', e, typed: true);
      return false;
    }
  }

  Future<void> stopBackground() async {
    try {
      await _channel.invokeMethod<void>('stopBackground');
    } on MissingPluginException {
      // Ignore.
    } on PlatformException catch (e) {
      _warn('could not stop the background service', e, typed: false);
      // Ignore.
    }
  }

  /// Replaces what the background service's notification says. [rows]: the
  /// overview's rows as JSON (`StatusContent.rowsJson`), drawn by the app's
  /// own layout; without them the plain [title] and [text] show.
  Future<bool> updateBackgroundNotification({
    required String title,
    required String text,
    String sub = '',
    String rows = '',
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
              'updateBackgroundNotification', {
            'title': title,
            'text': text,
            'sub': sub,
            'rows': rows,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not update the background notification', e, typed: true);
      return false;
    }
  }

  /// Wakes the CPU at about [epochSeconds] (also in Doze; replaces the
  /// previous alarm).
  Future<bool> scheduleWake(DateTime at) async {
    try {
      return await _channel.invokeMethod<bool>('scheduleWake', {
            'epochSeconds': at.millisecondsSinceEpoch / 1000.0,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not schedule the next wake-up', e, typed: true);
      return false;
    }
  }

  Future<void> cancelWake() async {
    try {
      await _channel.invokeMethod<void>('cancelWake');
    } on MissingPluginException {
      // Ignore.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Hands the upcoming wake-up alarms to `AlarmReceiver` (`[]` cancels
  /// them). [queueJson]: a JSON list of `at`/`lesson` (epoch ms), `title`,
  /// `text`.
  Future<bool> setWakeupAlarms({
    required String queueJson,
    required String channelName,
    required String dismissLabel,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('setWakeupAlarms', {
            'queueJson': queueJson,
            'channelName': channelName,
            'dismissLabel': dismissLabel,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not hand over the wake-up alarms', e, typed: true);
      return false;
    }
  }

  /// False when Android 12+ withholds exact alarms ("Alarms & reminders"
  /// off): the wake-up alarm then rings a few minutes late at worst.
  Future<bool> exactAlarmsAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('exactAlarmsAllowed') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system's "Alarms & reminders" switch (Android 12+).
  Future<void> openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod<void>('openExactAlarmSettings');
    } on MissingPluginException {
      // Ignore.
    } on PlatformException catch (e) {
      _warn('could not open the alarm settings', e, typed: false);
      // Ignore.
    }
  }

  /// Opens the phone's Clock app on a new alarm at [hour]:[minute]
  /// ([weekday]: Monday = 0, for a weekly alarm further ahead). True when
  /// an app was opened.
  Future<bool> openSystemAlarm(
    int hour,
    int minute, {
    String message = 'Strakaláři',
    int? weekday,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('openSystemAlarm', {
            'hour': hour,
            'minute': minute,
            'message': message,
            'weekday': weekday,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not open the Clock app', e, typed: true);
      return false;
    }
  }

  /// Saves the widget data and redraws the timetable widget.
  Future<bool> updateTimetableWidget(String payloadJson) async {
    try {
      return await _channel.invokeMethod<bool>(
              'updateTimetableWidget', {'payloadJson': payloadJson}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _warn('could not update the timetable widget', e, typed: true);
      return false;
    }
  }

  /// Persists the UI isolate's background-callback handle for headless runs.
  Future<void> registerBackgroundCallback(int handle) async {
    try {
      await _channel.invokeMethod<void>(
          'registerBackgroundCallback', {'handle': handle});
    } on MissingPluginException {
      // Ignore.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Holds the CPU awake with a new partial wakelock `strakalari:refresh`
  /// for at most [minutes]. Port of `KeepAwake.__enter__`. Returns the
  /// lock's id for [releaseAwake], or null when none was taken.
  Future<int?> keepAwake(double minutes) async {
    try {
      final id =
          await _channel.invokeMethod<int>('keepAwake', {'minutes': minutes});
      return (id == null || id < 0) ? null : id;
    } on MissingPluginException {
      return null; // not on Android: a no-op, like Python
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('Warning: could not keep the CPU awake (${e.message ?? e.code})');
      return null;
    }
  }

  /// Releases one [keepAwake] lock. Port of `KeepAwake.__exit__`.
  Future<void> releaseAwake(int id) async {
    try {
      await _channel.invokeMethod<void>('releaseAwake', {'id': id});
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // Python ignores a failed release too.
    }
  }

  /// Reads and clears why the current headless run started
  /// (`"boot"`, `"alarm"` or empty).
  Future<String> takeHeadlessReason() async {
    try {
      return await _channel.invokeMethod<String>('takeHeadlessReason') ?? '';
    } on MissingPluginException {
      return '';
    } on PlatformException {
      return '';
    }
  }

  /// End-of-run signal: releases the wakelock and drops the headless engine.
  Future<void> backgroundDone() async {
    try {
      await _channel.invokeMethod<void>('backgroundDone');
    } on MissingPluginException {
      // Ignore: nothing holds us then.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Whether [error] means "no Android backend here" (safe to ignore).
  static bool isNoBackend(Object error) =>
      error is MissingPluginException || error is PlatformException;
}
