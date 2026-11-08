// Periodic background runner for refresh / auto-excuse / lunch jobs.
//
// Port of strakalari/core/scheduler.py. The UI (or tray) registers
// callables; the runner executes them every [intervalMinutes] on a
// [Timer] and reports results through an optional callback. Jobs must
// never raise — failures are captured and reported as [JobResult].
//
// A tiny pure helper ([nextDue]) holds the scheduling math so it stays
// unit-testable without timers or clocks.
//
// Deviation: Python drives the loop with a daemon thread; Dart uses a
// `Timer.periodic` (PLAN §3.4). [waitStopped] is therefore async, and
// the in-isolate job table needs no thread lock (Dart runs one event
// loop per isolate).
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';

import '../error_report.dart';

/// When the next run should happen given the last one.
DateTime nextDue(DateTime? lastRun, double? intervalMinutes, DateTime now) {
  final interval = math.max(1.0, intervalMinutes ?? 60.0);
  if (lastRun == null) return now;
  return lastRun
      .add(Duration(microseconds: (interval * 60 * 1000000).round()));
}

/// A job failure the job itself already reported to the user.
///
/// Counts as a failed run (early retry), but [ResultCallback]s
/// should not notify about it a second time ([JobResult.reported]).
class JobFailed implements Exception {
  final String message;

  const JobFailed(this.message);

  @override
  String toString() => 'JobFailed: $message';
}

/// One finished job run.
class JobResult {
  final String name;
  final bool ok;
  final DateTime finishedAt;
  final String detail;
  final String error;

  /// True when the job already surfaced the failure (see [JobFailed]).
  final bool reported;

  JobResult({
    required this.name,
    required this.ok,
    DateTime? finishedAt,
    this.detail = '',
    this.error = '',
    this.reported = false,
  }) : finishedAt = finishedAt ?? clock.now();

  JobResult copyWith({
    String? name,
    bool? ok,
    DateTime? finishedAt,
    String? detail,
    String? error,
    bool? reported,
  }) =>
      JobResult(
        name: name ?? this.name,
        ok: ok ?? this.ok,
        finishedAt: finishedAt ?? this.finishedAt,
        detail: detail ?? this.detail,
        error: error ?? this.error,
        reported: reported ?? this.reported,
      );
}

/// A scheduled unit of work; its return value becomes [JobResult.detail].
typedef Job = Object? Function();

/// Receives one [JobResult] per finished job.
typedef ResultCallback = void Function(JobResult result);

