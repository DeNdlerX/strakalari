// DST day-arithmetic regressions (finding A-B1).
//
// Europe/Prague switches on 29.3.2026 (23h day) and 25.10.2026 (25h day).
// `DateTime + Duration(days: n)` on a local midnight lands at 23:00/01:00
// across those switches and breaks midnight comparisons, while Python
// `date + timedelta` stays on the date. Every calendar-day move must go
// through [addDays]/[daysBetween]. Run with `TZ=Europe/Prague` (dart.yml)
// — on a UTC runner the old code passes trivially and the bug hides.
import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/excuse_history.dart';
import 'package:strakalari_core/src/lunches/lunch_cutoff.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

DateTime day(int y, int m, int d) => DateTime(y, m, d);

String dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

Map<String, Object?> absentLesson() => {
      'teacher': 'T',
      'subject': 'M',
      'time': '1 (8:00-8:45)',
      'absenceType': 'Absent',
      'absencetext': 'Absence',
      'notice': '',
    };

void main() {
  group('addDays/daysBetween', () {
    test('springForward', () {
      // 27.3–1.4.2026 window: every step stays a local midnight.
      expect(addDays(day(2026, 3, 30), -2), day(2026, 3, 28));
      expect(addDays(day(2026, 3, 27), 5), day(2026, 4, 1));
      expect(addDays(day(2026, 3, 29), 1), day(2026, 3, 30));
      expect(daysBetween(day(2026, 3, 28), day(2026, 3, 30)), 2);
      expect(daysBetween(day(2026, 3, 27), day(2026, 4, 1)), 5);
    });

    test('autumnBack', () {
      // 23.10–28.10.2026 window.
      expect(addDays(day(2026, 10, 28), -5), day(2026, 10, 23));
      expect(addDays(day(2026, 10, 25), 1), day(2026, 10, 26));
      expect(addDays(day(2026, 10, 19), 14), day(2026, 11, 2));
      expect(daysBetween(day(2026, 10, 23), day(2026, 10, 28)), 5);
    });

    test('weekOffsetFloorsLikePython', () {
      // Python `//` floors; Dart `~/` truncates toward zero.
      expect((daysBetween(day(2026, 10, 26), day(2026, 10, 25)) / 7).floor(),
          -1);
      expect((daysBetween(day(2026, 3, 30), day(2026, 3, 23)) / 7).floor(),
          -1);
      expect((daysBetween(day(2026, 10, 19), day(2026, 10, 26)) / 7).floor(),
          1);
    });
  });

  group('excuseWindow', () {
    test('aprilWindowStartsMarch16', () {
      expect(excuseWindowStart(day(2026, 4, 15)), day(2026, 3, 16));
    });

    test('unconfirmedPureDaysBlockResend', () {
      final excuse = {
        'type': 'pure days',
        'starting_day': '24.10.2026',
        'ending_day': '26.10.2026',
      };
      final pending = [
        unconfirmedEntry({
          'type': 'pure days',
          'starting_day': '26.10.2026',
          'ending_day': '26.10.2026',
        }, DateTime(2026, 10, 26, 12, 0)),
      ];
      expect(unconfirmedBlocks(excuse, pending), isTrue);
    });
  });

  group('generateExcuses', () {
    test('absenceOnSpringSaturdayIsExcused', () {
      final Map<String, Object?> raw = {
        '28.03.2026': [absentLesson()],
      };
      final excuses = generateExcuses(raw,
          delayDays: 2, overrideToday: day(2026, 3, 30));
      expect(excuses, hasLength(1));
      expect(excuses[0]['type'], 'pure days');
      expect(excuses[0]['starting_day'], '28.03.2026');
      expect(excuses[0]['ending_day'], '28.03.2026');
    });
  });

  group('lunchCutoff', () {
    test('previousBusinessDayAcrossSwitches', () {
      expect(previousBusinessDay(day(2026, 3, 31)), day(2026, 3, 30));
      expect(previousBusinessDay(day(2026, 10, 26)), day(2026, 10, 23));
      expect(previousBusinessDay(day(2026, 3, 30)), day(2026, 3, 27));
    });
  });
}
