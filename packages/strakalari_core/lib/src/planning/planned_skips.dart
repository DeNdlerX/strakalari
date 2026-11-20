// Planned skips (planner "stay home" ranges) — pure helpers.
//
// Port of strakalari/core/planned_skips.py. Canonical entry shape
// (stored in config under `planned_skips`):
//
//   {"start_date": iso, "end_date": iso,
//    "start_period": int | null, "end_period": int | null,
//    "template": str}
//
// The legacy `{"date": iso, "template": str}` single-day shape is upgraded
// by [normalizePlannedEntry].
import '../models.dart';
import '../storage/helpers.dart';

/// Canonical planned-skip entry, or null for unparseable input.
Map<String, Object?>? normalizePlannedEntry(Object? raw) {
  if (raw is! Map) return null;
  final template = '${raw['template'] ?? ''}';
  final startIso = '${raw['start_date'] ?? raw['date'] ?? ''}';
  final endIso = '${raw['end_date'] ?? startIso}';

  int? period(Object? value) {
    if (value == null || value == '') return null;
    int? num;
    if (value is int) {
      num = value;
    } else if (value is double) {
      // Python int() truncates toward zero.
      num = value.truncate();
    } else if (value is bool) {
      return null;
    } else {
      num = int.tryParse('$value'.trim());
    }
    if (num == null) return null;
    return num >= 0 ? num : null;
  }

  final startPeriod = period(raw['start_period']);
  final endPeriod = period(raw['end_period']);
  DateTime start;
  DateTime end;
  try {
    start = DateTime.parse(startIso);
    end = DateTime.parse(endIso);
  } catch (_) {
    return null;
  }
  var startDay = DateTime(start.year, start.month, start.day);
  var endDay = DateTime(end.year, end.month, end.day);
  if (endDay.isBefore(startDay)) {
    final swap = startDay;
    startDay = endDay;
    endDay = swap;
  }
  var startP = startPeriod;
  var endP = endPeriod;
  if (startDay == endDay &&
      startP != null &&
      endP != null &&
      endP < startP) {
    final swap = startP;
    startP = endP;
    endP = swap;
  }
  String iso(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  final entry = <String, Object?>{
    'start_date': iso(startDay),
    'end_date': iso(endDay),
    'template': template,
  };
  if (startP != null) entry['start_period'] = startP;
  if (endP != null) entry['end_period'] = endP;
  // Only an explicit "keep my lunch" is stored; entries without the key
  // (older configs, the default) cancel the lunch.
  if (raw['cancel_lunch'] == false) entry['cancel_lunch'] = false;
  return entry;
}

/// True unless the user chose to keep the lunch on this day off.
bool cancelsLunch(Map<String, Object?> entry) {
  return entry['cancel_lunch'] != false;
}

/// ISO start of an entry (legacy `date` shape included).
String entryStartIso(Map<String, Object?> entry) {
  return '${entry['start_date'] ?? entry['date'] ?? ''}';
}

/// ISO end of an entry (defaults to the start).
String entryEndIso(Map<String, Object?> entry) {
  return '${entry['end_date'] ?? entryStartIso(entry)}';
}

/// Every calendar day an entry covers (inclusive, capped at [limit]).
List<DateTime> entryDays(Map<String, Object?> entry, [int limit = 62]) {
  DateTime start;
  DateTime end;
  try {
    start = DateTime.parse(entryStartIso(entry));
    end = DateTime.parse(entryEndIso(entry));
  } catch (_) {
    return [];
  }
  final days = <DateTime>[];
  var current = DateTime(start.year, start.month, start.day);
  final last = DateTime(end.year, end.month, end.day);
  while (!current.isAfter(last) && days.length < limit) {
    days.add(current);
    // Constructor arithmetic: `+ Duration(days: 1)` drifts across DST
    // transitions, while Python `date + timedelta` stays on the date.
    current = DateTime(current.year, current.month, current.day + 1);
  }
  return days;
}

/// True when [entry] skips lesson [period] on [day].
///
/// The planner's rule: `start_period` limits the first day, `end_period`
/// the last one, the days between are whole; a lesson without a number
/// counts as covered.
bool entryCovers(Map<String, Object?> entry, DateTime day, int? period) {
  final days = entryDays(entry);
  final target = DateTime(day.year, day.month, day.day);
  if (!days.contains(target)) return false;
  if (period == null) return true;
  final startP = target == days.first ? entry['start_period'] : null;
  final endP = target == days.last ? entry['end_period'] : null;
  final first = startP is int ? startP : null;
  final last = endP is int ? endP : null;
  return (first == null || period >= first) &&
      (last == null || period <= last);
}

DateTime _nextWeekday(DateTime day) {
  // Dart weekday: Monday = 1 … Sunday = 7
  // (Python weekday(): Monday = 0, so Python skips >= 5).
  var next = addDays(day, 1);
  while (next.weekday >= DateTime.saturday) {
    next = addDays(next, 1);
  }
  return next;
}

int? _toIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is double) return value.truncate();
  if (value is bool) return null;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Planned entries that skip exactly the picked lessons.
