import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('i18n')) {
      expect(c['fn'], 't');
      final args = c['args'] as List;
      setLanguage(args[2] as String);
      final result = t(args[0] as String,
          args: (args[1] as Map).cast<String, Object?>());
      expect(decodeParityValue(result), decodeParityValue(c['expected']),
          reason: "${c['args']}");
    }
    setLanguage('cs');
  });
}
