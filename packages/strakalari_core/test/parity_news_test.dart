import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/news.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));
  test('parityWithPython', () {
    for (final c in loadParityCases('news')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'newMarks':
          result = newMarks(strMap(args[0]), strMap(args[1]));
        case 'newQuarterlyMarks':
          result = newQuarterlyMarks(
              strMap(args[0]), strMap(args[1]));
        case 'newAbsences':
          result = newAbsences(strMap(args[0]), strMap(args[1]));
        case 'newChanges':
          result = newChanges(strMap(args[0]), strMap(args[1]),
              args[2] as DateTime);
        case 'findNews':
          result = [
            for (final e in findNews(
              args[0] == null ? null : strMap(args[0]),
              args[1] == null ? null : strMap(args[1]),
              args.length > 2 ? args[2] as DateTime? : null,
            ))
              [e.key, e.value],
          ];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
