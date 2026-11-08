import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/common.dart';
import 'package:strakalari_core/src/bakalari/extractors.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    (value as Map).map((k, v) => MapEntry(k as String, v));

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('bakalari')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseTimetableDetail':
          result = parseTimetableDetail(strMap(args[0]));
        case 'weekOffsets':
          result = weekOffsets(args[0], args.length > 1 ? args[1] : null);
        case 'extractGrades':
          result = extractGrades(args[0] as String).map(
              (k, v) => MapEntry(k, v));
        case 'sentExcuseEntries':
          result = sentExcuseEntries(strMap(args[0]));
        case 'absenceFromSubjects':
          final (percentages, details) =
              absenceFromSubjects(args[0]);
          result = [percentages, details];
        case 'subjectDirectory':
          result = subjectDirectoryFromRows(args[0]);
        case 'timetableDetails':
          result = timetableDetails(args[0]);
        case 'absenceDateRange':
          final range = absenceDateRange(args[0] as String);
          result = range == null ? [] : [range.$1, range.$2];
        case 'substitutionsFromWeeks':
          result = substitutionsFromWeeks(args[0]);
        case 'outboxExcuseIds':
          result = outboxExcuseIds(args[0] as String);
        case 'storeRows':
          result = storeRows(args[0]);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
