import 'package:app/features/timetable/timetable_controller.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_early_leave.py` (13 cases).
Map<String, Object?> _lesson({
  String absType = '',
  String absText = '',
  String period = '1',
}) =>
    {
      'teacher': 'T1',
      'subject': 'M',
      'time': period,
      'absenceType': absType,
      'absencetext': absText,
    };

String _status(Map<String, Object?> raw) =>
    lessonStatusFromLegacy(raw).$1;

void main() {
  group('TestSoonDetection', () {
    test('absentSoonYieldsSoonExcuse', () {
      final raw = {
        '10.09.2026': [_lesson(absType: 'AbsentSoon', absText: 'AbsentSoon')]
      };
      final excuses = Strakalari.generateExcuses(
        raw,
        delayDays: 1,
        overrideToday: DateTime(2026, 9, 15),
      );
      expect(excuses, hasLength(1));
      expect(excuses[0]['type'], 'soon');
      expect(excuses[0]['starting_lesson'], 1);
      expect(excuses[0]['ending_lesson'], 1);
    });

    test('brzkyOdchodVariants', () {
      for (final text in ['Brzký odchod', 'Brzky odchod']) {
        final raw = {
          '10.09.2026': [_lesson(absType: text, absText: text)]
        };
        final excuses = Strakalari.generateExcuses(
          raw,
          delayDays: 1,
          overrideToday: DateTime(2026, 9, 15),
        );
        expect(
          excuses,
          [
            {
              'type': 'soon',
              'starting_day': '10.09.2026',
              'ending_day': '10.09.2026',
              'starting_lesson': 1,
              'ending_lesson': 1,
            }
          ],
          reason: text,
        );
      }
    });

    test('lateStillYieldsIncome', () {
      final raw = {
        '10.09.2026': [
          _lesson(absType: 'AbsentLate', absText: 'Pozdní příchod')
        ]
      };
      final excuses = Strakalari.generateExcuses(
        raw,
        delayDays: 1,
        overrideToday: DateTime(2026, 9, 15),
      );
      expect([for (final e in excuses) e['type']], ['income']);
    });

    test('soonDoesNotMergeIntoFullDay', () {
      final raw = {
        '10.09.2026': [
          _lesson(absType: 'AbsentSoon', absText: 'Brzký odchod', period: '1'),
          _lesson(absType: 'Absent', absText: 'Absence', period: '2'),
        ]
      };
      final excuses = Strakalari.generateExcuses(
        raw,
        delayDays: 1,
        overrideToday: DateTime(2026, 9, 15),
      );
      final byType = [for (final e in excuses) e['type']]..sort();
      expect(byType, ['days and hours', 'soon']);
    });
  });

  group('TestSoonStatus', () {
    test('absentSoonIsSoonNotAbsent', () {
      expect(_status({'absenceType': 'AbsentSoon'}), 'soon');
      expect(_status({'absencetext': 'AbsentSoon'}), 'soon');
    });

    test('brzkyOdchodIsSoon', () {
      expect(_status({'absencetext': 'Brzký odchod'}), 'soon');
      expect(_status({'absenceType': 'Brzky odchod'}), 'soon');
    });

    test('genericEarlyUnchanged', () {
      expect(_status({'absencetext': 'Předčasný odchod'}), 'early');
      expect(_status({'absenceType': 'AbsentEarly'}), 'early');
    });

    test('excusedSoonStaysExcused', () {
      expect(
        _status({'absenceType': 'AbsentSoon', 'absencetext': 'Omluveno'}),
        'excused',
      );
    });

    test('soonTaskKind', () {
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
      final tasks = excuseTasksFromLessons(lessonsFromTimetable(timetable));
      expect(tasks, hasLength(1));
      expect(tasks[0].kind, 'soon');
    });

    test('soonBadgeKindIsLateColor', () {
      final c = TimetableController();
      final look = c.look({
        'subject': 'M',
        'teacher': 'T',
        'time': '1 (8:00 - 8:45)',
        'absenceType': 'AbsentSoon',
      }, DateTime(2026, 9, 10));
      expect(look.bar, 'late');
    });
  });

  group('TestSoonTemplates', () {
    test('configDefaults', () {
      final soonTpls = canonicalDefaults['left_soon_excuses'] as List<Object?>?;
      expect(soonTpls, isNotNull);
      expect(soonTpls!.length, greaterThanOrEqualTo(1));
    });

    test('plannerTemplatesForSoon', () {
      final c = TodayController(
        config: {
          'left_soon_excuses': ['SOON-TPL'],
          'late_income_excuses': ['LATE-TPL'],
          'short_absence_excuses': ['SHORT-TPL'],
          'long_absence_excuses': ['LONG-TPL'],
          'your_signature': '',
        },
      );
      expect([for (final o in c.templateOptions('soon')) o.text], ['SOON-TPL']);
      expect([for (final o in c.templateOptions('late')) o.text], ['LATE-TPL']);
    });

    test('webHourExcuseDedupesSoon', () {
      final detail = {
        'Kind': 'OMLUVENKA',
        'DateFrom': '10.9.2026',
        'DateTo': '10.9.2026',
        'TimeFrom': '08:55',
        'TimeTo': '09:40',
        'HourFrom': {'Caption': '2'},
        'HourTo': {'Caption': '2'},
      };
      final result = sentExcuseEntries(detail);
      expect(
        result.any((e) =>
            e['type'] == 'soon' &&
            e['starting_day'] == '10.09.2026' &&
            e['ending_day'] == '10.09.2026' &&
            e['starting_lesson'] == 2 &&
            e['ending_lesson'] == 2),
        isTrue,
      );
    });
  });
}
