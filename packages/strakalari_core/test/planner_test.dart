// Port of tests/test_year_planner.py (engine cases) and the portable
// case of tests/test_plan_reserve.py (reserve validation).
//
// Not ported here:
// - tests/test_plan_picker.py (12 cases): drives the Flet planner dialog
//   (`flet_ui.views.planner`); the subject only exists in the Flutter app
//   (migration phase 6).
// - test_year_planner AppState/view cases (plan_days batching, year-plan
//   caching, first_plannable_day, planner_target, view builds): need
//   AppState (automation/state phase) and Flet views.
// - test_plan_reserve forecast cases (forecast_subject/forecast_all):
//   need forecast.dart (phase 3).
import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/planning/planner.dart';
import 'package:strakalari_core/src/storage/config.dart';

// Mon: M M F | Tue: M F | Wed: F | Thu: M | Fri: F F
final Map<Object?, Object?> template = {
  (0, 1): {'subject': 'M'},
  (0, 2): {'subject': 'M'},
  (0, 3): {'subject': 'F'},
  (1, 1): {'subject': 'M'},
  (1, 2): {'subject': 'F'},
  (2, 1): {'subject': 'F'},
  (3, 1): {'subject': 'M'},
  (4, 1): {'subject': 'F'},
  (4, 2): {'subject': 'F'},
};

// One concrete day so the planner has a "timetable" at all.
final Map<Object?, Object?> timetable = {
  '07.09.2026': [
    {'subject': 'M', 'time': '1 (8:00 - 8:45)'}
  ],
};

List<SubjectState> states(
        {double mPct = 0.0,
        double fPct = 0.0,
        double mTaught = 0.0,
        double fTaught = 0.0,
        double limit = 25.0}) =>
    [
      SubjectState(
          name: 'M',
          currentPct: mPct,
          limitPct: limit,
          weeklyHours: 5,
          taughtHours: mTaught),
      SubjectState(
          name: 'F',
          currentPct: fPct,
          limitPct: limit,
          weeklyHours: 6,
          taughtHours: fTaught),
    ];

int dayDiff(DateTime a, DateTime b) => DateTime.utc(a.year, a.month, a.day)
    .difference(DateTime.utc(b.year, b.month, b.day))
    .inDays;

DateTime addDays(DateTime day, int n) =>
    DateTime(day.year, day.month, day.day + n);

YearPlan plan(
        {DateTime? today,
        List<Map<String, Object?>>? planned,
        Set<DateTime>? holidays,
        List<SubjectState>? stateList,
        int targetDays = 0}) =>
    buildYearPlan(
      stateList ?? states(),
      timetable: timetable,
      stableBaseline: template,
      holidays: holidays,
      planned: planned ?? const [],
      today: today ?? DateTime(2026, 9, 21),
      sem1Close: '25.01.2027',
      sem2Close: '30.06.2027',
      targetDays: targetDays,
    );

