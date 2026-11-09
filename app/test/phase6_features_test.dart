import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/widgets/app_widgets.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('phase6_features_test_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    allowMissingKeyStoreForTesting = true;
    clearKeyCache();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    allowMissingKeyStoreForTesting = false;
    clearKeyCache();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('test_early_leave (AppState & models)', () {
    test('soon badge kind is late color', () {
      expect(lessonKind('soon'), 'late');
      expect(lessonKind('early'), 'late');
      expect(lessonKind('late'), 'late');
    });

    test('soon task kind and lesson status', () {
      final raw = {
        'absenceType': 'AbsentSoon',
        'absencetext': 'Brzký odchod',
      };
      final status = lessonStatusFromLegacy(raw);
      expect(status.$1, 'soon');

      final timetable = {
        '10.09.2026': [
          {
            'subject': 'M',
            'teacher': 'T',
            'time': '1 (8:00-8:45)',
            'absenceType': 'AbsentSoon',
            'absencetext': 'Brzký odchod',
          }
        ]
      };
      final lessons = lessonsFromTimetable(timetable);
      final tasks = excuseTasksFromLessons(lessons);
      expect(tasks, hasLength(1));
      expect(tasks.first.kind, 'soon');
    });

    test('absent soon yields soon excuse and does not merge into full day', () {
      final raw = {
        '10.09.2026': [
          {
            'teacher': 'T1',
            'subject': 'M',
            'time': '1',
            'absenceType': 'AbsentSoon',
            'absencetext': 'Brzký odchod',
          },
          {
            'teacher': 'T1',
            'subject': 'F',
            'time': '2',
            'absenceType': 'Absent',
            'absencetext': 'Absence',
          },
        ]
      };
      final excuses = Strakalari.generateExcuses(
        raw,
        delayDays: 1,
        overrideToday: DateTime(2026, 9, 15),
      );
      final types = [for (final e in excuses) e['type']]..sort();
      expect(types, ['days and hours', 'soon']);
    });
  });

  group('test_timetable_week_nav (AppState)', () {
    test('week switch emits once and clears stable view', () {
      final state = AppState();
      state.timetableMondayIso = '2026-09-07';
      state.showStableTimetable = true;
      var count = 0;
      state.onChanged = () => count++;

      state.goTimetableWeek('2026-09-14');
      expect(count, 1);
      expect(state.timetableMondayIso, '2026-09-14');
      expect(state.showStableTimetable, isFalse);
    });

    test('week switch noop emits nothing', () {
      final state = AppState();
      state.timetableMondayIso = '2026-09-14';
      state.showStableTimetable = false;
      var count = 0;
      state.onChanged = () => count++;

      state.goTimetableWeek('2026-09-14');
      state.setShowStable(false);
      expect(count, 0);
    });
  });

  group('test_marks_view (AppState)', () {
    test('predictor state add edit remove restore reset', () {
      final state = AppState(data: {
        'grades': {
          'Fyzika': [
            {'Grade': '3', 'Weight': 5, 'Date': '06.09.2026'},
          ],
        },
      });
      state.demoMode = false;

      expect(state.predictAdd('Fyzika', 'abc', 1), isFalse);
      expect(state.predictAdd('Fyzika', '1', 0), isFalse);
      expect(state.predictAdd('Fyzika', '2', 2.5), isTrue);
      expect(state.marksPredictions['Fyzika']?['added'], [
        {'Grade': '2', 'Weight': 2.5}
      ]);

      expect(state.predictEdit('Fyzika', 'add:0', '1', 5), isTrue);
      expect(state.marksPredictions['Fyzika']?['added'], [
        {'Grade': '1', 'Weight': 5.0}
      ]);

      final fyzSummary =
          state.marksSummaries().firstWhere((s) => s.name == 'Fyzika');
      final key = fyzSummary.rows.firstWhere((r) => r.state == 'real').key;

      state.predictRemove('Fyzika', key);
      final updatedFyz =
          state.marksSummaries().firstWhere((s) => s.name == 'Fyzika');
      expect(updatedFyz.average, 3.0);
      expect(updatedFyz.predicted, 1.0);

      state.predictRestore('Fyzika', key);
      state.predictRemove('Fyzika', 'add:0');
      expect(state.marksPredictions.containsKey('Fyzika'), isFalse);

      state.predictAdd('Fyzika', '1', 1);
      state.predictReset();
      expect(state.marksPredictions, isEmpty);
    });

    test('scale preferences and preset bands', () {
      final state = AppState();
      expect(state.setMarksScale('percent'), isTrue);
      expect(state.marksScale(), 'percent');
      expect(state.marksSubjectScales(), isEmpty);
      expect(state.setMarksScale('bogus'), isFalse);

      state.setSubjectScale('Fyzika', 'grade');
      expect(state.marksSubjectScales(), {'Fyzika': 'grade'});

      expect(state.setMarksBands([90, 95, 50, 30]), isFalse);
      expect(state.setMarksBands([85, 70, 50, 30]), isTrue);
      expect(state.marksBands(), [85.0, 70.0, 50.0, 30.0]);
      expect(state.setMarksBands(null), isTrue);

      state.config.data['school_preset_id'] = 'gekom_2026_2027';
      final (bands, source) = state.marksBandsSource();
      expect(bands, [87.0, 72.0, 55.0, 40.0]);
      expect(source, 'preset');
    });

    test('selecting the open subject closes it', () {
      final state = AppState();
      state.selectMarksSubject('Fyzika');
      expect(state.marksSelected, 'Fyzika');
      state.selectMarksSubject('Fyzika');
      expect(state.marksSelected, isNull);
    });

    test('saving an unchanged mark is not an edit', () {
      final state = AppState(data: {
        'grades': {
          'Fyzika': [
            {'Grade': '3', 'Weight': 5, 'Date': '06.09.2026'},
          ],
        },
      });
      state.demoMode = false;
      final key =
          state.marksSummaries().first.rows.firstWhere((r) => r.state == 'real').key;
      expect(state.predictEdit('Fyzika', key, '3', 5), isTrue);
      expect(state.marksPredictions.containsKey('Fyzika'), isFalse);
      expect(state.predictEdit('Fyzika', key, '2', 5), isTrue);
      expect((state.marksPredictions['Fyzika']?['edits'] as Map?)?[key],
          {'Grade': '2', 'Weight': 5.0});
    });
  });

  group('test_wizard_setup (AppState)', () {
    test('needs setup fresh and dismiss', () {
      final state = AppState();
      expect(state.needsSetup(), isTrue);
      state.dismissWizard();
      expect(state.needsSetup(), isFalse);
    });

    test('wizard step navigation and clamping', () {
      final state = AppState();
      state.wizardGoto(99, 6);
      expect(state.wizardStep, 6); // STEP_DONE
      state.wizardGoto(-3, 6);
      expect(state.wizardStep, 0);
      state.setDraft('wiz:bakalari_username', 'novak');
      state.wizardFinished();
      expect(state.wizardDismissed, isTrue);
      expect(state.drafts.keys.where((k) => k.startsWith('wiz:')), isEmpty);
    });
  });

  group('test_year_planner (AppState)', () {
    void seed(AppState state) {
      final days = <String, List<Map<String, Object?>>>{};
      for (var offset = 0; offset < 5; offset++) {
        final d = DateTime(2026, 9, 21).add(Duration(days: offset));
        final key =
            '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
        days[key] = [
          {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)'},
          {'subject': 'Fyzika', 'time': '2 (8:55 - 9:40)'},
        ];
      }
      state.data = {
        'absence': {'Matematika': 5.0, 'Fyzika': 0.0},
        'timetable': days,
      };
      state.demoMode = false;
    }

    test('planDays batches one save', () {
      final state = AppState();
      seed(state);
      var saves = 0;
      state.config.saveOverride = () => saves++;

      final n = state.planDays(
        ['2026-10-01', '2026-10-08', '2026-10-01', 'bad'],
        'tpl',
        false,
      );
      expect(n, 2);
      expect(saves, 1);
      expect(state.plannedSkips, hasLength(2));
      final plan = state.yearPlan(DateTime(2026, 9, 24, 7, 0));
      expect(plan.defaultTerm!.plannedDates, contains(DateTime(2026, 10, 1)));
    });

    test('year plan is cached until inputs change', () {
      final state = AppState();
      seed(state);
      final now = DateTime(2026, 9, 24, 7, 0);
      final first = state.yearPlan(now);
      expect(identical(state.yearPlan(now), first), isTrue);

      state.planSkip('2026-10-01', 'tpl', false);
      expect(identical(state.yearPlan(now), first), isFalse);
    });

    test('first plannable day is clock aware', () {
      final state = AppState();
      seed(state);
      expect(state.firstPlannableDay(DateTime(2026, 9, 24, 7, 0)),
          DateTime(2026, 9, 24));
      expect(state.firstPlannableDay(DateTime(2026, 9, 24, 12, 0)),
          DateTime(2026, 9, 25));
    });

    test('target days setting limits the plan', () {
      final state = AppState();
      seed(state);
      final now = DateTime(2026, 9, 24, 7, 0);
      expect(state.setPlannerTarget(2), isTrue);
      expect(state.yearPlan(now).defaultTerm!.recommended.length, lessThanOrEqualTo(2));
      expect(state.plannerTargetDays(), 2);
    });
  });
}
