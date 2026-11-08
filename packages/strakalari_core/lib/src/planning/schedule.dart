// Stable-schedule baseline, change-vs-note classification, lesson clock.
//
// Port of strakalari/core/schedule.py.
//
// The timetable coming from Bakalari is the *actual* week: every lesson may
// carry a teacher ``notice`` (description). A notice alone is NOT a schedule
// change — it only becomes one when the lesson actually differs from the
// stable (main) timetable: different subject, teacher, room, time, an added
// lesson in a normally free slot, a missing stable lesson, or a cancelled
// lesson.
//
// The baseline prefers the scraped "Stálý rozvrh" view (the exact template
// week, see `BakalariClient.extract_stable_timetable`): with a *complete*
// baseline an empty slot is a free period, so an actual lesson there is an
// ``added`` change and a stable slot with no actual lesson is a ``missing``
// change. The baseline is never guessed from the actual weeks: when the
// stable view cannot be scraped there is no baseline, and Bakaláři's own
// change flags plus the notice-keyword heuristic decide.
//
// Lesson-clock helpers in this module are the single place that reasons
// about "what time is it during the school day" — the Today view and the
// planner both use them so "next lesson" and "can I still plan today"
// respect the clock, not just the date.
import 'package:clock/clock.dart';

import '../models.dart';
import '../storage/helpers.dart';

final RegExp _timeRangeRe = RegExp(
    r'(\d{1,2})\s*:\s*(\d{2})\s*(?:-|–|—|do)\s*(\d{1,2})\s*:\s*(\d{2})');

/// Notice keywords that — without any baseline to compare against — still
/// mean a real schedule change (substitution, move, cancellation).
const List<String> changeKeywords = [
  'supl',
  'substitut',
  'změn',
  'zmen',
  'odpad',
  'zruš',
  'zrus',
  'vyjm',
  'vynat',
  'vyňat',
  'přid',
  'prid',
  'přesun',
  'presun',
  'náhrad',
  'nahrad',
  'cancel',
  'moved',
];

const Set<String> _titleTokens = {
  'ph.d.',
  'phd',
  'csc.',
  'csc',
  'drsc.',
  'drsc',
  'dis.',
  'dis',
  'mba',
  'th.d.',
  'thd',
  'dr.',
  'mgr.',
  'ing.',
  'bc.',
  'mudr.',
  'judr.',
  'paeddr.',
  'rndr.',
};

/// Mirrors Python's `str(value or "")`: null, false, zero, empty string,
/// empty collections all read as "".
String _orEmpty(Object? value) {
  if (value == null) return '';
  if (value is bool) return value ? 'True' : '';
  if (value is num && value == 0) return '';
  if (value is String && value.isEmpty) return '';
  if (value is Iterable && value.isEmpty) return '';
  if (value is Map && value.isEmpty) return '';
  return '$value';
}

String _normText(Object? value) => _orEmpty(value).trim().toLowerCase();

String _surname(Object? fullName) {
  final tokens = '$fullName'
      .split(RegExp(r'\s+'))
      .map((t) => t.trim().replaceAll(RegExp(r',+$'), ''))
      .where((t) => t.isNotEmpty)
      .toList();
  while (tokens.isNotEmpty &&
      _titleTokens.contains(tokens.first.toLowerCase())) {
    tokens.removeAt(0);
  }
  while (tokens.isNotEmpty &&
      _titleTokens.contains(tokens.last.toLowerCase())) {
    tokens.removeLast();
  }
  return tokens.isEmpty ? '' : tokens.last.toLowerCase();
}

/// Read-only string-keyed view of a lesson row (tolerates non-string keys;
/// never used for the mutating paths, which write through the original).
Map<String, Object?> _readMap(Map<Object?, Object?>? raw) {
  if (raw == null) return <String, Object?>{};
  if (raw is Map<String, Object?>) return raw;
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    out['${entry.key}'] = entry.value;
  }
  return out;
}

/// Mirrors Python's `int()` for lesson numbers: ints pass, doubles
/// truncate, numeric strings parse, bools become 0/1, the rest is null.
int? _slotIntOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }
  return null;
}

/// Python `//` floors while Dart `~/` truncates; minute arithmetic only
/// ever divides non-negative numbers in practice, but `floor()` matches
/// Python exactly for every input.
int _floorDiv60(int minutes) => (minutes / 60).floor();

String _clockLabel(int period, int? startMin) {
  if (startMin == null) return '$period';
  return '$period (${_floorDiv60(startMin)}:${(startMin % 60).toString().padLeft(2, '0')})';
}

/// Parses ``8:00 - 8:45`` (also inside ``1. 8:00 - 8:45`` /
/// ``3 (10:05 - 10:50)``).
///
/// Returns (start_hour, start_min, end_hour, end_min) or null.
(int, int, int, int)? parseTimeRange(Object? text) {
  if (text == null) return null;
  final str = '$text';
  if (str.isEmpty) return null;
  final match = _timeRangeRe.firstMatch(str);
  if (match == null) return null;
  final sh = int.tryParse(match.group(1)!);
  final sm = int.tryParse(match.group(2)!);
  final eh = int.tryParse(match.group(3)!);
  final em = int.tryParse(match.group(4)!);
  if (sh == null || sm == null || eh == null || em == null) return null;
  if (!(sh >= 0 && sh <= 23 && eh >= 0 && eh <= 23 && sm >= 0 && sm <= 59 && em >= 0 && em <= 59)) {
    return null;
  }
  return (sh, sm, eh, em);
}

