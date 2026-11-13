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
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

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
///
/// On Windows, uses `CreateProcessW` with `CREATE_NO_WINDOW` and `SW_HIDE` so
/// launching `powershell.exe` from a GUI (`/SUBSYSTEM:WINDOWS`) app does not
/// flash a console window (mirrors Python's `STARTF_USESHOWWINDOW`).
Future<int> runProcess(String exe, List<String> args,
    {required Duration timeout}) async {
  if (Platform.isWindows) {
    final ms = timeout.inMilliseconds.clamp(1, 0x7FFFFFFE);
    return Isolate.run(() => _runWindowsHiddenSync(exe, args, ms, timeout));
  }
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

const int _heapZeroMemory = 0x00000008;
const int _startfUseShowWindow = 0x00000001;
const int _createNoWindow = 0x08000000;
const int _waitObject0 = 0x00000000;
const int _waitTimeout = 0x00000102;

final class _StartupInfoW extends ffi.Struct {
  @ffi.Uint32()
  external int cb;
  external ffi.Pointer<ffi.Uint16> lpReserved;
  external ffi.Pointer<ffi.Uint16> lpDesktop;
  external ffi.Pointer<ffi.Uint16> lpTitle;
  @ffi.Uint32()
  external int dwX;
  @ffi.Uint32()
  external int dwY;
  @ffi.Uint32()
  external int dwXSize;
  @ffi.Uint32()
  external int dwYSize;
  @ffi.Uint32()
  external int dwXCountChars;
  @ffi.Uint32()
  external int dwYCountChars;
  @ffi.Uint32()
  external int dwFillAttribute;
  @ffi.Uint32()
  external int dwFlags;
  @ffi.Uint16()
  external int wShowWindow;
  @ffi.Uint16()
  external int cbReserved2;
  external ffi.Pointer<ffi.Uint8> lpReserved2;
  external ffi.Pointer<ffi.Void> hStdInput;
  external ffi.Pointer<ffi.Void> hStdOutput;
  external ffi.Pointer<ffi.Void> hStdError;
}

final class _ProcessInformation extends ffi.Struct {
  external ffi.Pointer<ffi.Void> hProcess;
  external ffi.Pointer<ffi.Void> hThread;
  @ffi.Uint32()
  external int dwProcessId;
  @ffi.Uint32()
  external int dwThreadId;
}

typedef _GetProcessHeapC = ffi.Pointer<ffi.Void> Function();
typedef _HeapAllocC = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void> hHeap, ffi.Uint32 dwFlags, ffi.Size dwBytes);
typedef _HeapFreeC = ffi.Int32 Function(ffi.Pointer<ffi.Void> hHeap,
    ffi.Uint32 dwFlags, ffi.Pointer<ffi.Void> lpMem);
typedef _CreateProcessWC = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint16> lpApplicationName,
  ffi.Pointer<ffi.Uint16> lpCommandLine,
  ffi.Pointer<ffi.Void> lpProcessAttributes,
  ffi.Pointer<ffi.Void> lpThreadAttributes,
  ffi.Int32 bInheritHandles,
  ffi.Uint32 dwCreationFlags,
  ffi.Pointer<ffi.Void> lpEnvironment,
  ffi.Pointer<ffi.Uint16> lpCurrentDirectory,
  ffi.Pointer<_StartupInfoW> lpStartupInfo,
  ffi.Pointer<_ProcessInformation> lpProcessInformation,
);
typedef _WaitForSingleObjectC = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void> hHandle, ffi.Uint32 dwMilliseconds);
typedef _GetExitCodeProcessC = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hProcess, ffi.Pointer<ffi.Uint32> lpExitCode);
typedef _TerminateProcessC = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hProcess, ffi.Uint32 uExitCode);
typedef _CloseHandleC = ffi.Int32 Function(ffi.Pointer<ffi.Void> hObject);

