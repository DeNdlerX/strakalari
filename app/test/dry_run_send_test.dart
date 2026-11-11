import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_timetable_cache_merge.py::TestDryRunNeverMarksExcused`
/// (the two send-path cases; `test_excuse_single_dry_run_fills_only` is the
/// core case `excuseDryRunFillsWithoutSubmitting` in automation_test.dart).
class _DryApp extends Strakalari {
  @override
  String get excuseMode => 'dry_run';

  @override
  Future<String> sendExcuseOutcome(
          Map<String, Object?> excuse, [String? customText]) async =>
      'dry_run';

  @override
  void close() {}
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_dry_run_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': dir.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  AppState dryState() => AppState(
        configData: {
          'bakalari_url': 'https://b.example.cz',
          'bakalari_username': 'u',
          'bakalari_password': 'p',
        },
        data: {
          'timetable': {
            '18.09.2026': [
              for (final n in [1, 2])
                {
                  'subject': 'M$n',
                  'teacher': 'T',
                  'time': '$n (8:00 - 8:45)',
                  'absenceType': 'Absent',
                },
            ],
          },
          'sent_excuses_from': '2026-09-01',
        },
      )..demoMode = false;

  test('submitExcuseDryRunLeavesPending', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () async {
      final st = dryState();
      final jobs = <Future<void> Function()>[];
      st.createApp = ({onLog, configData}) => _DryApp();
      st.spawn = (job, name) => jobs.add(job);
      final task = st.excuseTasks().first;
      expect(st.submitExcuse(task, 'text'), isTrue);
      await jobs.single();
      expect(st.excuseLog, isEmpty);
      expect(st.lastSnackMessage, Strings.get('excuse_dry_run'));
    });
  });

  test('submitDayExcuseDryRunLeavesPending', () async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () async {
      final st = dryState();
      final jobs = <Future<void> Function()>[];
      st.createApp = ({onLog, configData}) => _DryApp();
      st.spawn = (job, name) => jobs.add(job);
      expect(st.submitDayExcuse('2026-09-18', 'text'), isTrue);
      await jobs.single();
      expect(st.excuseLog, isEmpty);
      expect(st.lastSnackMessage, Strings.get('excuse_dry_run'));
    });
  });
}
