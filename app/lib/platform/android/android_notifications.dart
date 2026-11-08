// Android notification backend (event notifications, not the ongoing one).
//
// Posts through `AndroidChannel.notify` on the `strakalari_events` channel —
// the same path as Python's `_send_android` in `core/notify.py` (the channel
// name is "Automation"/"Automatizace" by language). The ongoing background
// notification stays with `KeepAliveService` (see `AndroidChannel`).
import 'package:strakalari_core/strakalari_core.dart';

import 'android_channel.dart';

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
  }) {
    // Core's `notify` calls synchronously; the channel answers async, so
    // the post is fire-and-forget and `true` means "accepted", like the
    // desktop toast backends (a failure only skips the stdout fallback).
    final english = languageOf?.call() == 'en';
    channel.notify(
      title: title,
      text: body,
      channelName: english ? 'Automation' : 'Automatizace',
    );
    return true;
  }
}
