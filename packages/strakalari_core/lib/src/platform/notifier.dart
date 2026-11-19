// Customizable desktop notifications (tray-hidden friendly).
//
// Port of strakalari/core/notify.py. Pure Dart: event names, per-event
// preferences and dispatch. The OS backends (Windows WinRT toast, macOS
// osascript, Linux notify-send, plyer fallback, Android notifications) are
// implemented by the app in phase 7 and registered as [NotifierBackend];
// without one, [notify] falls back to printing, exactly like Python.
//
// Each event type can be toggled in settings under the ``notifications``
// config key, e.g. ``{"excuse_sent": true}``. Missing keys fall back to
// [defaults] (and unknown events default to ON).

/// Application name shown in notifications.
const String appName = 'Strakaláři';

/// WinRT toast identity. Must stay plain ASCII — the toast API does not
/// accept diacritics here (the visible title still uses [appName]).
const String appId = 'Strakalari';

/// All notification event types.
const List<String> eventTypes = [
  'excuse_sent',
  'excuse_needs_confirm',
  'refresh_done',
  'refresh_failed',
  'lunch_ordered',
  'lunch_skipped',
  'planner_suggestion',
  'automation_failed',
  'new_mark',
  'new_quarterly_mark',
  'new_absence',
  'timetable_change',
  'update_available',
];

/// Default preference per event (all ON except refresh_done and refresh_failed).
const Map<String, bool> defaults = {
  'excuse_sent': true,
  'excuse_needs_confirm': true,
  'refresh_done': false,
  'refresh_failed': false,
  'lunch_ordered': true,
  'lunch_skipped': true,
  'planner_suggestion': true,
  'automation_failed': true,
  'new_mark': true,
  'new_quarterly_mark': true,
  'new_absence': true,
  'timetable_change': true,
  'update_available': true,
};

bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// Whether [event] is enabled under [prefs], falling back to [defaults].
bool isEnabled(Map<String, Object?>? prefs, String event) {
  if (prefs == null || !prefs.containsKey(event)) {
    return defaults[event] ?? true;
  }
  return _truthy(prefs[event]);
}

/// One OS notification backend (implemented by the app per platform).
abstract interface class NotifierBackend {
  /// Shows the notification; true when a backend accepted it.
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  });
}

/// The backend the app registered at startup (null = none available).
NotifierBackend? notifierBackend;

/// Sends [message] for [event] when enabled. Returns sent-or-not.
///
/// Throws [ArgumentError] for unknown events (a programmer error, not a
/// runtime failure); the actual send never raises.
bool notify(String event, String message, [Map<String, Object?>? prefs]) {
  if (!eventTypes.contains(event)) {
    throw ArgumentError('Unknown notification event: $event');
  }
  if (!isEnabled(prefs, event)) return false;
  try {
    final backend = notifierBackend;
    if (backend != null &&
        backend.sendNotification(title: appName, body: message, tag: event)) {
      return true;
    }
  } catch (_) {
    // A notification must never crash background jobs; fall through
    // to the plain stdout fallback below.
  }
  // No toast backend worked — plain stdout fallback, no scary suffix.
  // ignore: avoid_print
  print('[$appName] $message');
  return false;
}