/// Returns (start_minutes, end_minutes) since midnight for a lesson row.
(int, int)? lessonClock(Map<Object?, Object?>? raw, [Object? day]) {
  final parsed = Lesson.fromLegacy(_readMap(raw), day);
  final span = parseTimeRange(parsed.time);
  if (span == null) return null;
  final start = span.$1 * 60 + span.$2;
  final end = span.$3 * 60 + span.$4;
  if (end <= start) return null;
  return (start, end);
}

/// Taught lessons with a parseable clock, sorted by start time.
///
/// Cancelled lessons are never running or up next — in a swapped slot
/// the lesson taught instead is.
List<(int, int, Map<Object?, Object?>)> _clocked(List<Object?>? lessons, [Object? day]) {
  final out = <(int, int, Map<Object?, Object?>)>[];
  for (final raw in lessons ?? []) {
    if (raw is! Map) continue;
    if (Lesson.fromLegacy(_readMap(raw), day).status == 'cancelled') {
      continue;
    }
    final span = lessonClock(raw, day);
    if (span != null) out.add((span.$1, span.$2, raw));
  }
  out.sort((a, b) {
    final byStart = a.$1.compareTo(b.$1);
    return byStart != 0 ? byStart : a.$2.compareTo(b.$2);
  });
  return out;
}

/// Splits one day into running / upcoming lessons for [now].
///
/// Returns ``{"phase", "current", "upcoming", "remaining"}`` where phase is
/// one of ``empty`` (no clocked lessons at all), ``before`` (school hasn't
/// started), ``running`` (a lesson is on right now), ``between`` (in a
/// break, ``upcoming`` is next), ``done`` (all lessons over).
/// Lessons without a parseable time are ignored for the clock but counted
/// in ``remaining`` when their period number is still ahead — callers that
/// need period-only fallback should sort by period themselves.
Map<String, Object?> resolveDayLessons(List<Object?>? dayLessons,
    [DateTime? now, Object? day]) {
  final current = now ?? clock.now();
  final nowMin = current.hour * 60 + current.minute;
  final clocked = _clocked(dayLessons, day);
  if (clocked.isEmpty) {
    return {
      'phase': 'empty',
      'current': null,
      'upcoming': null,
      'remaining': <Map<Object?, Object?>>[],
    };
  }
  for (final (start, end, raw) in clocked) {
    if (start <= nowMin && nowMin < end) {
      final rest = [
        for (final (s, _, r) in clocked)
          if (s >= nowMin) r
      ];
      return {
        'phase': 'running',
        'current': raw,
        'upcoming': null,
        'remaining': rest,
      };
    }
  }
  final upcoming = [
    for (final (s, _, r) in clocked)
      if (s > nowMin) (s, r)
  ];
  if (upcoming.isEmpty) {
    return {
      'phase': 'done',
      'current': null,
      'upcoming': null,
      'remaining': <Map<Object?, Object?>>[],
    };
  }
  if (nowMin < clocked.first.$1) {
    return {
      'phase': 'before',
      'current': null,
      'upcoming': upcoming.first.$2,
      'remaining': [for (final (_, r) in upcoming) r],
    };
  }
  return {
    'phase': 'between',
    'current': null,
    'upcoming': upcoming.first.$2,
    'remaining': [for (final (_, r) in upcoming) r],
  };
}

/// Lessons of one day that haven't started yet (clock-aware).
///
/// Lessons without a parseable clock are kept (better to offer than to
/// hide), so "plan today" never drops unparseable rows. Cancelled lessons
/// and class events are never ahead: there is nothing left to skip.
List<Map<Object?, Object?>> futureLessons(List<Object?>? dayLessons, [DateTime? now, Object? day]) {
  final current = now ?? clock.now();
  final nowMin = current.hour * 60 + current.minute;
  final out = <Map<Object?, Object?>>[];
  for (final raw in dayLessons ?? []) {
    if (raw is! Map) continue;
    if (Lesson.fromLegacy(_readMap(raw), day).status == 'cancelled' ||
        isClassEvent(raw)) {
      continue;
    }
    final span = lessonClock(raw, day);
    if (span == null || span.$1 > nowMin) out.add(raw);
  }
  return out;
}

// -- stable baseline ----------------------------------------------------

/// The stable lesson for one (weekday, period) slot.
class SlotBaseline {
  /// Python `date.weekday()` numbering: Monday = 0 … Sunday = 6.
  final int weekday;
  final int period;
  String subject;
  String teacher;
  String room;
  final int? startMin;
  /// How many weeks agree on this fingerprint.
  final int support;

  SlotBaseline({
    required this.weekday,
    required this.period,
    this.subject = '',
    this.teacher = '',
    String room = '',
    this.startMin,
    this.support = 0,
  }) : room = shortRoomName(room);

  factory SlotBaseline.fromJson(Map<String, Object?> json) {
    final slot = _slotFromJson(json, (0, 0));
    if (slot == null) {
      throw FormatException('Invalid SlotBaseline: $json');
    }
    return slot;
  }

  Map<String, Object?> toJson() => {
        'weekday': weekday,
        'period': period,
        'subject': subject,
        'teacher': teacher,
        'room': room,
        'start_min': startMin,
        'support': support,
      };

  SlotBaseline copyWith({
    int? weekday,
    int? period,
    String? subject,
    String? teacher,
    String? room,
    int? startMin,
    int? support,
  }) =>
      SlotBaseline(
        weekday: weekday ?? this.weekday,
        period: period ?? this.period,
        subject: subject ?? this.subject,
        teacher: teacher ?? this.teacher,
        room: room ?? this.room,
        startMin: startMin ?? this.startMin,
        support: support ?? this.support,
      );
}

