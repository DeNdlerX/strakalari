// Port of TestEnsureStdio (tests/test_shutdown.py): a windowed build's
// warnings and tracebacks land in console.log (rotated at 1 MiB, one
// header per start). Python's None / broken stream cases have no Dart
// counterpart (print never fails here); see Dropped.
import 'dart:io';

import 'package:app/platform/desktop/console_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('console_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File logFile() => File('${dir.path}${Platform.pathSeparator}console.log');

  test('windowedWarningsLandInConsoleLog', () async {
    final log = openConsoleLog(dir.path, now: DateTime(2026, 11, 12, 9, 5, 7))!;
    await runWithConsoleLog(log, () async {
      // ignore: avoid_print
      print('Warning: visible now');
      Future<void>.microtask(() => throw StateError('Traceback: also here'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    log.close();
    final text = logFile().readAsStringSync();
    expect(text, contains('\n=== 2026-11-12 09:05:07 pid $pid ===\n'));
    expect(text, contains('Warning: visible now'));
    expect(text, contains('Traceback: also here'));
  });

  test('aSecondStartAppends', () {
    openConsoleLog(dir.path)!
      ..writeln('first')
      ..close();
    openConsoleLog(dir.path)!
      ..writeln('second')
      ..close();
    final text = logFile().readAsStringSync();
    expect(text.indexOf('first'), lessThan(text.indexOf('second')));
    expect(RegExp('=== ').allMatches(text), hasLength(2));
  });

  test('aFullLogIsRotatedToOld', () {
    logFile().writeAsStringSync('x' * (consoleLogMaxBytes + 1));
    openConsoleLog(dir.path)!.close();
    expect(File('${logFile().path}.old').lengthSync(), consoleLogMaxBytes + 1);
    expect(logFile().lengthSync(), lessThan(100));
  });

  test('anUnwritableFolderNeverStopsTheStart', () {
    expect(openConsoleLog('${dir.path}${Platform.pathSeparator}missing${Platform.pathSeparator}deeper'), isNull);
  });

  test('onlyTheWindowsReleaseBuildRedirects', () {
    // Tests run in debug mode: never redirected, like a source run.
    expect(windowedBuild, isFalse);
  });
}
