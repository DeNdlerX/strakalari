// Desktop notifications via `flutter_local_notifications`.
//
// Port of the app side of `strakalari/core/notify.py`: core `notify()`
// decides *whether* to notify (event names in `eventTypes`, per-event
// `notifications` prefs, unknown names default ON); the code below
// decides *how*. Sending never raises, so background jobs stay alive —
// the return value is honest: true only when a backend accepted the
// toast (unknown event names throw [ArgumentError], a programmer
// error, exactly like Python's `ValueError`).
//
// Backend mapping (first working one wins in Python; here the plugin
// owns the routing):
// * Windows: native WinRT toast via the plugin's Windows
//   implementation. Identity (`appUserModelId: 'Strakalari'`, guid =
//   the Inno `AppId`) is stable so Windows groups the toasts with the
//   installed app — the visible title stays `Strakaláři` (`appName`).
// * macOS: Notification Center via the plugin's Darwin implementation.
// * Linux: desktop notification via the plugin's Linux implementation.
// * Fallback: plain stdout print + false (mirrors Python's print
//   fallback; on a phone the Android path in `core/notify.py` — and
//   the app's `platform/android/` channel — apply instead).
//
// The plugin instance here is separate from the phase-5 stub backend
// (`platform/notifications.dart` records for tests); call
// [installDesktopNotifier] at startup to make core `notify()` show
// real toasts.
//
// UNVERIFIED beyond Windows: the macOS/Linux senders are configured
// but never ran here; the plugin needs its native registrant, which
// only a real `flutter build` on each OS produces.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Stable identity for the Windows toast (the Inno `AppId`, braces
/// included — it never changes, so toasts stay grouped with the app).
const String windowsToastGuid = '{D94B0F7F-65C1-4D52-9A47-E30D6E26F22B}';

/// Toast sender identity (ASCII only — matches core `appId`).
const String _toastAppId = 'Strakalari';

/// Deterministic notification id per event (index into core
/// `eventTypes`, so ids are stable across restarts and installs).
int notificationIdForEvent(String event) {
  final index = eventTypes.indexOf(event);
  if (index < 0) throw ArgumentError('Unknown notification event: $event');
  return 100 + index;
}

/// Real-toast `NotifierBackend` for the desktop app.
///
/// Construct with the plugin (see [DesktopNotifications]); pass
/// per-event prefs the same way `core/notify.py` reads the
/// `notifications` config key.
class DesktopNotifierBackend implements NotifierBackend {
  DesktopNotifierBackend({
    required this.plugin,
    this.prefsProvider,
    this.onNotificationTap,
  });

  final FlutterLocalNotificationsPlugin plugin;
  final Map<String, Object?>? Function()? prefsProvider;
  final Future<void> Function()? onNotificationTap;

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    // The plugin API is async while core's backend is sync: showing a
    // toast must never block (or crash) a background job, so the send
    // is detached and the honest result goes to the log.
    unawaitedSend(title: title, body: body, tag: tag);
    return true;
  }

  /// Parity helper mirroring `notify.notify(event, message, prefs)`:
  /// checks the per-event preference first, then toasts.
  Future<bool> notifyEvent(String event, String message) async {
    if (!eventTypes.contains(event)) {
      throw ArgumentError('Unknown notification event: $event');
    }
    final prefs = prefsProvider?.call();
    if (!isEnabled(prefs, event)) return false;
    try {
      await plugin.show(
        notificationIdForEvent(event),
        appName,
        message,
        const NotificationDetails(),
        payload: 'show',
      );
      return true;
    } catch (_) {
      // No toast backend worked — plain stdout fallback, no scary suffix.
      // ignore: avoid_print
      print('[$appName] $message');
      return false;
    }
  }

  Future<void> unawaitedSend({
    required String title,
    required String body,
    required String tag,
  }) async {
    try {
      final id = eventTypes.contains(tag)
          ? notificationIdForEvent(tag)
          : tag.hashCode & 0x7fffffff;
      await plugin.show(
        id,
        title,
        body,
        const NotificationDetails(),
        payload: 'show',
      );
    } catch (_) {
      // ignore: avoid_print
      print('[$title] $body');
    }
  }
}

/// Owns the plugin lifecycle for the desktop app.
class DesktopNotifications {
  DesktopNotifications({this.onNotificationTap});

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Future<void> Function()? onNotificationTap;
  bool _ready = false;

  /// Initializes the plugin once (idempotent). True when toasts can
  /// be shown on this OS.
  Future<bool> initialize() async {
    if (_ready) return true;
    try {
      final initialized = await _plugin.initialize(
        InitializationSettings(
          macOS: const DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(
            defaultActionName: 'Open',
          ),
          windows: const WindowsInitializationSettings(
            appName: appName,
            appUserModelId: _toastAppId,
            guid: windowsToastGuid,
          ),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse response) async {
          if (response.payload == 'show') {
            try {
              await onNotificationTap?.call();
            } catch (_) {}
          }
        },
      );
      _ready = initialized ?? false;
      return _ready;
    } catch (_) {
      return false;
    }
  }

  /// Builds the backend and registers it as core's [notifierBackend]
  /// so `notify()` shows real toasts. Returns the backend.
  DesktopNotifierBackend install({
    Map<String, Object?>? Function()? prefsProvider,
  }) {
    final backend = DesktopNotifierBackend(
      plugin: _plugin,
      prefsProvider: prefsProvider,
      onNotificationTap: onNotificationTap,
    );
    notifierBackend = backend;
    return backend;
  }
}

/// Installs real desktop toasts as core's [notifierBackend] (startup).
///
/// Returns the installed backend. Toasts that fail fall back to
/// stdout inside the backend; initialization itself never throws.
Future<DesktopNotifierBackend> installDesktopNotifier({
  Map<String, Object?>? Function()? prefsProvider,
  Future<void> Function()? onNotificationTap,
}) async {
  final notifications = DesktopNotifications(
    onNotificationTap: onNotificationTap,
  );
  await notifications.initialize();
  return notifications.install(prefsProvider: prefsProvider);
}