/// Period number of a scraped row.
///
/// Public in Dart (Python: `_period_of`) because the ported tests call it
/// directly; Dart privacy is per library.
int? periodOf(Map<Object?, Object?>? raw, [Object? day]) {
  final parsed = Lesson.fromLegacy(_readMap(raw), day);
  int? num = parsed.period;
  if (num == null) {
    try {
      num = extractLessonNum(parsed.time);
    } catch (_) {
      num = null;
    }
  }
  if (num == null && raw is Map) {
    // Scraped rows carry Bakalari's hourIndex (period + 2); the
    // cancelled ("removed") rows have no period number in their clock.
    // Same 1..15 range as parse_timetable_detail (period 0 is never
    // inferred from hourIndex 2).
    try {
      final hi = raw['hourIndex'];
      if (hi != null) {
        final hiInt = _slotIntOrNull(hi);
        if (hiInt != null) {
          final candidate = hiInt - 2;
          if (candidate >= 1 && candidate <= 15) num = candidate;
        }
      }
    } catch (_) {
      // Ignore.
    }
  }
  return num;
}

/// Weekly lesson counts per subject from the stable baseline.
///
/// Unlike counting raw timetable rows (which include cancelled lessons,
/// substitutions and one-off events), the baseline holds one slot per
/// (weekday, period) — so this is the trustworthy "how many hours of X
/// per normal week" input for absence forecasting. Accepts both live
/// [SlotBaseline] values and plain serialized dicts (see
/// [baselineToDict]). Split-group slots count each distinct
/// subject once — the student attends one group, but every offered
/// subject still costs absence budget.
Map<String, int> stableWeeklyHours(Map<Object?, Object?>? baseline) {
  final counts = <String, int>{};

  String nameOf(Object? variant) {
    if (variant is SlotBaseline) return variant.subject.trim();
    if (variant is Map) return '${variant['subject'] ?? ''}'.trim();
    return '';
  }

  for (final slotValue in (baseline ?? {}).values) {
    final variants = slotValue is List ? slotValue : [slotValue];
    final names = {for (final v in variants) nameOf(v)};
    for (final name in names) {
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  return counts;
}

/// Serializes a stable baseline to JSON-safe plain maps.
///
/// Split-group slots (variant lists) serialize to a list of maps.
Map<String, Object?> baselineToDict(Map<Object?, Object?>? baseline) {
  Map<String, Object?> one(SlotBaseline slot) => slot.toJson();
  Map<String, Object?> dictOf(Map<Object?, Object?> variant) =>
      {for (final entry in variant.entries) '${entry.key}': entry.value};

  final out = <String, Object?>{};
  for (final entry in (baseline ?? {}).entries) {
    final key = _slotKeyOf(entry.key);
    if (key == null) continue;
    final dictKey = '${key.$1}|${key.$2}';
    final slot = entry.value;
    if (slot is List) {
      final items = <Map<String, Object?>>[];
      for (final v in slot) {
        if (v is SlotBaseline) {
          items.add(one(v));
        } else if (v is Map) {
          items.add(dictOf(v));
        }
      }
      if (items.isNotEmpty) out[dictKey] = items;
    } else if (slot is SlotBaseline) {
      out[dictKey] = one(slot);
    } else if (slot is Map) {
      out[dictKey] = dictOf(slot);
    }
  }
  return out;
}

SlotBaseline? _slotFromJson(Object? item, (int, int) slotKey) {
  if (item is! Map) return null;
  try {
    final weekday =
        item.containsKey('weekday') ? _slotIntOrNull(item['weekday']) : slotKey.$1;
    final period =
        item.containsKey('period') ? _slotIntOrNull(item['period']) : slotKey.$2;
    if (weekday == null || period == null) return null;
    final supRaw = item.containsKey('support') ? item['support'] : 0;
    final int support;
    if (supRaw == null ||
        supRaw == false ||
        supRaw == 0 ||
        supRaw == '') {
      support = 0;
    } else {
      final parsed = _slotIntOrNull(supRaw);
      if (parsed == null) return null;
      support = parsed;
    }
    return SlotBaseline(
      weekday: weekday,
      period: period,
      subject: '${item['subject'] ?? ''}',
      teacher: '${item['teacher'] ?? ''}',
      room: shortRoomName('${item['room'] ?? ''}'),
      startMin: _slotIntOrNull(item['start_min']),
      support: support,
    );
  } catch (_) {
    return null;
  }
}

/// Restores a baseline serialized with [baselineToDict].
Map<(int, int), Object> baselineFromDict(Map<Object?, Object?>? data) {
  final baseline = <(int, int), Object>{};
  for (final entry in (data ?? {}).entries) {
    final parts = '${entry.key}'.split('|');
    if (parts.length != 2) continue;
    final weekday = _slotIntOrNull(parts[0].trim());
    final period = _slotIntOrNull(parts[1].trim());
    if (weekday == null || period == null) continue;
    final slotKey = (weekday, period);
    final item = entry.value;
    if (item is List) {
      final variants = <SlotBaseline>[];
      for (final v in item) {
        final one = _slotFromJson(v, slotKey);
        if (one != null) variants.add(one);
      }
      if (variants.length == 1) {
        baseline[slotKey] = variants.first;
      } else if (variants.isNotEmpty) {
        baseline[slotKey] = variants;
      }
    } else {
      final single = _slotFromJson(item, slotKey);
      if (single != null) baseline[slotKey] = single;
    }
  }
  return baseline;
}

/// Czech / English weekday names (full + common abbreviations) to
/// ``date.weekday()``. The scraped stable ("Stálý rozvrh") view may label
/// days with names (``Pondělí``) instead of dates.
const Map<String, int> _weekdayNames = {
  'pondělí': 0,
  'pondeli': 0,
  'po': 0,
  'monday': 0,
  'mon': 0,
  'úterý': 1,
  'utery': 1,
  'út': 1,
  'ut': 1,
  'tuesday': 1,
  'tue': 1,
  'tues': 1,
  'středa': 2,
  'streda': 2,
  'st': 2,
  'wednesday': 2,
  'wed': 2,
  'čtvrtek': 3,
  'ctvrtek': 3,
  'čt': 3,
  'ct': 3,
  'thursday': 3,
  'thu': 3,
  'thur': 3,
  'thurs': 3,
  'pátek': 4,
  'patek': 4,
  'pá': 4,
  'pa': 4,
  'friday': 4,
  'fri': 4,
  'sobota': 5,
  'so': 5,
  'saturday': 5,
  'sat': 5,
  'neděle': 6,
  'nedele': 6,
  'ne': 6,
  'ned': 6,
  'sunday': 6,
  'sun': 6,
};

/// Weekday for a timetable day key: a date or a weekday name.
int? _weekdayOf(Object? dayKey) {
  final day = parseCzDate(dayKey);
  // Dart weekday is Monday=1; Python weekday() is Monday=0.
  if (day != null) return day.weekday - 1;
  final text = '${dayKey ?? ''}'.split('(').first.trim().toLowerCase();
  return _weekdayNames[text];
}

/// Builds the baseline directly from a scraped stable week.
///
/// The stable ("Stálý") view already shows the template week, so no
/// majority vote is needed — but one slot may hold SEVERAL lessons
/// (split groups sharing a period). Those are kept as a variant list so
/// every group lesson still matches its slot instead of being flagged a
/// change forever. Single-lesson slots stay a plain [SlotBaseline].
/// Day keys may be dates or weekday names (``Pondělí``); unparseable
/// days are skipped.
Map<(int, int), Object> baselineFromStableTimetable(Map<Object?, Object?>? stable) {
  final votes = <(int, int), Map<(String, String, String, int), int>>{};
  final exemplars =
      <(int, int), Map<(String, String, String, int), Map<String, Object?>>>{};
  for (final entry in (stable ?? {}).entries) {
    final dayKey = entry.key;
    final weekday = _weekdayOf(dayKey);
    if (weekday == null) continue;
    final lessons = entry.value;
    if (lessons is! List) continue;
    for (final raw in lessons) {
      if (raw is! Map) continue;
      final period = periodOf(raw, dayKey);
      if (period == null) continue;
      final parsed = Lesson.fromLegacy(_readMap(raw), dayKey);
      final span = lessonClock(raw, dayKey);
      final fingerprint = (
        _normText(parsed.subject),
        _surname(parsed.teacher),
        _normText(parsed.room),
        span != null ? span.$1 : -1,
      );
      final slot = (weekday, period);
      final counter = votes.putIfAbsent(slot, () => {});
      counter[fingerprint] = (counter[fingerprint] ?? 0) + 1;
      exemplars.putIfAbsent(slot, () => {})[fingerprint] ??= {
        'subject': parsed.subject,
        'teacher': parsed.teacher,
        'room': parsed.room,
        'start_min': span?.$1,
      };
    }
  }
  final baseline = <(int, int), Object>{};
  for (final slot in votes.keys) {
    final counter = votes[slot]!;
    final variants = <SlotBaseline>[];
    for (final fingerprint in counter.keys) {
      final exemplar = exemplars[slot]![fingerprint]!;
      variants.add(SlotBaseline(
        weekday: slot.$1,
        period: slot.$2,
        subject: '${exemplar['subject'] ?? ''}',
        teacher: '${exemplar['teacher'] ?? ''}',
        room: '${exemplar['room'] ?? ''}',
        startMin: exemplar['start_min'] as int?,
        support: counter[fingerprint]!,
      ));
    }
    // One lesson per slot is the common case — keep it unwrapped so
    // lookups stay simple. Split-group slots keep every variant.
    baseline[slot] = variants.length == 1 ? variants.first : variants;
  }
  return baseline;
}

/// A 2-int slot key from a baseline map key (record or 2-list).
/// Anything else (including serialized "w|p" strings) is not a live key.
(int, int)? _slotKeyOf(Object? key) {
  Object? first;
  Object? second;
  if (key is (Object?, Object?)) {
    first = key.$1;
    second = key.$2;
  } else if (key is List && key.length == 2) {
    first = key[0];
    second = key[1];
  } else {
    return null;
  }
  final weekday = _slotIntOrNull(first);
  final period = _slotIntOrNull(second);
  if (weekday == null || period == null) return null;
  return (weekday, period);
}

/// Period number for a bare clock (``"13:40 - 14:25"``) via the baseline.
///
/// Scraped ``removed`` (cancelled) rows carry no period number — only a
/// clock. When exactly one stable slot on that weekday starts at the
/// same minute, that slot's period is unambiguous. Multiple or zero
/// matches yield null (callers fall back to the notice heuristic).
/// Never raises.
int? _periodByClock(
    Map<Object?, Object?>? baseline, int weekday, (int, int)? span) {
  try {
    if (baseline == null || baseline.isEmpty || span == null) return null;
    final start = span.$1;
    final hits = <int>{};
    for (final entry in baseline.entries) {
      final key = _slotKeyOf(entry.key);
      if (key == null) continue;
      if (key.$1 != weekday) continue;
      for (final variant in _variants(entry.value)) {
        if (variant.startMin == start) hits.add(key.$2);
      }
    }
    if (hits.length == 1) return hits.single;
  } catch (_) {
    // Ignore.
  }
  return null;
}

/// Completes scraped removed rows and class events from the stable baseline.
///
/// Cancelled lessons (and class events) arrive with a bare clock and short names; matching
/// their start time against the stable day fills the period number (so
/// the timetable grid can place them) and completes subject, teacher
/// and room from the closest stable variant. Returns the enriched row
/// count. Never raises.
int backfillStableFacts(Map<Object?, Object?>? timetable, Map<Object?, Object?>? baseline) {
  if (timetable == null ||
      timetable.isEmpty ||
      baseline == null ||
      baseline.isEmpty) {
    return 0;
  }
  var enriched = 0;
  for (final entry in timetable.entries) {
    final dayKey = entry.key;
    DateTime? day;
    try {
      day = parseCzDate(dayKey);
    } catch (_) {
      continue;
    }
    if (day == null) continue;
    final lessons = entry.value;
    if (lessons is! List) continue;
    for (final raw in lessons) {
      if (raw is! Map) continue;
      try {
        final type = _orEmpty(raw['type']).trim().toLowerCase();
        if (type != 'removed' && type != 'event') continue;
        final span = lessonClock(raw, dayKey);
        if (span == null) continue;
        var period = periodOf(raw, dayKey);
        period ??= _periodByClock(baseline, day.weekday - 1, span);
        if (period == null) continue;
        final slot = baseline[(day.weekday - 1, period)];
        final variant = closestVariant(slot, raw, dayKey);
        raw['period'] = period;
        if (variant != null) {
          // The stable slot is ground truth for *what* was
          // cancelled; removedinfo stays in notice/change.
          raw['subject'] = variant.subject;
          raw['teacher'] = variant.teacher;
          raw['room'] = variant.room;
        }
        enriched++;
      } catch (_) {
        continue;
      }
    }
  }
  return enriched;
}

/// Feed badges (Suplovani view) mapped to timetable change codes.
const Map<String, String> feedBadgeCodes = {
  'M': 'RoomChanged',
  'O': 'Removed',
  'S': 'Substitution',
  'N': 'Added',
  'A': 'Absence',
};

/// Timetable (day_key, lessons) whose date equals [day].
(Object?, List<Object?>) _feedDayLessons(Map<Object?, Object?>? timetable, DateTime day) {
  for (final entry in (timetable ?? {}).entries) {
    try {
      if (parseCzDate(entry.key) == day) {
        final lessons = entry.value;
        return (
          entry.key,
          lessons is List<Object?> ? lessons : <Object?>[]
        );
      }
    } catch (_) {
      continue;
    }
  }
  return (null, []);
}

/// Stamps Suplovani feed entries onto scraped lessons.
///
/// The feed is the authoritative per-student change list. For every
/// entry the matching actual lesson (same day + period, else same
/// day + clock) gains the feed's change code and description when it
/// does not already carry them, so live classification flags it even
/// when the timetable row arrived without signals. A cancelled (badge
/// O) entry with no matching lesson synthesizes a cancelled shell
/// (later enriched by backfillStableFacts). Returns the number of
/// stamped or synthesized lessons. Never raises.
int applySubstitutionFeed(Map<Object?, Object?>? timetable, List<Object?>? substitutions) {
  if (timetable == null ||
      timetable.isEmpty ||
      substitutions == null ||
      substitutions.isEmpty) {
    return 0;
  }
  var stamped = 0;
  for (final entry in substitutions) {
    try {
      if (entry is! Map) continue;
      final day = parseCzDate(entry['day']);
      if (day == null) continue;
      int? period;
      try {
        period = _slotIntOrNull(entry['period']);
      } catch (_) {
        period = null;
      }
      final badge = _orEmpty(entry['badge']).trim().toUpperCase();
      final code = feedBadgeCodes[badge] ?? '';
      final description = _orEmpty(entry['description']).trim();
      final clockSpan = parseTimeRange(entry['time']);
      int? start;
      try {
        if (clockSpan != null) start = clockSpan.$1 * 60 + clockSpan.$2;
      } catch (_) {
        start = null;
      }
      final (dayKey, lessons) = _feedDayLessons(timetable, day);
      final candidates = <Map<Object?, Object?>>[];
      for (final raw in lessons) {
        if (raw is! Map) continue;
        if (period != null) {
          int? lessonPeriod;
          try {
            lessonPeriod = periodOf(raw, dayKey);
          } catch (_) {
            lessonPeriod = null;
          }
          if (lessonPeriod != null) {
            if (lessonPeriod == period) candidates.add(raw);
            continue;
          }
          // Lesson period unknown (e.g. a bare-clock cancelled
          // row awaiting backfill): fall through to the clock.
        }
        if (start != null) {
          (int, int)? lessonClockValue;
          try {
            lessonClockValue = lessonClock(raw, dayKey);
          } catch (_) {
            lessonClockValue = null;
          }
          if (lessonClockValue != null && lessonClockValue.$1 == start) {
            candidates.add(raw);
          }
        }
      }
      // A swapped / moved slot holds both the removed original and the
      // lesson taught instead: a cancel entry belongs to the removed
      // row, any other entry to the taught lesson.
      Map<Object?, Object?>? match;
      for (final c in candidates) {
        final isRemoved =
            _orEmpty(c['type']).trim().toLowerCase() == 'removed';
        if (isRemoved == (badge == 'O')) {
          match = c;
          break;
        }
      }
      if (match == null && candidates.isNotEmpty) {
        if (badge != 'O') {
          match = candidates.first;
        } else {
          // Only taught lessons here: one carrying its own change
          // code (swap, substitution, room move) is the
          // replacement and still takes place — never cancel it.
          for (final c in candidates) {
            final infoCode =
                _orEmpty(c['infoChangeCode']).trim().toLowerCase();
            if (infoCode == '' || infoCode == 'nochange') {
              match = c;
              break;
            }
          }
        }
      }
      if (match == null) {
        if (badge != 'O' || dayKey == null) {
          // Never invent a day that was not scraped this run: the
          // cache merge would let that one-lesson shell replace
          // the day's known lessons (absences included).
          continue;
        }
        final dayLessons = timetable[dayKey];
        if (dayLessons is! List) continue;
        final shell = <String, Object?>{
          'subject': _orEmpty(entry['subject_short']).trim(),
          'teacher': '',
          'room': '',
          'time': _orEmpty(entry['time']).trim(),
          'date': dayKey,
          'notice': description,
          'change': description,
          'status': 'cancelled',
          'type': 'removed',
          'removedinfo': description,
          'infoChangeCode': 'Removed',
          'changeBadgeChar': 'O',
        };
        if (period != null) shell['period'] = period;
        dayLessons.add(shell);
        stamped++;
        continue;
      }
      var changed = false;
      if (badge == 'O') {
        String status;
        try {
          status = Lesson.fromLegacy(_readMap(match), dayKey).status;
        } catch (_) {
          status = '';
        }
        if (status != 'cancelled') {
          match['status'] = 'cancelled';
          match['type'] = 'removed';
          if (description.isNotEmpty &&
              !'${match['removedinfo'] ?? ''}'.contains(description)) {
            match['removedinfo'] = description;
          }
          changed = true;
        }
      } else {
        if (code.isNotEmpty &&
            _orEmpty(match['infoChangeCode']).trim().isEmpty) {
          match['infoChangeCode'] = code;
          changed = true;
        }
      }
      if (description.isNotEmpty) {
        final notice = _orEmpty(match['notice']);
        if (!notice.contains(description)) {
          match['notice'] =
              notice.isEmpty ? description : _stripPipes('$notice | $description');
          changed = true;
        }
      }
      if (changed) stamped++;
    } catch (_) {
      continue;
    }
  }
  return stamped;
}

/// Python `" | ".join(...).strip(" |")`: strips any run of spaces and
/// pipes from both ends (interior separators are kept).
String _stripPipes(String text) =>
    text.replaceAll(RegExp(r'^[ |]+|[ |]+$'), '');

/// Normalizes a baseline slot to a variant list (split-group safe).
///
/// Serialized dicts (see [baselineToDict]) do NOT match here — only
/// live [SlotBaseline] values do, so dict baselines must go through
/// [baselineFromDict] first.
List<SlotBaseline> _variants(Object? slotValue) {
  if (slotValue is List) {
    return [for (final v in slotValue) if (v is SlotBaseline) v];
  }
  if (slotValue is SlotBaseline) return [slotValue];
  return [];
}

/// Field names where a parsed lesson differs from one stable variant.
List<String> _fieldDiffs(
    Lesson parsed, int? clockStart, SlotBaseline variant) {
  final changed = <String>[];
  if (_normText(parsed.subject) != _normText(variant.subject)) {
    changed.add('subject');
  }
  if (_surname(parsed.teacher) != _surname(variant.teacher)) {
    changed.add('teacher');
  }
  if (_normText(parsed.room) != _normText(variant.room)) {
    changed.add('room');
  }
  if (clockStart != null &&
      variant.startMin != null &&
      clockStart != variant.startMin) {
    changed.add('time');
  }
  return changed;
}

/// The stable variant a lesson resembles most (fewest field diffs).
///
/// Used to render "usual vs actual" for split-group slots; null when the
/// slot has no usable baseline.
SlotBaseline? closestVariant(Object? slotValue, Map<Object?, Object?>? raw,
    [Object? day]) {
  final variants = _variants(slotValue);
  if (variants.isEmpty) return null;
  final parsed = Lesson.fromLegacy(_readMap(raw), day);
  final span = lessonClock(raw, day);
  final start = span?.$1;
  var best = variants.first;
  var bestLen = _fieldDiffs(parsed, start, best).length;
  for (final variant in variants.skip(1)) {
    final len = _fieldDiffs(parsed, start, variant).length;
    if (len < bestLen) {
      best = variant;
      bestLen = len;
    }
  }
  return best;
}

/// Renders the baseline as plain lesson dicts on one Mon–Sun week.
///
/// Used for the "Stálý" template view and as the fallback day plan when
/// no concrete week was fetched. [monday] anchors the week (any date
/// in the target week works); defaults to this week. Lesson dicts carry
/// subject/teacher/room plus ``"<period> (<HH:MM>)"`` clocks (start only
/// — the baseline stores no end times), so period parsing and the grid
/// work unchanged while clock comparison stays skipped.
Map<DateTime, List<Map<String, Object?>>> stableTemplateWeek(Map<Object?, Object?>? baseline,
    [DateTime? monday]) {
  DateTime anchor;
  if (monday == null) {
    final today = clock.now();
    anchor = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: today.weekday - 1));
  } else {
    anchor = DateTime(monday.year, monday.month, monday.day)
        .subtract(Duration(days: monday.weekday - 1));
  }
  final days = <DateTime, List<Map<String, Object?>>>{};
  for (final entry in (baseline ?? {}).entries) {
    final key = _slotKeyOf(entry.key);
    if (key == null) continue;
    if (key.$1 < 0 || key.$1 > 6) continue;
    final slotValue = entry.value;
    final variants = slotValue is List ? slotValue : [slotValue];
    for (final variant in variants) {
      String subject;
      String teacher;
      String room;
      int? start;
      if (variant is SlotBaseline) {
        subject = variant.subject;
        teacher = variant.teacher;
        room = variant.room;
        start = variant.startMin;
      } else if (variant is Map) {
        subject = '${variant['subject'] ?? ''}';
        teacher = '${variant['teacher'] ?? ''}';
        room = shortRoomName('${variant['room'] ?? ''}');
        start = _slotIntOrNull(variant['start_min']);
      } else {
        continue;
      }
      final day = anchor.add(Duration(days: key.$1));
      (days[day] ??= []).add({
        'subject': subject,
        'teacher': teacher,
        'room': room,
        'time': _clockLabel(key.$2, start),
      });
    }
  }
  for (final lessons in days.values) {
    lessons.sort(
        (a, b) => (periodOf(a) ?? 999).compareTo(periodOf(b) ?? 999));
  }
  final ordered = days.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return Map.fromEntries(ordered);
}