///
/// [picked] maps a day to the lesson numbers chosen on it, [lessons]
/// a day to every lesson number it holds (cancelled ones left out, already
/// planned or past ones kept, so they split the selection). Picked lessons
/// next to each other become one entry; whole days in a row — a weekend
/// between them doesn't break the row, a holiday does — merge into one
/// range, which may start with the end of one day and finish with the
/// start of another. The edge of a day stays open (no period), so a lesson
/// added there later is still covered. A range never spans more than
/// [maxDays] calendar days.
List<Map<String, Object?>> entriesForSelection({
  required Map<DateTime, Iterable<Object?>> picked,
  required Map<DateTime, Iterable<Object?>> lessons,
  String template = '',
  bool cancelLunch = true,
  int maxDays = 31,
}) {
  final out = <Map<String, Object?>>[];
  Map<String, Object?>? run; // open range: its last day is picked to the end

  void close() {
    final open = run;
    if (open != null) {
      out.add(open);
      run = null;
    }
  }

  String iso(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  final orderedDays = picked.keys.toList()..sort();
  for (final day in orderedDays) {
    final chosen = <int>{};
    for (final period in picked[day] ?? const <Object?>[]) {
      final n = _toIntOrNull(period);
      if (n != null) chosen.add(n);
    }
    if (chosen.isEmpty) continue;
    final order = <int>{...chosen};
    for (final period in lessons[day] ?? const <Object?>[]) {
      final n = _toIntOrNull(period);
      if (n != null) order.add(n);
    }
    final ordered = order.toList()..sort();
    // Index ranges into `ordered` of picked runs split by unpicked lessons.
    final segments = <(int, int)>[];
    int? begin;
    for (var i = 0; i < ordered.length; i++) {
      if (chosen.contains(ordered[i])) {
        begin ??= i;
      } else if (begin != null) {
        segments.add((begin, i - 1));
        begin = null;
      }
    }
    if (begin != null) segments.add((begin, ordered.length - 1));
    for (final (first, last) in segments) {
      final head = first == 0;
      final tail = last == ordered.length - 1;
      final open = run;
      if (head &&
          open != null &&
          _nextWeekday(DateTime.parse(open['end_date'] as String)) == day &&
          daysBetween(DateTime.parse(open['start_date'] as String), day) <
              maxDays) {
        open['end_date'] = iso(day);
        open['end_period'] = tail ? null : ordered[last];
      } else {
        close();
        run = {
          'start_date': iso(day),
          'end_date': iso(day),
          'start_period': head ? null : ordered[first],
          'end_period': tail ? null : ordered[last],
          'template': template,
          'cancel_lunch': cancelLunch,
        };
      }
      if (!tail) close();
    }
  }
  close();
  return out.map(normalizePlannedEntry).whereType<Map<String, Object?>>().toList();
}

/// Normalized planned-skip entries from a config map.
List<Map<String, Object?>> loadPlannedSkips(Map<String, Object?>? config) {
  final stored = (config ?? {})['planned_skips'];
  if (stored is! List) return [];
  return stored
      .map(normalizePlannedEntry)
      .whereType<Map<String, Object?>>()
      .toList();
}

/// `DD.MM.YYYY` days off whose lunch should be cancelled.
Set<String> plannedLunchDays(Map<String, Object?>? config) {
  final days = <String>{};
  for (final entry in loadPlannedSkips(config)) {
    if (!cancelsLunch(entry)) continue;
    for (final day in entryDays(entry)) {
      days.add(canonicalDayKey(day));
    }
  }
  return days;
}

bool _hasSetPeriod(Object? value) =>
    value != null && '$value'.trim().isNotEmpty && value != false;

/// `DD.MM.YYYY` whole planned days off whose lunch should be cancelled
/// automatically.
///
/// A day is whole when it is covered by at least one planned entry with
/// `cancel_lunch != false` where that day is neither the entry's first day
/// with `start_period` set nor its last day with `end_period` set.
Set<String> wholePlannedLunchDays(Map<String, Object?>? config) {
  final days = <String>{};
  final stored = (config ?? const {})['planned_skips'];
  if (stored is! List) return days;
  for (final raw in stored) {
    if (raw is! Map) continue;
    final entry = normalizePlannedEntry(raw);
    if (entry == null || !cancelsLunch(entry)) continue;
    final covered = entryDays(entry);
    if (covered.isEmpty) continue;
    final hasStartP =
        entry['start_period'] != null || _hasSetPeriod(raw['start_period']);
    final hasEndP =
        entry['end_period'] != null || _hasSetPeriod(raw['end_period']);
    for (final day in covered) {
      if (day == covered.first && hasStartP) continue;
      if (day == covered.last && hasEndP) continue;
      days.add(canonicalDayKey(day));
    }
  }
  return days;
}

