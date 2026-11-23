// Parsers for what the Strava web app API returns (see docs/STRAVA_API.md).
//
// Port of strakalari/core/extractors/strava.py.
import 'package:html_unescape/html_unescape.dart';

/// Removes HTML tags, newlines, tabs, and unescapes HTML entities.
String cleanText(Object? text) {
  if (text == null) return '';
  var out = '$text';
  if (out.isEmpty) return '';
  // 1. Line break and block tags become a space so words never merge.
  out = out.replaceAll(
      RegExp(r'<(?:br\s*/?|/div|/p|/tr|/td)[^>]*>',
          caseSensitive: false),
      ' ');
  // 2. Any remaining tags go away (e.g. <span>, <path d="...">, etc.).
  out = out.replaceAll(RegExp(r'<[^>]+>'), '');
  // 3. Entities back (converts &amp; to &, &lt; to <, etc.).
  out = HtmlUnescape().convert(out);
  // 4. Whitespace (newlines/tabs/runs) becomes one space.
  out = out.replaceAll(RegExp(r'\s+'), ' ');
  // 5. Strip.
  return out.trim();
}

// -- Web app JSON (/api/objednavky) -------------------------------------------

/// Monday-first names the menu day control shows.
const List<String> weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday'
];

/// `[(table key, meals)]` of an `/api/objednavky` reply, in day order.
List<(String, List<Object?>)> menuTables(Object? reply) {
  if (reply is! Map) return [];
  final tables = <(int, String, List<Object?>)>[];
  for (final entry in reply.entries) {
    final match = RegExp(r'^table(\d+)$').firstMatch('${entry.key}');
    final meals = entry.value;
    if (match != null && meals is List && meals.isNotEmpty) {
      tables.add((int.parse(match.group(1)!), '${entry.key}', meals));
    }
  }
  tables.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final t in tables) (t.$2, t.$3)];
}

/// False for rows the web shows with no order control (the soup row).
bool isOrderableMeal(Map<String, Object?> meal) =>
    meal['polevka'] != 'A' &&
    '${meal['zkratkaProduktu'] ?? ''}'.isNotEmpty;

/// The meal as the menu label reads: `oběd 1 - <name>(01, 03 )`.
String mealText(Map<String, Object?> meal) => _withAllergens(
    '${cleanText(meal['druh_popis'])} - ${cleanText(meal['nazev'])}', meal);

/// [text] followed by the row's allergen codes: `<text>(01, 03 )`.
String _withAllergens(String text, Map<Object?, Object?> meal) {
  final codes = <String>[];
  for (final a in (meal['alergeny'] as List?) ?? const []) {
    if (a is List && a.isNotEmpty && '${a[0]}'.trim().isNotEmpty) {
      codes.add('${a[0]}'.trim());
    }
  }
  return codes.isNotEmpty ? '$text(${codes.join(', ')} )' : text;
}

/// The day key of one table: the `datum` of its first row carrying a
/// valid date (the soup row comes first and may have none).
(String, DateTime?) _tableDay(List<Object?> meals) {
  var day = '';
  DateTime? when;
  for (final meal in meals) {
    if (meal is! Map) continue;
    day = '${meal['datum'] ?? ''}'.trim();
    when = _parseCzDay(day);
    if (when != null) break;
  }
  return (day, when);
}

/// The soup of each day (the rows with `polevka: "A"`), keyed like
/// [menuFromReply]'s days: `{"23.11.2026": "Frankfurtská(01, 07 )"}`.
/// Two soups on one day are joined with `, `. Never raises.
Map<String, String> soupsFromReply(Object? reply) {
  final soups = <String, String>{};
  for (final (_, meals) in menuTables(reply)) {
    final (day, date) = _tableDay(meals);
    if (date == null) continue;
    final texts = <String>[];
    for (final meal in meals) {
      if (meal is! Map || meal['polevka'] != 'A') continue;
      final name = cleanText(meal['nazev']);
      if (name.isNotEmpty) texts.add(_withAllergens(name, meal));
    }
    if (texts.isNotEmpty) soups[day] = texts.join(', ');
  }
  return soups;
}

/// `(foodDict, orderedDict)` from an `/api/objednavky` reply.
///
/// Same shapes and ids the menu page's elements carried: per day a
/// `<table>&-1&0` day control (cancel the day) plus `<table>&<id>&0`
/// per orderable meal; the ordered meal is the one with `pocet` > 0.
/// Never raises: `({}, {})` on garbage.
(Map<String, Map<String, String>>, Map<String, String>) menuFromReply(
    Object? reply) {
  final food = <String, Map<String, String>>{};
  final ordered = <String, String>{};
  for (final (key, meals) in menuTables(reply)) {
    final (day, date) = _tableDay(meals);
    if (date == null) continue;
    final w = date;
    final selection = <String, String>{
      '$key&-1&0': '${weekdays[w.weekday - 1]} '
          '${_two(w.day)}/${_two(w.month)}/${w.year}'
    };
    for (final meal in meals) {
      if (meal is! Map) continue;
      final m = meal is Map<String, Object?>
          ? meal
          : meal.cast<String, Object?>();
      if (!isOrderableMeal(m)) continue;
      final mealId = '$key&${m['id']}&0';
      selection[mealId] = mealText(m);
      final count = int.tryParse('${m['pocet'] ?? 0}') ?? 0;
      if (count > 0 && !ordered.containsKey(day)) {
        ordered[day] = mealId;
      }
    }
    food[day] = selection;
  }
  return (food, ordered);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Strict `dd.MM.yyyy`, or null (mirrors `strptime(…, "%d.%m.%Y")`).
DateTime? _parseCzDay(String day) {
  final match =
      RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(day);
  if (match == null) return null;
  try {
    final d = DateTime(int.parse(match.group(3)!),
        int.parse(match.group(2)!), int.parse(match.group(1)!));
    if (d.day == int.parse(match.group(1)!) &&
        d.month == int.parse(match.group(2)!)) {
      return d;
    }
    return null;
  } on Object {
    return null;
  }
}
