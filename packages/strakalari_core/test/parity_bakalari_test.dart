import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/common.dart';
import 'package:strakalari_core/src/bakalari/excuse.dart';
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
        case 'minutesText':
          result = minutesText(args[0] as int);
        case 'hourText':
          result = hourText(strMap(args[0]));
        case 'lesson':
          result = lesson(
              (args[0] as List).cast<Object?>(), args[1]);
        case 'textToHtml':
          result = textToHtml(args[0] as String);
        case 'jsDate':
          result = jsDate(args[0] as DateTime,
              includeTime: args[1] as bool);
        case 'dateState':
          result = dateState(args[0] as DateTime);
        case 'calendarState':
          result = calendarState(args[0] as DateTime);
        case 'pageResources':
          final res = pageResources(args[0] as String);
          result = [res.$1, res.$2];
        case 'editorDefaults':
          final def = editorDefaults(args[0] as String);
          result = [def.$1, def.$2];
        case 'excusePostback':
          result = excusePostback(args[0] as String,
                  dayFrom: args[1] as DateTime,
                  dayTo: args[2] as DateTime,
                  wholeDay: args[3] as bool,
                  hourFrom:
                      args[4] == null ? null : strMap(args[4]),
                  hourTo: args[5] == null ? null : strMap(args[5]),
                  text: args[6] as String,
                  now: args[7] as DateTime)
              .map((f) => [f.$1, f.$2])
              .toList();
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