/// Classification of one actual lesson against the stable baseline.
class LessonDiff {
  /// True when the lesson is a real schedule change (not a mere note).
  final bool isChange;

  /// Changed fields: subject/teacher/room/time/status, or the pseudo
  /// markers notice (no-baseline keyword hit), added (lesson in a free
  /// slot) and missing (stable slot with no actual lesson).
  final List<String> changed;

  /// Teacher description — always shown, never a change by itself.
  final String note;

  LessonDiff({
    this.isChange = false,
    List<String>? changed,
    this.note = '',
  }) : changed = changed ?? [];

  factory LessonDiff.fromJson(Map<String, Object?> json) => LessonDiff(
        isChange: json['isChange'] == true,
        changed: [
          for (final c in (json['changed'] as List<Object?>? ?? [])) '$c'
        ],
        note: '${json['note'] ?? ''}',
      );

  Map<String, Object?> toJson() => {
        'isChange': isChange,
        'changed': changed,
        'note': note,
      };

  LessonDiff copyWith({
    bool? isChange,
    List<String>? changed,
    String? note,
  }) =>
      LessonDiff(
        isChange: isChange ?? this.isChange,
        changed: changed ?? this.changed,
        note: note ?? this.note,
      );
}

/// Compares one lesson against the stable baseline.
///
/// A bare teacher note (description) with identical subject/teacher/room/
/// time is a *note*, not a change. Attendance states of the student
/// (absent/late/early/excused) are likewise not schedule changes — they
/// belong to excuses, not to "week changes". Cancelled lessons and real
/// field differences are changes. Split-group slots (several stable
/// variants) match when the lesson equals ANY variant.
///
/// [complete] marks a complete template-week baseline (scraped "Stálý"
/// view): an actual lesson in a slot the template leaves empty is an
/// ``added`` change even without signals. Without a complete baseline an
/// empty slot only means "no data", so the notice-keyword heuristic
/// decides instead.
LessonDiff classifyLesson(Map<Object?, Object?>? raw,
    [Object? day, Map<Object?, Object?>? baseline, bool complete = false]) {
  final parsed = Lesson.fromLegacy(_readMap(raw), day);
  final note = parsed.change;
  final status = parsed.status.toLowerCase();

  if (status == 'cancelled') {
    return LessonDiff(isChange: true, changed: ['status'], note: note);
  }

  final rawMap = raw is Map ? raw : <String, Object?>{};
  final infoCode = _orEmpty(rawMap['infoChangeCode']).trim().toLowerCase();
  // Bakalari's own verdict: an explicit change code (e.g. RoomChanged), a
  // "removed" (cancelled) row or a class event is a change even when the
  // teacher notice is empty and no baseline is available to diff against.
  final flagged =
      _orEmpty(rawMap['type']).trim().toLowerCase() == 'removed' ||
          _orEmpty(rawMap['type']).trim().toLowerCase() == 'event' ||
          (infoCode.isNotEmpty && infoCode != 'nochange');

  final dayObj = parsed.day;
  var period = parsed.period;
  if (period == null && dayObj != null && baseline != null) {
    // Cancelled rows carry a bare clock ("13:40 - 14:25") with no
    // period number — resolve the slot via the stable day's clocks.
    try {
      period = _periodByClock(
          baseline, dayObj.weekday - 1, lessonClock(rawMap, day));
    } catch (_) {
      period = null;
    }
  }
  if (dayObj == null ||
      period == null ||
      baseline == null ||
      baseline.isEmpty) {
    // No baseline to diff against: the teacher note, or Bakalari's
    // own change flag, decides. Negated notices ("Neodpadá - beze
    // změny") embed a keyword stem but mean no change (same guard as
    // models.cancelNegated).
    final lowered = note.toLowerCase();
    if (flagged ||
        (note.isNotEmpty &&
            !cancelNegated(note) &&
            changeKeywords.any(lowered.contains))) {
      return LessonDiff(isChange: true, changed: ['notice'], note: note);
    }
    return LessonDiff(isChange: false, changed: [], note: note);
  }

  final slot = baseline[(dayObj.weekday - 1, period)];
  final variants = _variants(slot);
  if (variants.isEmpty) {
    if (complete) {
      // Complete template week: the slot is a free period, so any
      // actual lesson there is an added hour — even with no notice
      // or change code on it.
      return LessonDiff(isChange: true, changed: ['added'], note: note);
    }
    final lowered = note.toLowerCase();
    if (flagged ||
        (note.isNotEmpty &&
            !cancelNegated(note) &&
            changeKeywords.any(lowered.contains))) {
      return LessonDiff(isChange: true, changed: ['notice'], note: note);
    }
    return LessonDiff(isChange: false, changed: [], note: note);
  }

  final span = lessonClock(raw is Map ? raw : null, day);
  final start = span?.$1;
  final diffs = [for (final v in variants) _fieldDiffs(parsed, start, v)];
  var best = diffs.first;
  for (final d in diffs.skip(1)) {
    if (d.length < best.length) best = d;
  }
  if (best.isEmpty) {
    if (flagged) {
      return LessonDiff(isChange: true, changed: ['notice'], note: note);
    }
    return LessonDiff(isChange: false, changed: [], note: note);
  }
  return LessonDiff(isChange: true, changed: best, note: note);
}

