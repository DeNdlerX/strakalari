// Allergens the diner avoids: parsing the codes after a meal, reading
// `strava_allergens`, and keeping those meals out of automatic picks.
import 'package:test/test.dart';

import 'package:strakalari_core/src/lunches/allergens.dart';
import 'package:strakalari_core/src/lunches/lunch_auto.dart';

String czDay(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

void main() {
  test('codes after a meal become allergen numbers', () {
    expect(mealAllergens('oběd 1 - Řízek(01, 03, 07 )'), {1, 3, 7});
    expect(mealAllergens('Kulajda; Kuře, rýže (1a, 7,9)'), {1, 7, 9});
    expect(mealAllergens('oběd 1 - Buchty (sladké)'), isEmpty);
    expect(mealAllergens('oběd 1 - Guláš'), isEmpty);
    expect(mealAllergens('Divné(15, 07 )'), {7});
  });

  test('avoided allergens read from the config, garbage ignored', () {
    expect(avoidedAllergens({'strava_allergens': [7, '1', ' 3 ', 0, 15, 'x']}),
        {1, 3, 7});
    expect(avoidedAllergens({'strava_allergens': 'nope'}), isEmpty);
    expect(avoidedAllergens({}), isEmpty);
    expect(avoidedAllergens(null), isEmpty);
  });

  test('first avoided allergen of a meal', () {
    expect(avoidedAllergenIn('Řízek(01, 03, 07 )', {7, 3}), 3);
    expect(avoidedAllergenIn('Řízek(01 )', {7}), isNull);
    expect(avoidedAllergenIn('Řízek(07 )', {}), isNull);
  });

  test('meals with an avoided allergen leave the menu, day controls stay', () {
    final food = {
      '23.11.2026': {
        't&-1&0': 'Monday 23/11/2026',
        't&1&0': 'oběd 1 - Roláda(01, 07 )',
        't&2&0': 'oběd 2 - Šišky(01 )',
      },
    };
    expect(withoutAvoidedAllergens(food, {7}), {
      '23.11.2026': {
        't&-1&0': 'Monday 23/11/2026',
        't&2&0': 'oběd 2 - Šišky(01 )',
      },
    });
    expect(identical(withoutAvoidedAllergens(food, {}), food), isTrue);
    expect(food['23.11.2026']!.length, 3); // input untouched
  });

  test('automatic ordering skips meals with an avoided allergen', () async {
    final now = DateTime.now();
    final day = czDay(DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 30)));
    final food = {
      day: {
        'a&-1&0': 'cancel',
        'a&1&0': 'oběd 1 - Roláda(01, 07 )',
        'a&2&0': 'oběd 2 - Šišky(01 )',
      },
    };
    final (plain, _) =
        await planAutoOrders(food, {}, ordered: {}, isOpen: (_) => true);
    expect(plain[day], 'a&1&0');
    final (avoiding, _) = await planAutoOrders(
      food,
      {'strava_allergens': [7]},
      ordered: {},
      isOpen: (_) => true,
    );
    expect(avoiding[day], 'a&2&0');
  });
}
