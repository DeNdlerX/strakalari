// Android notification backend (event notifications, not the ongoing one).
//
// Posts through `AndroidChannel.notify` on the `strakalari_events` channel —
// the same path as Python's `_send_android` in `core/notify.py` (the channel
// name is "Automation"/"Automatizace" by language). The ongoing background
// notification stays with `KeepAliveService` (see `AndroidChannel`).
import 'package:strakalari_core/strakalari_core.dart';

import 'android_channel.dart';

/// Target app route for every notification event in core `eventTypes` (O8).
const Map<String, String> notificationEventRoutes = {
  'excuse_needs_confirm': 'today',
  'excuse_sent': 'activity',
  'refresh_done': 'today',
  'refresh_failed': 'activity',
  'lunch_ordered': 'lunches',
  'lunch_skipped': 'lunches',
  'planner_suggestion': 'absences/plan',
  'automation_failed': 'activity',
  'new_mark': 'marks',
  'new_quarterly_mark': 'marks',
  'new_absence': 'absences',
  'timetable_change': 'timetable',
  'update_available': 'activity',
};

/// Resolves the target route for notification event [tag] (defaults to `'today'`).
String routeForNotificationEvent(String tag) =>
    notificationEventRoutes[tag] ?? 'today';

/// Posts event notifications through the Android backend.
///
/// Register at startup (Android only):
/// `notifierBackend = const AndroidNotifications();`
class AndroidNotifications implements NotifierBackend {
  final AndroidChannel channel;
  final String Function()? languageOf;

  /// [languageOf] returns `'en'` for English, anything else for Czech.
  const AndroidNotifications(
      [this.channel = const AndroidChannel(), this.languageOf]);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) {
    // Core's `notify` calls synchronously; the channel answers async, so
    // the post is fire-and-forget and `true` means "accepted", like the
    // desktop toast backends (a failure only skips the stdout fallback).
    final english = languageOf?.call() == 'en';
    channel.notify(
      title: title,
      text: body,
      channelName: english ? 'Automation' : 'Automatizace',
      route: route ?? routeForNotificationEvent(tag),
    );
    return true;
  }
}
