// OS notification backend (Flutter side of core's Notifier interface).
//
// Port of the app-side notification wiring: core `notify()` (see
// `core/platform/notifier.dart`) decides *whether* to notify; the OS
// backends below decide *how*. Phase 7 plugs in the real senders
// (`flutter_local_notifications` on all platforms); until then this is
// a recording stub so the shell and controllers already compile and the
// phase-6 screens can fire notifications in tests.
import 'package:flutter/foundation.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// A sent notification (kept in memory for tests / the activity log).
@immutable
class SentNotification {
  final String title;
  final String body;
  final String tag;
  const SentNotification(this.title, this.body, this.tag);
}

/// Phase-5 stub backend: records instead of showing. Phase 7 replaces
/// [sendNotification] with `flutter_local_notifications` and registers
/// the instance as [notifierBackend].
class AppNotifierBackend implements NotifierBackend {
  final List<SentNotification> sent = [];

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    sent.add(SentNotification(title, body, tag));
    if (sent.length > 50) sent.removeAt(0);
    return true;
  }
}

/// Installs the app backend once at startup (idempotent).
AppNotifierBackend ensureNotifierBackend() {
  final existing = notifierBackend;
  if (existing is AppNotifierBackend) return existing;
  final backend = AppNotifierBackend();
  notifierBackend = backend;
  return backend;
}
