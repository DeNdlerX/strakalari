import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/matching.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('matching')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'stripDiacritics':
          result = stripDiacritics(args[0]);
        case 'normalizeWord':
          result = normalizeWord(args[0]);
        case 'prefsBanKeywords':
          result = prefsBanKeywords(args[0]);
        case 'isFoodBanned':
          final r = isFoodBanned(
              args[0], (args[1] as List).cast<Object?>());
          result = [r.$1, r.$2];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
