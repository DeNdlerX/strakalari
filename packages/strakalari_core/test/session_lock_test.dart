// Cross-process guards: the session lock (plus the merge-on-save config
// cases that live in the same Python file).
//
// Port of tests/test_session_lock.py. The tray/window skip cases have no
// Dart tray or window yet, so they are ported as the lock-gated skip
// contract they assert: while the session is held, a guarded job must
// skip instead of running in parallel.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/session_lock.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

/// Child-process entry: tries the lock once, prints the outcome, exits
/// (the OS drops the lock on exit, mirroring the Python test's child).
void _maybeRunAsHolder() {
  if (Platform.environment['STRAKALARI_SESSION_LOCK_HOLDER'] != '1') return;
  final lockPath = Platform.environment['STRAKALARI_SESSION_LOCK_PATH']!;
  final lock = InterProcessLock(lockPath);
  print(lock.acquire() ? 'true' : 'false');
  exit(0);
}

Future<String> _tryLockInChild(String lockPath) async {
  final script = File('test/session_lock_test.dart').absolute.path;
  final result = await Process.run(
    Platform.resolvedExecutable,
    [script],
    workingDirectory: Directory.current.path,
    environment: {
      ...Platform.environment,
      'STRAKALARI_SESSION_LOCK_HOLDER': '1',
      'STRAKALARI_SESSION_LOCK_PATH': lockPath,
    },
  );
  expect(result.exitCode, 0, reason: 'holder stderr: ${result.stderr}');
  return (result.stdout as String).trim();
}

void main() {
  _maybeRunAsHolder();

  Directory? tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_lock_test_');
  });
  tearDown(() {
    if (tmp != null && tmp!.existsSync()) tmp!.deleteSync(recursive: true);
  });

  String lockPath() =>
      '${tmp!.path}${Platform.pathSeparator}session.lock';

  group('sessionLock', () {
    test('isExclusiveWithinProcess', () {
      withSessionLock((first) {
        expect(first, isTrue);
        withSessionLock((second) {
          expect(second, isFalse);
        }, lockFile: lockPath());
      }, lockFile: lockPath());
      withSessionLock((again) {
        expect(again, isTrue);
      }, lockFile: lockPath());
    });

    test('blocksOtherProcess', () async {
      final lock = InterProcessLock(lockPath());
      expect(lock.acquire(), isTrue);
      try {
        // Another process must fail while this one holds the lock.
        expect(await _tryLockInChild(lockPath()), 'false');
      } finally {
        lock.release();
      }
      // Released (and a dead holder never keeps it): acquirable again.
      expect(await _tryLockInChild(lockPath()), 'true');
    });

    test('guardedJobSkipsWhileSessionHeld', () {
      final ran = <int>[];
      String guardedJob() => withSessionLock((held) {
            if (!held) return 'skipped: session busy';
            ran.add(1);
            return 'ok';
          }, lockFile: lockPath());
      withSessionLock((held) {
        expect(held, isTrue);
        expect(guardedJob(), contains('skipped'));
      }, lockFile: lockPath());
      expect(ran, isEmpty);
      expect(guardedJob(), 'ok');
    });

    test('guardedWorkRecordsFailedRunWhileHeld', () {
      final runs = <Map<String, Object?>>[];
      void guardedWork() {
        withSessionLock((held) {
          if (!held) {
            runs.add({'ok': false});
            return;
          }
          runs.add({'ok': true});
        }, lockFile: lockPath());
      }
      withSessionLock((held) {
        expect(held, isTrue);
        guardedWork();
      }, lockFile: lockPath());
      expect(runs.single['ok'], isFalse);
      guardedWork();
      expect(runs.last['ok'], isTrue);
    });
  });

  group('configSave', () {
    test('keepsOtherProcessEdits', () {
      final path =
          '${tmp!.path}${Platform.pathSeparator}config.json';
      final window = ConfigManager(path);
      window.set('theme', 'light');
      window.save();

      final tray = ConfigManager(path);
      tray.set('gemini_last_run', '2026-09-24');
      tray.save();

      // The window's copy is stale; saving an unrelated edit must not
      // roll back the tray's stamp.
      window.set('language', 'en');
      window.save();

      final onDisk = jsonDecode(File(path).readAsStringSync())
          as Map<String, Object?>;
      expect(onDisk['gemini_last_run'], '2026-09-24');
      expect(onDisk['language'], 'en');
      expect(onDisk['theme'], 'light');
      expect(window.get('gemini_last_run'), '2026-09-24');
    });

    test('ownEditWinsOnSameKey', () {
      final path =
          '${tmp!.path}${Platform.pathSeparator}config.json';
      final a = ConfigManager(path);
      a.save();
      final b = ConfigManager(path);
      b.set('theme', 'light');
      b.save();
      a.set('theme', 'dark');
      a.save();
      expect(
          (jsonDecode(File(path).readAsStringSync())
              as Map<String, Object?>)['theme'],
          'dark');
    });
  });
}
