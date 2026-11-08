import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/lunches/gemini.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));
  test('parityWithPython', () {
    for (final c in loadParityCases('gemini')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'buildMenuBlock':
          result = buildMenuBlock(args[0] as Map);
        case 'buildPrompt':
          result = buildPrompt(args[0] as String, args[1] as String,
              args.length > 2 ? args[2] as String : 'cs');
        case 'parseRecommendationResponse':
          final r = parseRecommendationResponse(args[0] as String);
          result = [r.$1, r.$2];
        case 'validateRecommendation':
          result = validateRecommendation(
              args[0] as Map, args[1] as Map);
        case 'localFallbackRecommendation':
          final r = localFallbackRecommendation(
            args[0] as Map,
            args[1] as String,
            language: args.length > 2 ? args[2] as String : 'cs',
          );
          result = [r.$1, r.$2];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