/// Stable slots with no actual lesson on a fetched day.
///
/// Complete template weeks only: every fetched school day is expected to
/// carry each of its weekday slots, so a slot with no actual lesson of
/// that period is a ``missing`` change. Split-group slots (variant lists)
/// count as covered when ANY variant's period is present — one of the
/// rooms being taught means no change. Cancelled rows already carry their
/// backfilled period and count as present (they are flagged separately as
/// a status change). Never raises.
List<Map<String, Object?>> _missingChanges(Map<Object?, Object?> timetable, Map<Object?, Object?> baseline) {
  final out = <Map<String, Object?>>[];
  for (final entry in timetable.entries) {
    DateTime? day;
    try {
      day = parseCzDate(entry.key);
    } catch (_) {
      continue;
    }
    if (day == null) continue;
    final present = <int>{};
    final lessons = entry.value;
    if (lessons is List) {
      for (final raw in lessons) {
        if (raw is! Map) continue;
        int? period;
        try {
          period = periodOf(raw, entry.key);
        } catch (_) {
          period = null;
        }
        if (period != null) present.add(period);
      }
    }
    for (final slotEntry in baseline.entries) {
      final key = _slotKeyOf(slotEntry.key);
      if (key == null) continue;
      if (key.$1 != day.weekday - 1 || present.contains(key.$2)) continue;
      final variants = _variants(slotEntry.value);
      if (variants.isEmpty) continue;
      final first = variants.first;
      final lesson = {
        'subject': first.subject,
        'teacher': first.teacher,
        'room': first.room,
        'time': _clockLabel(key.$2, first.startMin),
        'date': entry.key,
        'period': key.$2,
        'group': '',
        'theme': '',
        'notice': '',
        'status': '',
      };
      out.add({
        'day_key': entry.key,
        'day': day,
        'lesson': lesson,
        'diff': LessonDiff(isChange: true, changed: ['missing'], note: ''),
      });
    }
  }
  return out;
}

