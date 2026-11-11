import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../l10n/strings.dart';

/// Pure formatting/parsing helpers ported from
/// `strakalari/flet_ui/components.py` (day names, Czech dates, plural
/// lessons) and `strakalari/core/models.py` (`parse_cz_date`,
/// `canonical_day_key`), plus `core/helpers.py` (`short_time`,
/// `teacher_surname`) and `core/wakeup.py` (`clamp_wakeup_minutes`).
///
/// Rules from PLAN §3.5 are honored throughout: dates are parsed by hand
/// (never with a locale), weekday is Monday-based, and no Czech text is
/// hardcoded in logic.

const List<String> _czechDays = [
  'Pondělí',
  'Úterý',
  'Středa',
  'Čtvrtek',
  'Pátek',
  'Sobota',
  'Neděle',
];
const List<String> _englishDays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const List<String> _czechDaysShort = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];
const List<String> _englishDaysShort = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Weekday name in the app language — accepts a [DateTime] or a
/// `DD.MM.YYYY` string (like `components.day_name`).
String dayName(Object? value, String language, {bool short = false}) {
  final day = value is DateTime ? value : parseCzDate(value);
  if (day == null) return '${value ?? '?'}';
  // Dart weekday is Monday=1 like Python's isoweekday; index 0..6.
  final idx = (day.weekday - 1).clamp(0, 6);
  final en = language == 'en';
  if (short) return (en ? _englishDaysShort : _czechDaysShort)[idx];
  return (en ? _englishDays : _czechDays)[idx];
}

/// `'1 hodina' / '3 hodiny' / '5 hodin'` (Czech plurals; English 1/other).
String lessonsText(int n, [Object? _]) {
  if (Strings.lang == 'en') {
    return n == 1
        ? Strings.format('lessons_one', {'n': n})
        : Strings.format('lessons_many', {'n': n});
  }
  if (n == 1) return Strings.format('lessons_one', {'n': n});
  if (n >= 2 && n <= 4) return Strings.format('lessons_few', {'n': n});
  return Strings.format('lessons_many', {'n': n});
}

/// Czech short date: `7. 9.` — accepts a [DateTime] or `DD.MM.YYYY`.
String czDay(Object? value) {
  final day = value is DateTime ? value : parseCzDate(value);
  if (day == null) return '${value ?? '?'}';
  return '${day.day}. ${day.month}.';
}

/// Czech date with year: `7. 9. 2026`.
String czDayYear(Object? value) {
  final day = value is DateTime ? value : parseCzDate(value);
  if (day == null) return '${value ?? '?'}';
  return '${day.day}. ${day.month}. ${day.year}';
}

/// `DD.MM.YYYY` for lookups (zero-padded, like `canonical_day_key`
/// after `strftime("%d.%m.%Y")`).
String dayKey(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';

/// ISO `YYYY-MM-DD`.
String isoDay(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// Monday of the week containing [day].
DateTime weekMonday(DateTime day) =>
    core.addDays(DateTime(day.year, day.month, day.day), -(day.weekday - 1));

/// Parses Czech/ISO dates. One implementation: the core's
/// `models.parse_cz_date` port.
DateTime? parseCzDate(Object? value) => core.parseCzDate(value);

/// `helpers.short_time` (the core port).
String shortTime(Object? raw) => core.shortTime(raw);

/// `helpers.teacher_surname` (the core port); null reads as empty.
String teacherSurname(Object? fullName) => core.teacherSurname(fullName ?? '');

/// Python `f"{x:g}"` — drops the trailing `.0`.
String gFormat(num x) {
  if (x is int) return '$x';
  if (x == x.truncateToDouble()) return '${x.truncate()}';
  var s = '$x';
  if (s.contains('e') || s.contains('E')) return s;
  s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s;
}

/// Python `round()` (half to even) for non-negative display values —
/// PLAN §3.5: Dart's `round()` rounds half away from zero.
int roundHalfEven(double value) {
  final lo = value.floor();
  final frac = value - lo;
  if (frac < 0.5) return lo;
  if (frac > 0.5) return lo + 1;
  return lo.isEven ? lo : lo + 1;
}

/// `wakeup.clamp_wakeup_minutes` (the core port).
int clampWakeupMinutes(Object? value, [int fallback = 60]) =>
    core.clampWakeupMinutes(value, fallback);

/// Clock range `8:00 - 8:45` → `(startMin, endMin)` in minutes —
/// like the timetable `_CLOCK_RE` (`(\d{1,2}):(\d{2})\s*[-–]\s*…`).
/// PLAN §3.5: plain numbered groups, no inline flags.
({int startMin, int endMin})? clockRange(String label) {
  final m = RegExp(r'(\d{1,2}):(\d{2})\s*[-–—]\s*(\d{1,2}):(\d{2})')
      .firstMatch(label);
  if (m == null) return null;
  try {
    final start = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
    final end = int.parse(m.group(3)!) * 60 + int.parse(m.group(4)!);
    return (startMin: start, endMin: end);
  } catch (_) {
    return null;
  }
}
