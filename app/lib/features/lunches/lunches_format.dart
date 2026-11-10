/// Meal name, soup and allergen parsing for the lunches screen.
///
/// Port of `LunchView._display_name`, `LunchView._split_meal` and
/// `LunchView._shared_soup` in `strakalari/flet_ui/views/lunches.py`.
library;

/// Tidy raw Strava meal names (ensures spacing after commas and around parentheses).
String displayMealName(String name) {
  var text = name.replaceAllMapped(
      RegExp(r',(\S)'), (m) => ', ${m.group(1)}');
  text = text.replaceAllMapped(
      RegExp(r'(\S)\('), (m) => '${m.group(1)} (');
  return text.replaceAll(RegExp(r'\s+\)'), ')');
}

/// Splits `'Soup; Main (1,3,7)'` into `(soup, main, allergens)`.
(String, String, String) splitMeal(String name) {
  var text = displayMealName(name).trim();
  var allergens = '';
  final m = RegExp(r'\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$')
      .firstMatch(text);
  if (m != null) {
    allergens = m
        .group(1)!
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .join(', ');
    text = text.substring(0, m.start).trimRight();
  }
  final idx = text.indexOf(';');
  if (idx < 0) return ('', text, allergens);
  return (text.substring(0, idx).trim(), text.substring(idx + 1).trim(), allergens);
}

/// Returns the shared soup every meal of the day has in common ('' when they differ).
String sharedSoup(Map<String, String> meals) {
  final soups = {
    for (final e in meals.entries)
      if (!e.key.contains('&-1&')) splitMeal(e.value).$1,
  };
  return soups.length == 1 ? soups.single : '';
}