String _detailString(Object? detail) {
  if (detail == null) return '';
  if (detail is String) return detail;
  if (detail is num && detail == 0) return '';
  if (detail is bool && !detail) return '';
  return '$detail';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Runs registered jobs every [intervalMinutes] on a [Timer].
class PeriodicRunner {
  double intervalMinutes;
  ResultCallback? onResult;

  /// Polled every tick so a setting saved elsewhere takes effect
  /// without a restart.
  double? Function()? intervalProvider;

  /// True = hold due runs (the phone app in the background, where the
  /// OS freezes it mid-run). A held run fires on the first tick after.
  bool Function()? paused;

  final Map<String, Job> _jobs = {};

  /// Seed for process starts: pass the last successful refresh time so
  /// the first auto-run comes [intervalMinutes] after it instead of
  /// firing ~5 s after launch even with a fresh cache. Null = run on
  /// first tick.
  DateTime? lastRun;

  final List<JobResult> _history = [];
  Timer? _timer;
  Completer<bool>? _stopSignal;

  PeriodicRunner({
    double? intervalMinutes = 60,
    this.onResult,
    this.lastRun,
    this.intervalProvider,
    this.paused,
  }) : intervalMinutes = _normalizeInterval(intervalMinutes);

  static double _normalizeInterval(double? value) =>
      math.max(1.0, value ?? 60.0);

  void addJob(String name, Job job) {
    _jobs[name] = job;
  }

  /// Jobs registered under their names (read-only view).
  Map<String, Job> get jobs => Map.unmodifiable(_jobs);

  /// Last results, newest last (kept to 50 entries).
  List<JobResult> get history => List.unmodifiable(_history);

  bool get running => _timer?.isActive ?? false;

  List<JobResult> _runAllOnce({bool advanceTimer = true}) {
    final jobs = Map<String, Job>.of(_jobs);
    final results = <JobResult>[];
    for (final entry in jobs.entries) {
      try {
        final detail = entry.value();
        results.add(
            JobResult(name: entry.key, ok: true, detail: _detailString(detail)));
      } on JobFailed catch (e) {
        results.add(JobResult(
            name: entry.key, ok: false, error: e.message, reported: true));
      } catch (e, st) {
        // Full trace: keeping only the outer frames would hide where the
        // job actually broke. Printed too — outside a dialog this lands
        // in the log, the only trace a background failure otherwise leaves.
        final tb = formatTraceback(e, st);
        final now = clock.now();
        print("Error: scheduled job '${entry.key}' failed at "
            '${now.year}-${_two(now.month)}-${_two(now.day)} '
            "${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}:\n"
            '${redactWithSavedConfig(tb)}');
        results.add(JobResult(name: entry.key, ok: false, error: tb));
      }
    }
    final now = clock.now();
    _history.addAll(results);
    if (_history.length > 50) {
      _history.removeRange(0, _history.length - 50);
    }
    if (advanceTimer) {
      if (results.isEmpty || results.every((r) => r.ok)) {
        lastRun = now;
      } else {
        // A failed run must not delay the retry a full interval:
        // come back in ~5 minutes instead (manual runs never
        // touch the timer at all — see [runNow]).
        lastRun = now
            .add(const Duration(minutes: 5))
            .subtract(Duration(
                microseconds: (intervalMinutes * 60 * 1000000).round()));
      }
    }
    final callback = onResult;
    if (callback != null) {
      for (final result in results) {
        try {
          callback(result);
        } catch (_) {
          // UI callback issues stay local.
          print(
              'Warning: scheduler result callback failed for ${result.name}');
        }
      }
    }
    return results;
  }

  /// Executes all jobs immediately (used by manual refresh too).
  ///
  /// Never touches the periodic timer, so a manual refresh neither
  /// postpones the next auto run nor masks a failed run's early retry.
  List<JobResult> runNow() => _runAllOnce(advanceTimer: false);

  /// Runs all jobs on the periodic schedule (test seam).
  List<JobResult> runAllOnce({bool advanceTimer = true}) =>
      _runAllOnce(advanceTimer: advanceTimer);

  /// Re-reads the live interval (test seam for the per-tick poll).
  void pollInterval() {
    final provider = intervalProvider;
    if (provider == null) return;
    double? value;
    try {
      value = provider();
    } catch (_) {
      return; // Keep the last good interval.
    }
    if (value != null) intervalMinutes = math.max(1.0, value);
  }

  void start() {
    if (running) return;
    _stopSignal = null;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isPaused()) return;
      pollInterval();
      final now = clock.now();
      if (!now.isBefore(nextDue(lastRun, intervalMinutes, now))) {
        _runAllOnce();
      }
      // No extra sleep: the 5 s tick above already paces the loop,
      // so intervals stay exact and stop() stays responsive.
    });
  }

  /// True once [stop] was called (waits up to [timeout]).
  ///
  /// For jobs that wait on work running elsewhere: they wake up on
  /// shutdown instead of holding the scheduler loop.
  ///
  /// Deviation: Python blocks the calling thread; Dart awaits a future.
  Future<bool> waitStopped(Duration timeout) async {
    if (_timer == null) return true;
    _stopSignal ??= Completer<bool>();
    return _stopSignal!.future.timeout(timeout, onTimeout: () => false);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    // Drop the timer so a later start() actually restarts the loop
    // instead of early-returning on a stale handle.
    _stopSignal?.complete(true);
    _stopSignal = null;
  }

  bool _isPaused() {
    final check = paused;
    if (check == null) return false;
    try {
      return check();
    } catch (_) {
      // A broken check never blocks runs.
      return false;
    }
  }
}
