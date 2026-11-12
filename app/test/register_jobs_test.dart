// Port of the `_register_jobs` cases: tests/test_scheduler.py
// (`test_register_jobs_seeds_from_fresh_cache`,
// `test_register_jobs_empty_cache_refreshes_on_start`) and
// tests/test_wizard_setup.py (`test_scheduler_skips_refresh_while_setup_pending`).
// `registerJobs` builds the one runner the app and the headless wake use.
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/platform/scheduler_jobs.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_jobs_');
    setEnvironmentOverride(
        {'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  AppState makeState() => AppState(data: {})..wizardDismissed = true;

  test('registerJobsSeedsFromFreshCache', () {
    final state = makeState();
    state.data = {'last_updated': _stamp(clock.now().subtract(const Duration(minutes: 10)))};
    final runner = registerJobs(state);
    try {
      expect(runner.lastRun, isNotNull);
      expect(state.schedulerLastRun, runner.lastRun);
      expect(nextDue(runner.lastRun, 60, clock.now()).isAfter(clock.now()), isTrue);
      expect(runner.jobs.keys, ['refresh', 'update']);
    } finally {
      runner.stop();
    }
  });

  test('registerJobsEmptyCacheRefreshesOnStart', () {
    final state = makeState();
    state.data = {};
    final runner = registerJobs(state);
    try {
      expect(runner.lastRun, isNull);
    } finally {
      runner.stop();
    }
  });

  test('schedulerSkipsRefreshWhileSetupPending', () async {
    final state = AppState(data: {});
    final calls = <String>[];
    state.spawn = (job, name) {
      if (name == 'strakalari-refresh') {
        calls.add('all');
        state.refreshRunning = false; // finished at once, no run recorded
      } else {
        state.updateCheckRunning = false;
      }
    };
    final runner = registerJobs(state);
    expect(state.setupPending, isTrue);
    var results = await runner.runNow();
    expect(results[0].name, 'refresh');
    expect(results[0].ok, isTrue);
    expect(results[0].detail, 'skipped (setup not finished)');
    expect(calls, isEmpty);
    // After finishing setup the same scheduler run starts a refresh.
    state.config.data.addAll({
      'bakalari_url': 'https://skola.bakalari.cz',
      'bakalari_username': 'novak',
      'bakalari_password': 'x',
    });
    state.wizardFinished();
    results = await runner.runNow();
    expect(calls, ['all']);
    expect(results[0].detail, 'refresh finished');
  });

  test('aFailedJobIsReportedOnceAndBeatsTheHeartbeat', () async {
    // `_on_result`: heartbeat after every result, the failure hook only
    // for failures the job did not report itself.
    final state = makeState();
    final runner = registerJobs(state);
    runner.addJob('refresh', () => throw StateError('boom'));
    runner.addJob('update', () => throw const JobFailed('already told'));
    final before = state.logLines.length;
    final results = await runner.runNow();
    expect(results.map((r) => r.ok), [false, false]);
    expect(state.schedulerLastRun, isNotNull);
    final logged = state.logLines.sublist(before).join('\n');
    expect(logged, contains('refresh'));
    expect(logged, isNot(contains('already told')));
  });
}
