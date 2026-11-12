// Desktop notifications: core's subprocess senders, like Python.
//
// Port of the app side of `strakalari/core/notify.py`: core `notify()`
// decides *whether* to notify; core's `sendDesktop` (`desktop_notify.dart`)
// decides *how*, with Python's own mechanisms: a WinRT toast through a
// hidden PowerShell script on Windows, `osascript` on macOS, `notify-send`
// on Linux, then the stdout line.
//
// `flutter_local_notifications` was used here first; its Windows code
// crashes this Flutter's AOT compiler (gen_snapshot: "Class with illegal
// cid", NativeLaunchDetails), so release builds failed once start-up
// called it. Python never used a toast library on the desktop either.
import 'package:strakalari_core/strakalari_core.dart';

/// Installs the desktop senders as core's [notifierBackend] (startup).
NotifierBackend installDesktopNotifier() {
  const backend = SubprocessNotifierBackend();
  notifierBackend = backend;
  return backend;
}
