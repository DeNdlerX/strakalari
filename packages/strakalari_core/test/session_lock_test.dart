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

/// Python body: holds `flock(LOCK_EX)` on `sys.argv[1]` for 60 s.
const String _pythonHoldScript = r'''
import fcntl, os, sys, time
path = sys.argv[1]
os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
fh = open(path, "a+b")
try:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    fh.close()
    print("failed", flush=True)
    sys.exit(0)
print("held", flush=True)
time.sleep(60)
''';

/// Runs one non-blocking `fcntl.flock(LOCK_EX | LOCK_NB)` attempt on
/// [lockPath], returns 'true' or 'false'.
Future<String> _pythonTryLock(String lockPath) async {
  const script = r'''
import fcntl, os, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
fh = open(path, "a+b")
try:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    print("true")
except OSError:
    print("false")
finally:
    fh.close()
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

    test(
      'freshLockFileIsOwnerReadWritable',
      () {
        // `open` is variadic: a wrongly declared mode argument gives random
        // permission bits on Apple arm64 and the lock looks busy forever.
        final path = lockPath();
        final first = InterProcessLock(path);
        expect(first.acquire(), isTrue);
        first.release();
        expect(FileStat.statSync(path).mode & 0x180, 0x180);
        final second = InterProcessLock(path);
        expect(second.acquire(), isTrue);
        second.release();
      },
      skip: Platform.isWindows ? 'POSIX permission bits only.' : false,
    );

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
          ['-c', _pythonHoldScript, lockPath()],
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
          expect(await _pythonTryLock(lockPath()), 'false');
        } finally {
          dartLock.release();
        }
        expect(await _pythonTryLock(lockPath()), 'true');
      },
      // POSIX flock on Linux and macOS (job dart-macos-locks); Windows
      // uses LockFileEx, proven against Python by hand (Checkpoint A).
      skip: (Platform.isLinux || Platform.isMacOS)
          ? false
          : 'flock parity probe runs on Linux and macOS only.',
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });
}