void main() {
  group('terms', () {
    test('coverBothSemestersUntilClosure', () {
      expect(
          schoolYearTerms(DateTime(2026, 10, 1),
              sem1Close: '25.01.2027', sem2Close: '26.04.2027'),
          [('sem1', DateTime(2026, 9, 1), DateTime(2027, 1, 25)),
           ('sem2', DateTime(2027, 2, 1), DateTime(2027, 4, 26))]);
    });

    test('nextSemesterStartsFresh', () {
      final yearPlan =
          plan(stateList: states(mPct: 20.0, mTaught: 15.0));
      final sem1 = yearPlan.term('sem1')!;
      final sem2 = yearPlan.term('sem2')!;
      expect(sem1.active, isTrue);
      expect(sem1.hasData, isTrue);
      expect(sem2.active, isFalse);
      expect(sem2.hasData, isFalse);
      expect(sem1.budgetByCanon['m']!.missed, equals(3.0));
      expect(sem2.budgetByCanon['m']!.missed, equals(0.0));
      expect(sem2.capacity, greaterThan(0));
      expect(sem2.recommended, isNotEmpty);
    });

    test('afterFirstClosureThePlannerMovesToSemesterTwo', () {
      final yearPlan = plan(today: DateTime(2027, 1, 27));
      expect([for (final t in yearPlan.terms) t.key], ['sem2']);
      expect(yearPlan.defaultTerm!.key, 'sem2');
      expect(yearPlan.defaultTerm!.hasData, isFalse);
    });
  });

  group('lessonSource', () {
    test('cancelledLessonsCostNoBudget', () {
      final source = LessonSource({
        '5.10.2099': [
          {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)'},
          {
            'subject': 'Fyzika',
            'time': '2 (8:55 - 9:40)',
            'status': 'cancelled'
          },
        ]
      });
      expect(
          [
            for (final l in source.lessons(DateTime(2099, 10, 5))!)
              l.subject
          ],
          ['Matematika']);
    });

    test('concreteWeekWinsOverTheTemplate', () {
      // Baseline built from a stable week (Monday: M, Tuesday: F),
      // mirroring schedule.baseline_from_stable_timetable.
      final baseline = {
        (0, 1): {'subject': 'M'},
        (1, 1): {'subject': 'F'},
      };

      Map<String, Object?> lesson(String subject, int period,
          [String notice = '']) {
        final row = <String, Object?>{
          'subject': subject,
          'teacher': 'T',
          'room': 'R',
          'time': '$period (8:00 - 8:45)',
        };
        if (notice.isNotEmpty) row['notice'] = notice;
        return row;
      }

      final fetched = {
        '31.08.2026': [lesson('M', 1), lesson('X', 2)],
        '07.09.2026': [lesson('M', 1), lesson('X', 2)],
        // Fetched week with a substitution: a 3rd lesson on Monday.
        '14.09.2026': [
          lesson('M', 1),
          lesson('X', 2),
          {...lesson('G', 3), 'notice': 'Suplování'}
        ],
        // Known-but-empty concrete day: no school at all.
        '28.09.2026': <Map<String, Object?>>[],
      };
      final source = LessonSource(fetched, baseline);

      List<String> subjects(DateTime day) {
        final got = source.lessons(day)!;
        return [for (final l in got) l.subject]..sort();
      }

      // Concrete day: exactly its lessons, the change included.
      expect(subjects(DateTime(2026, 9, 14)), ['G', 'M', 'X']);
      // Far-future day with no fetched week: the template.
      expect(subjects(DateTime(2026, 9, 21)), ['M']);
      expect(subjects(DateTime(2026, 9, 28)), isEmpty);
      // Without a baseline the concrete day still wins.
      expect(
          [
            for (final l in LessonSource(fetched)
                .lessons(DateTime(2026, 9, 14))!)
              l.subject
          ]..sort(),
          ['G', 'M', 'X']);
    });
  });

  group('budgets', () {
    test('futureHoursAreCountedDayByDay', () {
      final base = plan();
      final thursdays = {
        for (var i = 0; i < 20; i++) addDays(DateTime(2026, 9, 21), 3 + 7 * i)
      };
      final holed = plan(holidays: thursdays);
      final m0 = base.term('sem1')!.budgetByCanon['m']!;
      final m1 = holed.term('sem1')!.budgetByCanon['m']!;
      final f0 = base.term('sem1')!.budgetByCanon['f']!;
      final f1 = holed.term('sem1')!.budgetByCanon['f']!;
      expect(m1.future, lessThan(m0.future));
      expect(f1.future, equals(f0.future));
    });

    test('plannedDaysReduceTheBudgetAndCapacity', () {
      final free = plan();
      final withPlanned = plan(planned: [
        {'start_date': '2026-10-05', 'end_date': '2026-10-05'}
      ]);
      final b0 = free.term('sem1')!.budgetByCanon['m']!;
      final b1 = withPlanned.term('sem1')!.budgetByCanon['m']!;
      expect(b1.planned, equals(2)); // Monday holds two M lessons
      expect(b1.free, equals(b0.free - 2));
      expect(withPlanned.term('sem1')!.capacity,
          lessThan(free.term('sem1')!.capacity));
      expect(
          withPlanned.term('sem1')!.options.containsKey(DateTime(2026, 10, 5)),
          isFalse);
    });

    test('partialPlannedDayCountsOnlyItsPeriods', () {
      final source = LessonSource(timetable, template);
      final entry = {
        'start_date': '2026-10-05',
        'end_date': '2026-10-05',
        'start_period': 3,
        'end_period': 3,
      };
      final lessons = entryLessons(entry, source, {});
      expect(
          [for (final l in lessons[DateTime(2026, 10, 5)]!) l.subject],
          ['F']);
    });

    test('illnessBufferCoversOnlyLessonsStillAhead', () {
      final early = plan(today: DateTime(2026, 9, 21))
          .term('sem1')!
          .budgetByCanon['m']!;
      final late = plan(
              today: DateTime(2027, 1, 4),
              stateList: states(mTaught: 60.0, fTaught: 70.0))
          .term('sem1')!
          .budgetByCanon['m']!;
      expect(early.buffer, equals(early.future * 0.10));
      expect(late.buffer, lessThan(early.buffer));
      // Nothing missed so far: late in the term more of the limit is free.
      expect(late.free / late.total, greaterThan(early.free / early.total));
    });

    test('blockedDaysAreNeverRecommended', () {
      // Late in the term with M at 30 % of taught lessons: no day holding
      // M fits any more (the few remaining lessons only dilute a little).
      final yearPlan = plan(
          today: DateTime(2027, 1, 4),
          stateList: states(mPct: 30.0, mTaught: 60.0));
      final term = yearPlan.term('sem1')!;
      expect(term.budgetByCanon['m']!.free, lessThan(1));
      expect(
          term.recommended.every((o) => !o.cost.containsKey('m')), isTrue);
      expect(term.options.values.any((o) => !o.feasible), isTrue);
    });
  });

  group('recommendation', () {
    test('planIsSpreadOverTheWholeTerm', () {
      final term = plan(targetDays: 6).term('sem1')!;
      final days = [for (final o in term.recommended) o.day];
      expect(days.length, equals(6));
      final span = dayDiff(DateTime(2027, 1, 25), DateTime(2026, 9, 21));
      // Not front-loaded: the picks reach the last third of the term ...
      expect(
          days.last,
          isNot(days.last
              .isBefore(addDays(DateTime(2026, 9, 21), span * 2 ~/ 3))));
      // ... and never cluster: no two picks within one school week.
      var minGap = 1 << 30;
      for (var i = 0; i + 1 < days.length; i++) {
        final gap = dayDiff(days[i + 1], days[i]);
        if (gap < minGap) minGap = gap;
      }
      expect(minGap, greaterThanOrEqualTo(7));
    });

    test('finalWeekAvoidedWhenOtherDaysExist', () {
      final term = plan().term('sem1')!;
      final finalDays =
          term.schoolDays.sublist(term.schoolDays.length - finalWeekDays).toSet();
      expect(term.recommended, isNotEmpty);
      expect(
          finalDays.intersection(
              {for (final o in term.recommended) o.day}),
          isEmpty);
    });

    test('targetCountsAlreadyPlannedDays', () {
      final term = plan(planned: [
        {'start_date': '2026-10-07', 'end_date': '2026-10-07'}
      ], targetDays: 3)
          .term('sem1')!;
      expect(term.recommended.length, equals(2));
      expect(term.target, equals(3));
    });

    test('bridgeDayBeforeAHolidayMonday', () {
      final term = plan(holidays: {DateTime(2026, 9, 28)}).term('sem1')!;
      final friday = term.options[DateTime(2026, 9, 25)]!;
      expect(friday.streak, equals(4));
      expect(friday.tags, contains('bridge'));
      final mondayAfter = term.options[DateTime(2026, 10, 5)]!;
      expect(mondayAfter.tags, contains('long_weekend'));
    });

    test('planVariesWeekdays', () {
      final term = plan().term('sem1')!;
      final weekdays = {for (final o in term.recommended) o.day.weekday};
      expect(weekdays.length, greaterThanOrEqualTo(2));
    });
  });

  group('impact', () {
    test('impactLevels', () {
      final yearPlan =
          plan(stateList: states(mPct: 20.0, mTaught: 20.0));
      final term = yearPlan.term('sem1')!;
      final m = term.budgetByCanon['m']!;
      // A range long enough to blow the school limit for M.
      final impacts = yearPlan.impactOfEntry({
        'start_date': '2026-10-05',
        'end_date': '2026-11-27',
      });
      final rows = {for (final r in impacts[0].$2) r.name: r};
      expect(rows['M']!.level, equals('over'));
      expect(rows['M']!.cost, greaterThan(m.schoolLeft));
      // One Wednesday (F only) is fine.
      final calm = yearPlan.impactOfEntry({
        'start_date': '2026-10-07',
        'end_date': '2026-10-07',
      });
      expect([for (final r in calm[0].$2) r.level], ['ok']);
    });

    test('plannedEntryOverLimitIsFlagged', () {
      final yearPlan = plan(
          stateList: states(mPct: 20.0, mTaught: 20.0),
          planned: [
            {'start_date': '2026-10-05', 'end_date': '2026-11-06'}
          ]);
      final term = yearPlan.term('sem1')!;
      expect(term.planned, isNotEmpty);
      expect(term.planned[0].over, contains('m'));
      expect(term.budgetByCanon['m']!.status, equals('over'));
    });
  });

  test('noStatesNoPlan', () {
    final yearPlan = buildYearPlan([],
        timetable: timetable,
        stableBaseline: template,
        today: DateTime(2026, 9, 21));
    expect(yearPlan.terms, isEmpty);
  });

  group('reserve', () {
    // From tests/test_plan_reserve.py: the planning reserve lowers the
    // plan limit (`reserve_pct` validation in config); the school truth
    // is untouched. The forecast_subject/forecast_all cases need
    // forecast.dart (phase 3) and are not ported here.
    Map<String, Object?> base() => defaultConfig();

    test('reserveValidation', () {
      expect(
          validateConfig(base()..['absence_plan_reserve_pct'] = 10.0)
              .where((p) => p.contains('reserve')),
          isEmpty);
      final bad = validateConfig(base()..['absence_plan_reserve_pct'] = -1);
      expect(bad.any((p) => p.contains('reserve')), isTrue);
      final bad2 =
          validateConfig(base()..['absence_plan_reserve_pct'] = 'lots');
      expect(bad2.any((p) => p.contains('reserve')), isTrue);
    });
  });
}
