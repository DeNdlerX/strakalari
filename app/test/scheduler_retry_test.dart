import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of the window-job cases of tests/test_scheduler_retry.py: the
/// scheduler's refresh job (`_register_jobs` → `runner._jobs["refresh"]`)
/// is `AppState.scheduledRefreshJob`. Python monkeypatches
/// `start_refresh`; here the refresh worker is replaced through
/// [AppState.spawn], which `startRefresh` hands its worker to.
void main() {
  late Directory dir;
  late AppState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_sched_');
    setEnvironmentOverride(
        {'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
    state = AppState()
      ..wizardDismissed = true
      ..demoMode = false;
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  /// The refresh "finishes" at once with [run] recorded.
  void finishWith(Map<String, Object?> run) {
    state.spawn = (job, name) {
      state.runs.add(run);
      state.refreshRunning = false;
    };
  }

  /// The refresh never finishes.
  void hang() {
    state.spawn = (job, name) {};
  }

  test('windowJobRaisesWhenRefreshFailed', () async {
    finishWith({'ok': false, 'detail': 'Login failed'});
    await expectLater(state.scheduledRefreshJob(), throwsA(isA<JobFailed>()));
  });

  test('windowJobIgnoresCancelledRunInAnyLanguage', () async {
    // The detail is translated text: only the flag may decide.
    finishWith(
        {'ok': false, 'detail': 'zrušeno uživatelem', 'cancelled': true});
    expect(await state.scheduledRefreshJob(), 'refresh finished');
  });

  test('windowJobStopsWaitingOnShutdown', () async {
    hang();
    var stopped = false;
    Future<void>.delayed(
        const Duration(milliseconds: 200), () => stopped = true);
    expect(await state.scheduledRefreshJob(stopped: () => stopped),
        'refresh still running at shutdown');
  });

  test('windowJobGivesUpOnAHungRefresh', () async {
    hang();
    await expectLater(
        state.scheduledRefreshJob(maxWait: Duration.zero),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('still running'))));
  });
}
