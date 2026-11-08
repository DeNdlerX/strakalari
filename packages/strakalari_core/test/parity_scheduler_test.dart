import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/scheduler.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('scheduler')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'nextDue':
          result = nextDue(
            args[0] as DateTime?,
            (args[1] as num?)?.toDouble(),
            args[2] as DateTime,
          );
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
