import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';

import 'parity_cases.dart';

/// Builds the same shape dump.py stores for `lessonFromLegacy`.
Map<String, Object?> lessonToParity(Lesson lesson) => {
      'subject': lesson.subject,
      'period': lesson.period,
      'status': lesson.status,
      'excused': lesson.excused,
      'room': lesson.room,
      'day': lesson.day,
    };

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('models')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseCzDate':
          result = parseCzDate(args[0]);
        case 'canonicalDayKey':
          result = canonicalDayKey(args[0]);
        case 'absenceKind':
          result = absenceKind(args[0], args[1]);
        case 'isCancelNotice':
          result = isCancelNotice(args[0]);
        case 'lessonFromLegacy':
          result = lessonToParity(Lesson.fromLegacy({
            'subject': 'Matematika',
            'teacher': 'T',
            'time': '1 (8:00-8:45)',
            'room': '4A - (104)',
            'absenceType': 'Absent',
            'absencetext': 'Absence',
          }));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
