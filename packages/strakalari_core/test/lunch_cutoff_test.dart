// Lunch ordering cutoff: order only until a set time on the previous
// business day.
//
// Port of tests/test_lunch_cutoff.py (pure cases), tests/test_lunch_day_keys.py
// (UI-state cases, not portable yet) and tests/test_lunch_deadline_calendar.py
// (school_presets case, not portable yet).
//
// Cases NOT ported here (their subjects live in other modules):
// - test_gekom_preset_cutoff_defaults_to_noon /
//   test_resolve_lunch_cutoff_user_wins_then_preset -> school_presets port
//   (planning/school_presets.dart), which owns preset_lunch_cutoff and
//   resolve_lunch_cutoff.
// - test_state_rejects_closed_day_and_filters_submit -> lunches controller
//   (phase 5, AppState port).
// - test_lunch_day_keys.py (3 tests) -> AppState/automation ports (phase 4/5):
//   canonical keys in orders, _record_web_orders, _store_ordered.
// - test_unclipped_calendar_keeps_user_days_after_closure -> school_presets
//   port (effective_calendar with clip: false).
import 'package:test/test.dart';

import 'package:strakalari_core/src/lunches/lunch_cutoff.dart';

DateTime day(int year, int month, int d) => DateTime(year, month, d);

DateTime moment(int year, int month, int d, int hour, int minute) =>
    DateTime(year, month, d, hour, minute);

void main() {
  group('parse and validate cutoff', () {
    test('parseCutoffTime', () {
      expect(parseCutoffTime('12:00'), (12, 0));
      expect(parseCutoffTime('9:05'), (9, 5));
      expect(parseCutoffTime(''), (12, 0));
      expect(parseCutoffTime('bogus'), (12, 0));
      expect(parseCutoffTime('25:00'), (12, 0));
    });

    test('normalizeCutoffTime', () {
      expect(normalizeCutoffTime('9:05'), '09:05');
    });

    test('isValidCutoffTime', () {
      expect(isValidCutoffTime(''), isTrue);
      expect(isValidCutoffTime('12:00'), isTrue);
      expect(isValidCutoffTime('9:05'), isTrue);
      expect(isValidCutoffTime('24:00'), isFalse);
      expect(isValidCutoffTime('noon'), isFalse);
    });

    test('dot spelling valid, garbage still invalid', () {
      expect(isValidCutoffTime('12.30'), isTrue);
      expect(parseCutoffTime('12.30'), (12, 30));
      expect(isValidCutoffTime('noon'), isFalse);
      expect(isValidCutoffTime('24.00'), isFalse);
      expect(isValidCutoffTime(''), isTrue);
    });
  });

  group('previous business day', () {
    test('skips weekend', () {
      // Monday lunch -> Friday deadline.
      expect(previousBusinessDay(day(2026, 9, 7)), day(2026, 9, 4));
      // Tuesday lunch -> Monday deadline.
      expect(previousBusinessDay(day(2026, 9, 8)), day(2026, 9, 7));
      // Sunday lunch -> Friday deadline.
      expect(previousBusinessDay(day(2026, 9, 13)), day(2026, 9, 11));
    });

    test('skips free days', () {
      final free = {day(2026, 9, 4)}; // Friday off -> Thursday deadline.
      expect(previousBusinessDay(day(2026, 9, 7), free), day(2026, 9, 3));
      expect(isBusinessDay(day(2026, 9, 4), free), isFalse);
      expect(isBusinessDay(day(2026, 9, 5)), isFalse); // Saturday
      expect(isBusinessDay(day(2026, 9, 7), free), isTrue);
    });
  });

  group('deadline', () {
    test('is noon on the previous business day', () {
      expect(
        lunchOrderDeadline(day(2026, 9, 7), '12:00'),
        DateTime(2026, 9, 4, 12, 0),
      );
      expect(
        lunchOrderDeadline(day(2026, 9, 8), '10:30'),
        DateTime(2026, 9, 7, 10, 30),
      );
    });

    test('winter deadline keeps wall time', () {
      // Tuesday 03.11.2026 -> Monday 02.11.2026 12:00 (CET wall time).
      expect(
        lunchOrderDeadline(day(2026, 11, 3), '12:00'),
        DateTime(2026, 11, 2, 12, 0),
      );
    });
  });

  group('is open', () {
    test('open until cutoff, then closed', () {
      final lunch = day(2026, 9, 8); // Tuesday; deadline Mon 07.09. 12:00.
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 7, 11, 59), cutoffTime: '12:00'),
        isTrue,
      );
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 7, 12, 0), cutoffTime: '12:00'),
        isTrue,
      );
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 7, 12, 1), cutoffTime: '12:00'),
        isFalse,
      );
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 8, 8, 0), cutoffTime: '12:00'),
        isFalse,
      );
    });

    test('monday deadline is friday noon', () {
      final lunch = day(2026, 9, 7); // Monday; deadline Fri 04.09. 12:00.
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 4, 12, 0), cutoffTime: '12:00'),
        isTrue,
      );
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 9, 6, 12, 0), cutoffTime: '12:00'),
        isFalse,
      );
    });

    test('winter boundary is CET wall time', () {
      final lunch = day(2026, 11, 3); // Deadline Mon 02.11. 12:00 CET.
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 11, 2, 12, 0), cutoffTime: '12:00'),
        isTrue,
      );
      expect(
        isLunchOrderOpen(lunch,
            now: moment(2026, 11, 2, 12, 1), cutoffTime: '12:00'),
        isFalse,
      );
    });
  });
}
