// Periodic background runner: scheduling math, retries, error capture.
//
// Port of tests/test_scheduler.py + tests/test_scheduler_retry.py (the
// PeriodicRunner core cases). The window/tray wiring cases (_register_jobs,
// TrayApp, the refresh job wrapper) belong to the refresh/app owners:
// this package has no AppState or tray yet.
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/scheduler.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';

String _stamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

void main() {
  Directory? tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('scheduler_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp!.path});
  });
  tearDown(() {
    setEnvironmentOverride(null);
    if (tmp != null && tmp!.existsSync()) tmp!.deleteSync(recursive: true);
  });

  group('PeriodicRunner', () {
    test('stopWithoutStartIsSafe', () {
      PeriodicRunner(intervalMinutes: 60).stop();
    });

    test('startStopCycle', () {
      final runner = PeriodicRunner(intervalMinutes: 60);
      runner.start();
      try {
        expect(runner.running, isTrue);
      } finally {
        runner.stop();
      }
      expect(runner.running, isFalse);
    });

    test('failedRunRetriesSoon', () async {
      final runner = PeriodicRunner(intervalMinutes: 60);
      runner.addJob('bad', () => throw StateError('x'));
      final before = DateTime.now();
      await runner.runAllOnce();
      final dueIn = (runner.lastRun!
                  .add(const Duration(minutes: 60))
                  .difference(before))
              .inSeconds /
          60;
      // ~5 min, not a full hour.
      expect(dueIn, greaterThan(0));
      expect(dueIn, lessThanOrEqualTo(6));
    });

    test('asyncJobFailureTriggersEarlyRetry', () async {
      final seen = <JobResult>[];
      final runner =
          PeriodicRunner(intervalMinutes: 60, onResult: seen.add);
      runner.addJob('async_refresh', () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw const JobFailed('async network failure');
      });
      final before = DateTime.now();
      final results = await runner.runAllOnce();
      expect(results.single.ok, isFalse);
      expect(results.single.reported, isTrue);
      expect(seen.single.ok, isFalse);
      final dueIn =
          nextDue(runner.lastRun, 60, before).difference(before);
      expect(dueIn, greaterThan(Duration.zero));
      expect(dueIn, lessThan(const Duration(minutes: 6)));
    });

    test('runNowLeavesTimerAlone', () async {
      final runner = PeriodicRunner(intervalMinutes: 60);
      runner.addJob('good', () => 'ok');
      expect(runner.lastRun, isNull);
      await runner.runNow();
      expect(runner.lastRun, isNull);
    });

    test('runsJobsAndCapturesErrors', () async {
      final calls = <int>[];
      final runner = PeriodicRunner(intervalMinutes: 60);
      runner.addJob('good', () {
        calls.add(1);
        return 'ok';
      });
      runner.addJob('bad', () => throw StateError('x'));
      final results = await runner.runNow();
      expect(calls, [1]);
      final byName = {for (final r in results) r.name: r};
      expect(byName['good']!.ok, isTrue);
      expect(byName['bad']!.ok, isFalse);
      expect(byName['bad']!.error, isNotEmpty);
    });

    test('keepsFullTraceback', () async {
      void inner() => throw StateError('deep cause');
      void middle() => inner();
      void outer() => middle();

      final runner = PeriodicRunner(intervalMinutes: 60);
      runner.addJob('deep', () => outer());
      late final List<JobResult> results;
      await expectLater(() async {
        results = await runner.runNow();
      }, prints(contains("scheduled job 'deep' failed")));
      // The innermost frame is where the bug is.
      expect(results.single.error, contains('inner'));
      expect(results.single.error, contains('deep cause'));
    });

    test('intervalProviderIsPolled', () {
      final runner = PeriodicRunner(
          intervalMinutes: 60, intervalProvider: () => 15);
      runner.pollInterval();
      expect(runner.intervalMinutes, 15);
      runner.intervalProvider = () => null; // "unchanged"
      runner.pollInterval();
      expect(runner.intervalMinutes, 15);
    });

    test('jobFailedCountsAsFailureButReported', () async {
      void job() => throw const JobFailed('login failed');

      final seen = <JobResult>[];
      final runner =
          PeriodicRunner(intervalMinutes: 60, onResult: seen.add);
      runner.addJob('refresh', job);
      final before = DateTime.now();
      await runner.runAllOnce();
      expect(seen.single.ok, isFalse);
      expect(seen.single.reported, isTrue);
      // Early retry: due in ~5 minutes, not a full interval.
      final dueIn =
          nextDue(runner.lastRun, 60, before).difference(before);
      expect(dueIn, lessThan(const Duration(minutes: 6)));
    });
  });

  group('nextDue', () {
    test('scheduling', () {
      final now = DateTime(2026, 9, 7, 12, 0);
      expect(nextDue(null, 60, now), now);
      final last = DateTime(2026, 9, 7, 11, 0);
      expect(nextDue(last, 60, now), DateTime(2026, 9, 7, 12, 0));
    });

    test('seedDefersFirstAutoRun', () {
      final now = DateTime.now();
      final freshSeed = now.subtract(const Duration(minutes: 10));
      // Next run in ~50 min, not at start.
      expect(nextDue(freshSeed, 60, now).isAfter(now), isTrue);
      final staleSeed = now.subtract(const Duration(hours: 3));
      // Overdue -> run on first tick.
      expect(nextDue(staleSeed, 60, now).isBefore(now), isTrue);
      // Unknown -> old behavior.
      expect(nextDue(null, 60, now), now);
    });
  });

  group('cacheSeed', () {
    test('lastUpdatedTimeParsesFormats', () {
      final now = DateTime.now().copyWith(microsecond: 0);
      expect(lastUpdatedTime({'last_updated': _stamp(now)}),
          now.copyWith(millisecond: 0, microsecond: 0));
      expect(
          lastUpdatedTime({
            'last_updated':
                '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} 12:00:00'
          }),
          isNotNull);
      expect(lastUpdatedTime({}), isNull);
      expect(lastUpdatedTime({'last_updated': 'nonsense'}), isNull);
    });

    test('startupSeedNeedsPositiveEvidence', () {
      final now = DateTime.now();
      final fresh =
          startupSeed({'last_updated': _stamp(now.subtract(
            const Duration(minutes: 10)))}, now);
      expect(fresh, isNotNull);
      expect(now.difference(fresh!), lessThan(const Duration(minutes: 11)));
      // Overdue stamp is still a seed (nextDue puts it in the past).
      expect(
          startupSeed({'last_updated': _stamp(now.subtract(
            const Duration(hours: 3)))}, now),
          isNotNull);
      // Unknown or future stamps fall back to refresh-on-start (null).
      expect(startupSeed({}, now), isNull);
      expect(startupSeed({'last_updated': 'nonsense'}, now), isNull);
      expect(
          startupSeed(
              {'last_updated': _stamp(now.add(const Duration(hours: 1)))},
              now),
          isNull);
    });

    test('runnerAcceptsLastRunSeed', () {
      final seed = DateTime.now().subtract(const Duration(minutes: 10));
      expect(PeriodicRunner(intervalMinutes: 60, lastRun: seed).lastRun,
          seed);
      expect(PeriodicRunner(intervalMinutes: 60).lastRun, isNull);
    });
  });

  test('schedulerHoldsRunsWhilePaused', () async {
    // Port of tests/test_mobile.py: the phone app in the background holds
    // due runs; the overdue run fires once when it comes back.
    final ran = <int>[];
    var hidden = true;
    final runner = PeriodicRunner(intervalMinutes: 60, paused: () => hidden);
    runner.addJob('refresh', () => ran.add(1));
    await runner.tick();
    await runner.tick();
    expect(ran, isEmpty); // held twice
    hidden = false; // the app came back
    await runner.tick();
    await runner.tick(); // not due again
    expect(ran, [1]);
  });

  group('PeriodicRunner nextDueProvider (F6)', () {
    test('usesProviderAndRespectsOffHoursPauseWithoutOneMinuteLoop', () async {
      final ran = <DateTime>[];
      final targetWake = DateTime(2026, 9, 8, 7, 0);
      final runner = PeriodicRunner(
        intervalMinutes: 5,
        lastRun: DateTime(2026, 9, 7, 17, 0),
        nextDueProvider: (lastRun, now) =>
            now.isBefore(targetWake) ? targetWake : now,
      );
      runner.addJob('refresh', () => ran.add(clock.now()));

      // Throughout the night (even hours later), tick does not fire.
      for (final t in [
        DateTime(2026, 9, 7, 17, 5),
        DateTime(2026, 9, 7, 22, 0),
        DateTime(2026, 9, 8, 6, 59),
      ]) {
        await withClock(Clock.fixed(t), () async {
          expect(runner.nextDueAt(t), targetWake);
          await runner.tick();
        });
      }
      expect(ran, isEmpty);

      // Right at 07:00 it fires once.
      await withClock(Clock.fixed(targetWake), () async {
        await runner.tick();
      });
      expect(ran, [targetWake]);
      expect(runner.lastRun, targetWake);
    });

    test('failedRunWithProviderSetsRetryAtWithoutRewritingLastRun', () async {
      var shouldFail = true;
      final start = DateTime(2026, 9, 7, 20, 0);
      final initialLastRun = DateTime(2026, 9, 7, 17, 0);
      final morning = DateTime(2026, 9, 8, 7, 0);
      final runner = PeriodicRunner(
        intervalMinutes: 60,
        lastRun: initialLastRun,
        nextDueProvider: (lastRun, now) => morning,
      );
      runner.addJob('refresh', () {
        if (shouldFail) throw const JobFailed('net down');
        return 'ok';
      });

      await withClock(Clock.fixed(start), () async {
        await runner.runAllOnce();
        // lastRun was NOT rewritten backwards; retryAt schedules +5 min.
        expect(runner.lastRun, initialLastRun);
        expect(runner.nextDueAt(start), start.add(const Duration(minutes: 5)));
      });

      // 4 minutes later: not due yet.
      await withClock(Clock.fixed(start.add(const Duration(minutes: 4))),
          () async {
        await runner.tick();
        expect(runner.history.length, 1);
      });

      // 5 minutes later: retry runs and succeeds -> retryAt cleared, lastRun updated.
      shouldFail = false;
      final retryTime = start.add(const Duration(minutes: 5));
      await withClock(Clock.fixed(retryTime), () async {
        await runner.tick();
        expect(runner.history.length, 2);
        expect(runner.history.last.ok, isTrue);
        expect(runner.lastRun, retryTime);
        expect(runner.nextDueAt(retryTime), morning);
      });
    });

    test('runnerWithoutProviderKeepsLegacyBehavior', () async {
      final t0 = DateTime(2026, 9, 7, 10, 0);
      final runner = PeriodicRunner(intervalMinutes: 60, lastRun: t0);
      expect(runner.nextDueAt(t0), DateTime(2026, 9, 7, 11, 0));
    });
  });
}