/// Real schedule changes across the timetable (notes excluded).
///
/// Each item holds day_key, day, lesson and diff. Without a [baseline]
/// Bakaláři's own change flags and notices decide. With ``complete=True``
/// (scraped template week) an actual lesson in a free slot is an
/// ``added`` change and a stable slot with no actual lesson on a fetched
/// day is a ``missing`` change.
List<Map<String, Object?>> iterChanges(Map<Object?, Object?>? timetable,
    [Map<Object?, Object?>? baseline, bool complete = false]) {
  final base = baseline ?? {};
  final out = <Map<String, Object?>>[];
  for (final entry in (timetable ?? {}).entries) {
    final dayKey = entry.key;
    final day = parseCzDate(dayKey);
    final lessons = entry.value;
    if (lessons is! List) continue;
    for (final raw in lessons) {
      if (raw is! Map) continue;
      final diff = classifyLesson(raw, dayKey, base, complete);
      if (diff.isChange) {
        out.add({
          'day_key': dayKey,
          'day': day,
          'lesson': raw,
          'diff': diff,
        });
      }
    }
  }
  if (complete && base.isNotEmpty) {
    try {
      out.addAll(_missingChanges(timetable ?? {}, base));
    } catch (_) {
      // Ignore.
    }
  }
  return out;
}

/// Lessons carrying a teacher note that is NOT a schedule change.
List<Map<String, Object?>> iterNotes(Map<Object?, Object?>? timetable,
    [Map<Object?, Object?>? baseline, bool complete = false]) {
  final base = baseline ?? {};
  final out = <Map<String, Object?>>[];
  for (final entry in (timetable ?? {}).entries) {
    final dayKey = entry.key;
    final day = parseCzDate(dayKey);
    final lessons = entry.value;
    if (lessons is! List) continue;
    for (final raw in lessons) {
      if (raw is! Map) continue;
      final diff = classifyLesson(raw, dayKey, base, complete);
      if (!diff.isChange && diff.note.isNotEmpty) {
        out.add({
          'day_key': dayKey,
          'day': day,
          'lesson': raw,
          'diff': diff,
        });
      }
    }
  }
  return out;
}
