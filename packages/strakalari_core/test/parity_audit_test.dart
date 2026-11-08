import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/audit.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('audit')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'describeExcuse':
          result = describeExcuse((args[0] as Map)
              .map((k, v) => MapEntry(k as String, v)));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
