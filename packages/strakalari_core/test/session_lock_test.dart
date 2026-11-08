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

/// Walks up from the test working dir to the repo root (the dir containing
/// `strakalari/core/helpers.py`), or null when not found.
String? _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}${Platform.pathSeparator}strakalari'
            '${Platform.pathSeparator}core'
            '${Platform.pathSeparator}helpers.py')
        .existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

/// Python body: holds `flock(LOCK_EX)` on `sys.argv[1]` for 60 s.
///
/// Loads `strakalari/core/helpers.py` by path (not via the package: the
/// package `__init__` pulls in the heavy automation engine).
String _pythonHoldScript(String repoRoot) => '''
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location(
    "b5_helpers", ${jsonEncode('$repoRoot/strakalari/core/helpers.py')})
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
lock = helpers.InterProcessLock(sys.argv[1])
print("held" if lock.acquire(0.0) else "failed", flush=True)
time.sleep(60)
''';

/// Runs one Python `InterProcessLock.acquire(0.0)` attempt on [lockPath],
/// returns 'true' or 'false'.
Future<String> _pythonTryLock(String repoRoot, String lockPath) async {
  final script = '''
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "b5_helpers", ${jsonEncode('$repoRoot/strakalari/core/helpers.py')})
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
lock = helpers.InterProcessLock(sys.argv[1])
print("true" if lock.acquire(0.0) else "false")
''';
  final result = await Process.run('python3', ['-c', script, lockPath])
      .timeout(const Duration(seconds: 60));
  expect(result.exitCode, 0, reason: 'python stderr: ${result.stderr}');
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

  group('withSessionLockAsync', () {
    test('holdsAcrossAwait', () async {
      await withSessionLockAsync((held) async {
        expect(held, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // Still held after the await: a nested job must skip.
        withSessionLock((inner) {
          expect(inner, isFalse);
        }, lockFile: lockPath());
      }, lockFile: lockPath());
      withSessionLock((again) {
        expect(again, isTrue);
      }, lockFile: lockPath());
    });

    test('releasesAfterBody', () async {
      final seen = <bool>[];
      final result = await withSessionLockAsync((held) async {
        seen.add(held);
        return 'done';
      }, lockFile: lockPath());
      expect(result, 'done');
      expect(seen, [true]);
      withSessionLock((again) {
        expect(again, isTrue);
      }, lockFile: lockPath());
    });

    test('skipsWhileBusy', () async {
      final inner = <bool>[];
      await withSessionLockAsync((held) async {
        expect(held, isTrue);
        inner.add(await withSessionLockAsync((busy) async => busy,
            lockFile: lockPath()));
      }, lockFile: lockPath());
      expect(inner, [false]);
    });

    test('syncVariantRejectsFutureBody', () {
      expect(
        () => withSessionLock((held) => Future.value(held),
            lockFile: lockPath()),
        throwsA(isA<AssertionError>()),
      );
      // The rejected body still released the lock: acquirable again.
      withSessionLock((again) {
        expect(again, isTrue);
      }, lockFile: lockPath());
    });
  });

  group('pythonInterop', () {
    test(
      'matchesPythonFlock',
      () async {
        final repoRoot = _findRepoRoot();
        if (repoRoot == null) {
          markTestSkipped('repo root with strakalari/ not found.');
          return;
        }
        try {
          final version = await Process.run('python3', ['--version'])
              .timeout(const Duration(seconds: 30));
          if (version.exitCode != 0) {
            markTestSkipped('python3 is not usable.');
            return;
          }
        } catch (_) {
          markTestSkipped('python3 is not available.');
          return;
        }

        // Python holds -> Dart refuses.
        final holder = await Process.start(
          'python3',
          ['-c', _pythonHoldScript(repoRoot), lockPath()],
        );
        final stderrText = holder.stderr.transform(utf8.decoder).join();
        try {
          final firstLine = await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 60));
          if (firstLine.trim() != 'held') {
            final err = await stderrText;
            fail('Python holder did not acquire the lock '
                '(got "$firstLine"). stderr: $err');
          }
          final blocked = InterProcessLock(lockPath());
          expect(blocked.acquire(), isFalse);
          expect(blocked.held, isFalse);
        } finally {
          holder.kill(ProcessSignal.sigkill);
          await holder.exitCode;
        }
        final afterPython = InterProcessLock(lockPath());
        expect(afterPython.acquire(), isTrue);
        afterPython.release();

        // Dart holds -> Python refuses; released -> Python acquires.
        final dartLock = InterProcessLock(lockPath());
        expect(dartLock.acquire(), isTrue);
        try {
          expect(await _pythonTryLock(repoRoot, lockPath()), 'false');
        } finally {
          dartLock.release();
        }
        expect(await _pythonTryLock(repoRoot, lockPath()), 'true');
      },
      skip: Platform.isLinux ? false : 'flock parity probe runs on Linux only.',
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });
}