/// Quotes one Windows command-line argument using standard `CommandLineToArgvW` rules.
String _quoteWindowsArg(String arg) {
  if (arg.isNotEmpty && !RegExp(r'[\s"]').hasMatch(arg)) return arg;
  final buf = StringBuffer('"');
  var backslashes = 0;
  for (var i = 0; i < arg.length; i++) {
    final ch = arg[i];
    if (ch == r'\') {
      backslashes++;
    } else if (ch == '"') {
      buf.write(r'\' * (backslashes * 2 + 1));
      buf.write('"');
      backslashes = 0;
    } else {
      if (backslashes > 0) {
        buf.write(r'\' * backslashes);
        backslashes = 0;
      }
      buf.write(ch);
    }
  }
  if (backslashes > 0) buf.write(r'\' * (backslashes * 2));
  buf.write('"');
  return buf.toString();
}

int _runWindowsHiddenSync(
    String exe, List<String> args, int timeoutMs, Duration timeout) {
  final k32 = ffi.DynamicLibrary.open('kernel32.dll');
  final getProcessHeap =
      k32.lookupFunction<_GetProcessHeapC, ffi.Pointer<ffi.Void> Function()>(
          'GetProcessHeap');
  final heapAlloc = k32.lookupFunction<
      _HeapAllocC,
      ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Void>, int, int)>('HeapAlloc');
  final heapFree = k32.lookupFunction<
      _HeapFreeC,
      int Function(
          ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Void>)>('HeapFree');
  final createProcessW = k32.lookupFunction<
      _CreateProcessWC,
      int Function(
        ffi.Pointer<ffi.Uint16>,
        ffi.Pointer<ffi.Uint16>,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        int,
        int,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint16>,
        ffi.Pointer<_StartupInfoW>,
        ffi.Pointer<_ProcessInformation>,
      )>('CreateProcessW');
  final waitForSingleObject = k32.lookupFunction<_WaitForSingleObjectC,
      int Function(ffi.Pointer<ffi.Void>, int)>('WaitForSingleObject');
  final getExitCodeProcess = k32.lookupFunction<_GetExitCodeProcessC,
          int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)>(
      'GetExitCodeProcess');
  final terminateProcess = k32.lookupFunction<_TerminateProcessC,
      int Function(ffi.Pointer<ffi.Void>, int)>('TerminateProcess');
  final closeHandle =
      k32.lookupFunction<_CloseHandleC, int Function(ffi.Pointer<ffi.Void>)>(
          'CloseHandle');

  final cmdLine = [exe, ...args].map(_quoteWindowsArg).join(' ');
  final units = cmdLine.codeUnits;
  final heap = getProcessHeap();
  final cmdPtr =
      heapAlloc(heap, _heapZeroMemory, (units.length + 1) * 2).cast<ffi.Uint16>();
  final siPtr = heapAlloc(heap, _heapZeroMemory, ffi.sizeOf<_StartupInfoW>())
      .cast<_StartupInfoW>();
  final piPtr =
      heapAlloc(heap, _heapZeroMemory, ffi.sizeOf<_ProcessInformation>())
          .cast<_ProcessInformation>();
  final exitCodePtr =
      heapAlloc(heap, _heapZeroMemory, ffi.sizeOf<ffi.Uint32>())
          .cast<ffi.Uint32>();

  if (cmdPtr == ffi.nullptr ||
      siPtr == ffi.nullptr ||
      piPtr == ffi.nullptr ||
      exitCodePtr == ffi.nullptr) {
    if (cmdPtr != ffi.nullptr) heapFree(heap, 0, cmdPtr.cast());
    if (siPtr != ffi.nullptr) heapFree(heap, 0, siPtr.cast());
    if (piPtr != ffi.nullptr) heapFree(heap, 0, piPtr.cast());
    if (exitCodePtr != ffi.nullptr) heapFree(heap, 0, exitCodePtr.cast());
    throw ProcessException(exe, args, 'HeapAlloc failed');
  }

  try {
    cmdPtr.asTypedList(units.length + 1).setRange(0, units.length, units);
    siPtr.ref.cb = ffi.sizeOf<_StartupInfoW>();
    siPtr.ref.dwFlags = _startfUseShowWindow;
    siPtr.ref.wShowWindow = 0; // SW_HIDE

    final ok = createProcessW(
      ffi.nullptr,
      cmdPtr,
      ffi.nullptr,
      ffi.nullptr,
      0,
      _createNoWindow,
      ffi.nullptr,
      ffi.nullptr,
      siPtr,
      piPtr,
    );
    if (ok == 0) {
      throw ProcessException(exe, args, 'CreateProcessW failed');
    }
    final hProcess = piPtr.ref.hProcess;
    final hThread = piPtr.ref.hThread;
    try {
      final wait = waitForSingleObject(hProcess, timeoutMs);
      if (wait == _waitTimeout) {
        terminateProcess(hProcess, 1);
        throw TimeoutException('Process timed out', timeout);
      }
      if (wait != _waitObject0 ||
          getExitCodeProcess(hProcess, exitCodePtr) == 0) {
        throw ProcessException(exe, args, 'Wait/exit code lookup failed');
      }
      return exitCodePtr.value;
    } finally {
      closeHandle(hThread);
      closeHandle(hProcess);
    }
  } finally {
    heapFree(heap, 0, cmdPtr.cast());
    heapFree(heap, 0, siPtr.cast());
    heapFree(heap, 0, piPtr.cast());
    heapFree(heap, 0, exitCodePtr.cast());
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
