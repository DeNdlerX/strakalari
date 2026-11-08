import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/planning/forecast.dart'
    as fc;

DateTime day(String iso) => DateTime.parse(iso);

Map<String, List<Map<String, Object?>>> timetableWith(
    String dayKey, List<String> subjects) {
  return {
    dayKey: [
      for (final s in subjects)
        {'subject': s},
    ],
  };
}

void main() {
  group('weeklyHoursPerSubject', () {
    test('one-off not floored to one', () {
      final timetable = <String, List<Map<String, Object?>>>{
        for (var d = 1; d <= 10; d++)
          '${'$d'.padLeft(2, '0')}.09.2026': [
            {'subject': 'Common'},
          ],
      };
      timetable['01.09.2026']!.add({'subject': 'Rare'});
      final hours = fc.weeklyHoursPerSubject(timetable);
      expect(hours['Common'], 5);
      expect(hours.containsKey('Rare'), isFalse);
    });

    test('counts the stable week', () {
      final timetable = timetableWith('01.09.2026', ['Matematika', 'Matematika'])
        ..addAll(timetableWith('02.09.2026', ['Fyzika']));
      expect(
        fc.weeklyHoursPerSubject(timetable),
        {'Matematika': 2, 'Fyzika': 1},
      );
    });
  });

  group('warn threshold', () {
    test('explicit warn used', () {
      const state =
          SubjectState(name: 'M', currentPct: 20.0, limitPct: 25.0, warnPct: 22.0);
      expect(state.status, 'ok');
      const state2 =
          SubjectState(name: 'M', currentPct: 20.0, limitPct: 25.0, warnPct: 18.0);
      expect(state2.status, 'warning');
    });

    test('fallback stays sixty percent', () {
      const ok =
          SubjectState(name: 'M', currentPct: 14.0, limitPct: 25.0);
      expect(ok.status, 'ok');
      const warn =
          SubjectState(name: 'M', currentPct: 16.0, limitPct: 25.0);
      expect(warn.status, 'warning');
    });

    test('forecast passes warn through', () {
      final (states, _) = fc.forecastAll(
        absence: {'M': 20.0},
        timetable: {},
        today: day('2026-09-07'),
        warnPct: 22.0,
      );
      expect(states, isNotEmpty);
      expect(states.first.warnPct, 22.0);
      expect(states.first.status, 'ok');
    });
  });

  group('school days and semesters', () {
    test('school days skip weekends and holidays', () {
      final days = fc.schoolDaysBetween(
        day('2026-09-07'),
        day('2026-09-13'),
        {day('2026-09-08')},
      );
      // Mon, Wed-Fri (Tue holiday).
      expect([for (final d in days) d.weekday], [1, 3, 4, 5]);
    });

    test('semester bounds follow the Czech school year', () {
      final (first, last) = fc.semesterBounds(day('2026-09-07'));
      expect(first, day('2026-09-01'));
      expect(last, day('2027-01-31'));
      final (first2, last2) = fc.semesterBounds(day('2026-03-07'));
      expect(first2, day('2026-02-01'));
      expect(last2, day('2026-06-30'));
    });
  });

  group('forecastSubject', () {
    test('math projects below the current rate when attending', () {
      final state = fc.forecastSubject(
        currentPct: 10.0,
        weeklyHours: 4,
        schoolDaysLeft: 50,
        schoolDaysTotal: 100,
        limitPct: 30.0,
      );
      expect(state.safeHoursLeft, greaterThan(0));
      expect(state.projectedPct, lessThanOrEqualTo(10.0));
      expect(state.status, isIn(['ok', 'warning']));
    });

    test('taught override beats the estimate', () {
      final estimated = fc.forecastSubject(
        currentPct: 50.0,
        weeklyHours: 4,
        schoolDaysLeft: 100,
        schoolDaysTotal: 150,
        limitPct: 25.0,
      );
      final exact = fc.forecastSubject(
        currentPct: 50.0,
        weeklyHours: 4,
        schoolDaysLeft: 100,
        schoolDaysTotal: 150,
        limitPct: 25.0,
        taughtHours: 8.0,
      );
      // 50% of 8 taught = 4 missed vs 50% of the ~100-day estimate.
      expect(exact.safeHoursLeft, greaterThan(estimated.safeHoursLeft));
    });
  });

  group('forecastAll', () {
    test('uses per-subject limits', () {
      final (states, days) = fc.forecastAll(
        absence: {'Matematika': 20.0, 'Zeměpis': 20.0},
        timetable: timetableWith('01.09.2026', ['Matematika', 'Zeměpis']),
        subjectLimits: {'matematika': 30.0, 'zeměpis': 20.0},
        today: day('2026-09-07'),
      );
      final byName = {for (final s in states) s.name: s};
      expect(byName['Matematika']!.limitPct, 30.0);
      expect(byName['Zeměpis']!.limitPct, 20.0);
      // Same current %, higher limit -> more hours left.
      expect(
        byName['Matematika']!.safeHoursLeft,
        greaterThanOrEqualTo(byName['Zeměpis']!.safeHoursLeft),
      );
      expect(days, isNotEmpty);
    });

    test('non-stable absence subjects are free', () {
      final timetable = timetableWith('01.09.2026', ['M'])
        ..addAll(timetableWith('08.09.2026', ['M']));
      final (states, _) = fc.forecastAll(
        absence: {'M': 10.0, 'OneOff': 50.0},
        timetable: timetable,
        today: day('2026-09-07'),
        // Serialized stable baseline shape: one slot per (weekday, period).
        stableBaseline: {
          'mon|1': {'subject': 'M'},
        },
      );
      // OneOff: free, unbudgeted.
      expect({for (final s in states) s.name}, {'M'});
    });

    test('tracked set drops homeroom but null disables the filter', () {
      Map<String, List<Map<String, Object?>>> timetable() => {
            '07.09.2026': [
              {
                'subject': 'Matematika',
                'teacher': 'T',
                'room': 'R',
                'time': '1 (8:00 - 8:45)',
              },
              {
                'subject': 'Třídnická hodina',
                'teacher': 'T',
                'room': 'R',
                'time': '2 (8:55 - 9:40)',
              },
            ],
          };
      final absence = {'Matematika': 10.0, 'Třídnická hodina': 50.0};
      final (filtered, _) = fc.forecastAll(
        absence: absence,
        timetable: timetable(),
        today: day('2026-09-07'),
        trackedSubjects: {'Matematika', 'Anglický jazyk'},
      );
      expect({for (final s in filtered) s.name}, {'Matematika'});
      // Unknown directory (null): no filtering at all.
      final (unfiltered, _) = fc.forecastAll(
        absence: absence,
        timetable: timetable(),
        today: day('2026-09-07'),
      );
      expect(
        {for (final s in unfiltered) s.name},
        {'Matematika', 'Třídnická hodina'},
      );
    });

    test('school badges escalate status', () {
      Map<String, List<Map<String, Object?>>> timetable() =>
          timetableWith('07.09.2026', ['Matematika']);
      Map<String, Object?> details({required bool approaching}) => {
            'Matematika': {
              'percent': 5.0,
              'total_hours': 8.0,
              'missed_hours': 0.0,
              'approaching': approaching,
              'unclassifiable': false,
            },
          };
      final (warned, _) = fc.forecastAll(
        absence: {'Matematika': 5.0},
        timetable: timetable(),
        today: day('2026-09-07'),
        absenceDetails: details(approaching: true),
      );
      expect(warned.first.status, 'warning');
      final (critical, _) = fc.forecastAll(
        absence: {'Matematika': 5.0},
        timetable: timetable(),
        today: day('2026-09-07'),
        absenceDetails: {
          'Matematika': {
            ...details(approaching: false)['Matematika']!
                as Map<String, Object?>,
            'unclassifiable': true,
          },
        },
      );
      expect(critical.first.status, 'critical');
      expect(critical.first.planStatus, 'critical');
    });

    test('taught hours override beats the estimate', () {
      Map<String, List<Map<String, Object?>>> timetable() =>
          timetableWith('07.09.2026', ['Matematika']);
      final (plain, _) = fc.forecastAll(
        absence: {'Matematika': 50.0},
        timetable: timetable(),
        today: day('2026-09-07'),
      );
      expect(plain, isNotEmpty);
      expect(plain.first.taughtHours, 0.0);
      final (exact, _) = fc.forecastAll(
        absence: {'Matematika': 50.0},
        timetable: timetable(),
        today: day('2026-09-07'),
        absenceDetails: {
          'Matematika': {
            'percent': 50.0,
            'total_hours': 8.0,
            'missed_hours': 4.0,
            'approaching': false,
            'unclassifiable': false,
          },
        },
      );
      expect(exact.first.taughtHours, 8.0);
      // Real elapsed hours (8) beat the calendar estimate,
      // so the budget differs.
      expect(exact.first.safeHoursLeft, isNot(plain.first.safeHoursLeft));
    });
  });

  group('canonSubject', () {
    test('collapses nbsp and case', () {
      expect(
        fc.canonSubject('Seminář z matematiky S'),
        fc.canonSubject('Seminář z matematiky S'),
      );
      expect(fc.canonSubject('Seminář z matematiky S'),
          'seminář z matematiky s');
      expect(fc.canonSubject('  M  '), 'm');
    });
  });

  group('SubjectState defaults', () {
    test('keep old behavior', () {
      const state = SubjectState(name: 'M', currentPct: 5.0, limitPct: 25.0);
      expect(state.status, 'ok');
      expect(state.planStatus, 'ok');
      expect(state.approaching, isFalse);
      expect(state.unclassifiable, isFalse);
      expect(state.taughtHours, 0.0);
    });
  });
}
