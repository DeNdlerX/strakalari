import 'package:test/test.dart';

import 'package:strakalari_core/src/strava/client.dart';
import 'package:strakalari_core/src/strava/extractors.dart';
import 'package:strakalari_core/src/strava/ordering.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    (value as Map).map((k, v) => MapEntry(k as String, v));

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('strava')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'cleanText':
          result = cleanText(args[0]);
        case 'menuTables':
          result = [
            for (final (key, meals) in menuTables(args[0])) [key, meals]
          ];
        case 'isOrderableMeal':
          result = isOrderableMeal(strMap(args[0]));
        case 'mealText':
          result = mealText(strMap(args[0]));
        case 'menuFromReply':
          final (food, ordered) = menuFromReply(args[0]);
          result = [food, ordered];
        case 'orderSheet':
          result = orderSheet(
              (args[0] as List).map((m) => strMap(m)).toList());
        case 'apiRoot':
          result = apiRoot(args[0]);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
