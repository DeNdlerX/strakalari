import 'package:test/test.dart';

import 'package:strakalari_core/src/storage/helpers.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('helpers')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseDate':
          result = parseDate(args[0]);
        case 'extractLessonNum':
          result = extractLessonNum(args[0]);
        case 'shortTime':
          result = shortTime(args[0]);
        case 'teacherSurname':
          result = teacherSurname(args[0]);
        case 'isExcusedMarker':
          result = isExcusedMarker(args[0]);
        case 'shortRoomName':
          result = shortRoomName(args[0]);
        case 'formatExcuseTemplate':
          result = formatExcuseTemplate(args[0] as String,
              dateStr: args[1] as String,
              lessonsStr: args[2],
              subjectStr: args[3] as String,
              signatureStr: args[4] as String);
        case 'templateText':
          result = templateText(args[0]);
        case 'isEncryptedFlag':
          result = isEncryptedFlag(args[0]);
        case 'addDays':
          result = addDays(args[0] as DateTime, args[1] as int);
        case 'pyJsonDumps':
          result = pyJsonDumps(args[0]);
        case 'jsonIndent2':
          result = jsonIndent2(args[0]);
        case 'daysBetween':
          result = daysBetween(args[0] as DateTime, args[1] as DateTime);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
