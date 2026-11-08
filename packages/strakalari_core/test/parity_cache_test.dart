import 'package:test/test.dart';

import 'package:strakalari_core/src/storage/cache.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('cache')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'mergeTimetableDays':
          final old = (args[0] as Map?)?.map(
              (k, v) => MapEntry(k as String, v as Object?));
          final fresh = (args[1] as Map?)?.map(
              (k, v) => MapEntry(k as String, v as Object?));
          final window =
              args.length > 2 ? args[2] as DateTime? : null;
          result = mergeTimetableDays(old, fresh, windowStart: window);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
