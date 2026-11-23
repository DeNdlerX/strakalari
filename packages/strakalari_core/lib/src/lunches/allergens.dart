// Food allergens: the numbers canteens print after a meal, e.g.
// "Řízek(01, 03, 07 )" — the 14 allergens of EU regulation 1169/2011,
// Annex II. Sub-codes such as "1a" (wheat) count as their number.
//
// The diner's avoided allergens (config `strava_allergens`) work like
// the blacklist: meals listing one are hidden and never picked
// automatically. Pure helpers, no I/O.

/// The allergen numbers, 1–14.
const List<int> allergenNumbers = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, //
];

/// Trailing allergen list: "(1,3,7)", "(01, 1a, 07 )".
final RegExp _trailingCodes =
    RegExp(r'\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$');

/// The allergen numbers listed at the end of a meal [text]:
/// `"oběd 1 - Řízek(01, 1a, 07 )"` → `{1, 7}`.
Set<int> mealAllergens(String text) {
  final match = _trailingCodes.firstMatch(text.trim());
  if (match == null) return {};
  final out = <int>{};
  for (final code in match.group(1)!.split(',')) {
    final n = int.tryParse(RegExp(r'\d+').stringMatch(code) ?? '');
    if (n != null && allergenNumbers.contains(n)) out.add(n);
  }
  return out;
}

/// The allergens the diner avoids (config `strava_allergens`); anything
/// that is not a number 1–14 is ignored.
Set<int> avoidedAllergens(Map<String, Object?>? config) {
  final raw = config?['strava_allergens'];
  if (raw is! List) return {};
  final out = <int>{};
  for (final value in raw) {
    final n = int.tryParse('$value'.trim());
    if (n != null && allergenNumbers.contains(n)) out.add(n);
  }
  return out;
}

/// The lowest avoided allergen in a meal [text], or null.
int? avoidedAllergenIn(String text, Set<int> avoided) {
  if (avoided.isEmpty) return null;
  final hits = mealAllergens(text).intersection(avoided).toList()..sort();
  return hits.isEmpty ? null : hits.first;
}

/// [food] without the meals that list an avoided allergen; the day
/// controls (`&-1&`) stay. Returns [food] itself when nothing is avoided.
Map<String, Map<String, String>> withoutAvoidedAllergens(
  Map<String, Map<String, String>> food,
  Set<int> avoided,
) {
  if (avoided.isEmpty) return food;
  return {
    for (final day in food.entries)
      day.key: {
        for (final meal in day.value.entries)
          if (meal.key.contains('&-1&') ||
              avoidedAllergenIn(meal.value, avoided) == null)
            meal.key: meal.value,
      },
  };
}
