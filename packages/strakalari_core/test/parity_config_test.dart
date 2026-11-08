import 'package:test/test.dart';

import 'package:strakalari_core/src/storage/config.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('config')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'looksLikePlaceholder':
          result = looksLikePlaceholder(args[0]);
        case 'hasValidCredentials':
          final creds = hasValidCredentials(
              (args[0] as Map).map((k, v) => MapEntry(k as String, v)));
          result = [creds.$1, creds.$2];
        case 'validateConfig':
          result = validateConfig((args[0] as Map)
              .map((k, v) => MapEntry(k as String, v)));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
