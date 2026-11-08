import 'package:test/test.dart';

import 'package:strakalari_core/src/lunches/lunch_auto.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<String, Map<String, String>> foodOf(Object? value) =>
    (value as Map).map((k, v) => MapEntry(
        k as String, Map<String, String>.from(v as Map)));

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('lunch_auto')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'clampGeminiInterval':
          result = clampGeminiInterval(args[0]);
        case 'parseLastRun':
          result = parseLastRun(args[0]);
        case 'shouldRunGeminiAuto':
          result = shouldRunGeminiAuto(
            args[0],
            args[1],
            args[2],
            args.length > 3 ? args[3] as DateTime? : null,
          );
        case 'filterPicks':
          final opts = strMap(args[1]);
          result = filterPicks(
            foodOf(args[0]),
            blacklist: (opts['blacklist'] as List?)?.cast<String>(),
            cancelledDays:
                (opts['cancelledDays'] as List?)?.cast<String>(),
            today: opts['today'] as DateTime?,
          );
        case 'mergeGeminiWithFilter':
          final opts = strMap(args[2]);
          result = mergeGeminiWithFilter(
            (args[0] as Map)
                .map((k, v) => MapEntry(k as String, v as String)),
            foodOf(args[1]),
            blacklist: (opts['blacklist'] as List?)?.cast<String>(),
            cancelledDays:
                (opts['cancelledDays'] as List?)?.cast<String>(),
            today: opts['today'] as DateTime?,
          );
        case 'updateHandledDays':
          result = updateHandledDays(
            (args[0] as List).cast<String>(),
            (args[1] as Map)
                .map((k, v) => MapEntry(k as String, v as String)),
            (args[2] as List).cast<String>(),
            args.length > 3 ? args[3] as DateTime? : null,
          );
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
