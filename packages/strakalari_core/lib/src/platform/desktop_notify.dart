// Desktop toast senders. Port of the OS half of `strakalari/core/notify.py`.
//
// - Windows: native WinRT toast through a hidden `powershell -File`
//   script written as UTF-8 with BOM (PowerShell 5.1 reads -File scripts
//   in the system codepage otherwise, mangling Czech diacritics).
// - macOS: `osascript` (always present).
// - Linux: `notify-send` (checked exit code).
//
// Deviation: Python's last-resort `plyer` fallback is not ported (no Dart
// equivalent; the stdout print in core `notify` stays the last resort).
// Deviation: core's backend interface is synchronous and a subprocess is
// not, so [SubprocessNotifierBackend] starts the send and reports
// "accepted"; a failed send prints the stdout line afterwards.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'notifier.dart';

/// Finds [name] on PATH like `shutil.which` (null when absent).
typedef WhichFn = String? Function(String name);

/// Runs [exe] with [args] and returns its exit code (a timeout or a
/// start failure throws).
typedef RunFn = Future<int> Function(String exe, List<String> args,
    {required Duration timeout});

/// `shutil.which` for the senders below.
String? which(String name) {
  final path = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  final exts = Platform.isWindows && p.extension(name).isEmpty
      ? (Platform.environment['PATHEXT'] ?? '.EXE').split(';')
      : [''];
  for (final dir in path.split(sep)) {
    if (dir.isEmpty) continue;
    for (final ext in exts) {
      final candidate = p.join(dir, '$name$ext');
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

/// `subprocess.run(..., stdin=DEVNULL, capture, timeout=…)`: the exit code.
Future<int> runProcess(String exe, List<String> args,
    {required Duration timeout}) async {
  final process = await Process.start(exe, args);
  unawaited(process.stdin.close());
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  try {
    return await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    rethrow;
  }
}

/// Escapes [text] for a PowerShell single-quoted literal ($ and ` stay
/// literal).
String psSingleQuote(String text) => text.replaceAll("'", "''");

/// Wraps [text] as XML CDATA (toast title/body).
String cdata(String text) =>
    '<![CDATA[${text.replaceAll(']]>', ']] >')}]]>';

/// The PowerShell script showing one WinRT toast.
String toastPsScript(String title, String message, String tag) {
  final xml = '<toast duration="short">'
      '<visual><binding template="ToastGeneric">'
      '<text id="1">${cdata(title)}</text>'
      '<text id="2">${cdata(message)}</text>'
      '</binding></visual>'
      '<audio silent="true"/>'
      '</toast>';
  return '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, '
      'ContentType=WindowsRuntime] | Out-Null\n'
      '[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, '
      'ContentType=WindowsRuntime] | Out-Null\n'
      "\$xml = '${psSingleQuote(xml)}'\n"
      '\$doc = New-Object Windows.Data.Xml.Dom.XmlDocument\n'
      '\$doc.LoadXml(\$xml)\n'
      '\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$doc)\n'
      "\$toast.Tag = '${psSingleQuote(tag)}'\n"
      "\$toast.Group = '${psSingleQuote(appId)}'\n"
      '\$notifier = [Windows.UI.Notifications.ToastNotificationManager]'
      "::CreateToastNotifier('${psSingleQuote(appId)}')\n"
      '\$notifier.Show(\$toast)\n';
}

/// Native WinRT toast via hidden powershell. True only on exit code 0.
Future<bool> sendWindows(String title, String message, String tag,
    {WhichFn whichFn = which, RunFn run = runProcess}) async {
  final exe =
      whichFn('powershell.exe') ?? whichFn('pwsh.exe') ?? whichFn('pwsh');
  if (exe == null) return false;
  File? script;
  try {
    final dir = Directory.systemTemp.createTempSync('strakalari-toast-');
    script = File(p.join(dir.path, 'toast.ps1'));
    // UTF-8 with BOM: PowerShell 5.1 needs it for the diacritics.
    script.writeAsBytesSync(
        [0xEF, 0xBB, 0xBF, ...utf8.encode(toastPsScript(title, message, tag))]);
    final code = await run(
        exe, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        timeout: const Duration(seconds: 30));
    return code == 0;
  } catch (_) {
    return false;
  } finally {
    try {
      script?.parent.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// macOS Notification Center via osascript (no dependencies).
Future<bool> sendMacos(String title, String message,
    {WhichFn whichFn = which, RunFn run = runProcess}) async {
  final exe = whichFn('osascript');
  if (exe == null) return false;
  String escape(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  final script = 'display notification "${escape(message)}"'
      ' with title "${escape(title)}"'
      ' subtitle "${escape(appName)}"';
  try {
    return await run(exe, ['-e', script],
            timeout: const Duration(seconds: 15)) ==
        0;
  } catch (_) {
    return false;
  }
}

/// Linux desktop notification via notify-send (checked exit code).
Future<bool> sendLinux(String title, String message,
    {WhichFn whichFn = which, RunFn run = runProcess}) async {
  final exe = whichFn('notify-send');
  if (exe == null) return false;
  try {
    return await run(exe, ['-a', appName, title, message, '-t', '8000'],
            timeout: const Duration(seconds: 15)) ==
        0;
  } catch (_) {
    return false;
  }
}

/// Port of `_send` for the desktop: the platform's sender, then stdout.
Future<bool> sendDesktop(String title, String message, String tag,
    {String? platform}) async {
  final os = platform ?? Platform.operatingSystem;
  var sent = false;
  try {
    if (os == 'windows') {
      sent = await sendWindows(title, message, tag);
    } else if (os == 'macos') {
      sent = await sendMacos(title, message);
    } else {
      sent = await sendLinux(title, message);
    }
  } catch (_) {
    sent = false;
  }
  if (!sent) {
    // No toast backend worked — plain stdout fallback, no scary suffix.
    // ignore: avoid_print
    print('[$title] $message');
  }
  return sent;
}

/// Core's [NotifierBackend] over [sendDesktop] (install as
/// `notifierBackend` on the desktop).
class SubprocessNotifierBackend implements NotifierBackend {
  const SubprocessNotifierBackend();

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    unawaited(sendDesktop(title, body, tag));
    return true;
  }
}
