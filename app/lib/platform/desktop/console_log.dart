// Where a windowed build's warnings and tracebacks go.
//
// Port of `ensure_stdio` / `_console_log` (flet_ui/startup.py). A
// windowed Windows build has no console: without this every
// `print('Warning: …')` in the app (CONTRIBUTING §5 "fail loudly": print
// where no logger exists) vanished. Python pointed the missing
// stdout/stderr of its PyInstaller windowed build at `console.log` in the
// data folder; the Flutter Windows release runner has no console either,
// so its prints and uncaught errors go there too.
import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// `CONSOLE_LOG` (relative to the data dir) and its rotation size.
const String consoleLogFile = 'console.log';
const int consoleLogMaxBytes = 1024 * 1024;

/// A line-buffered append handle on `console.log` (each line is flushed).
class ConsoleLog {
  ConsoleLog._(this._file);
  final RandomAccessFile _file;

  void writeln(String line) {
    try {
      _file.writeStringSync('$line\n');
      _file.flushSync();
    } catch (_) {
      // stdio must never break the app (Python: errors="replace").
    }
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }
}

/// `_console_log()`: rotates a file over 1 MiB to `console.log.old`,
/// opens it for appending and writes the `=== <time> pid <pid> ===`
/// header. Null when it cannot be opened (startup never fails over it).
ConsoleLog? openConsoleLog(String dataDir, {DateTime? now}) {
  try {
    final path = '$dataDir${Platform.pathSeparator}$consoleLogFile';
    try {
      if (File(path).lengthSync() > consoleLogMaxBytes) {
        File(path).renameSync('$path.old');
      }
    } on FileSystemException {
      // Missing, or another process is rotating it.
    }
    final log = ConsoleLog._(File(path).openSync(mode: FileMode.append));
    final t = now ?? clock.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.writeln('\n=== ${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} pid $pid ===');
    return log;
  } catch (_) {
    return null;
  }
}

/// True where Python's windowed build had no stdio: the Windows release
/// build (the Flutter runner is a GUI app without a console). Debug runs
/// and the other desktops keep their terminal, like Python's source runs.
bool get windowedBuild => Platform.isWindows && kReleaseMode;

/// Runs [body] with its prints and uncaught errors going to [log] (and
/// still to the parent zone's print, harmless without a console).
Future<void> runWithConsoleLog(ConsoleLog log, Future<void> Function() body) {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      await body();
      if (!done.isCompleted) done.complete();
    },
    (error, stack) {
      log.writeln('Unhandled error: $error\n$stack');
      if (!done.isCompleted) done.complete();
    },
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {
      log.writeln(line);
      parent.print(zone, line);
    }),
  );
  return done.future;
}
