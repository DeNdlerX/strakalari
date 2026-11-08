import 'format.dart';
import 'lesson_model.dart';

/// Schedule comparison + day-resolution logic ported from
/// `strakalari/core/schedule.py`.
///
/// Covers what the today/timetable screens need: `parseTimeRange`,
/// `lessonClock`, `resolveDayLessons`, `SlotBaseline`,
/// `stableTemplateWeek`, `classifyLesson`, `closestVariant`,
/// `iterChanges`, `iterNotes` (with `_missingChanges`).
///
/// The stable baseline is carried as `Map<String, List<SlotBaseline>>`
/// keyed `'$weekday|$period'` (weekday Monday=0 like Python's
/// `date.weekday()`), decoded from the same JSON the Python cache holds.

// -- time ranges ------------------------------------------------------------

/// Parses `8:00 - 8:45` (also inside `1. 8:00 - 8:45` /
/// `3 (10:05 - 10:50)`) — like `schedule.parse_time_range`.
/// Returns `(startHour, startMin, endHour, endMin)` or null.
({int sh, int sm, int eh, int em})? parseTimeRange(Object? text) {
  if (text == null) return null;
  final s = '$text';
  if (s.isEmpty) return null;
  final m = RegExp(
          r'(\d{1,2})\s*:\s*(\d{2})\s*(?:-|–|—|do)\s*(\d{1,2})\s*:\s*(\d{2})')
      .firstMatch(s);
  if (m == null) return null;
  final sh = int.tryParse(m.group(1)!);
  final sm = int.tryParse(m.group(2)!);
  final eh = int.tryParse(m.group(3)!);
  final em = int.tryParse(m.group(4)!);
  if (sh == null || sm == null || eh == null || em == null) return null;
  if (!(sh >= 0 && sh <= 23 && eh >= 0 && eh <= 23 && sm >= 0 && sm <= 59 && em >= 0 && em <= 59)) {
    return null;
  }
  return (sh: sh, sm: sm, eh: eh, em: em);
}

/// `(startMinutes, endMinutes)` since midnight for a lesson dict —
/// like `schedule.lesson_clock`.
({int start, int end})? lessonClock(Map<String, Object?> raw,
    [Object? day]) {
  final parsed = LessonRow.fromLegacy(raw, day);
  final span = parseTimeRange(parsed.time);
  if (span == null) return null;
  final start = span.sh * 60 + span.sm;
  final end = span.eh * 60 + span.em;
  if (end <= start) return null;
  return (start: start, end: end);
}

List<({int start, int end, Map<String, Object?> raw})> _clocked(
    List<Object?> lessons, Object? day) {
  final out = <({int start, int end, Map<String, Object?> raw})>[];
  for (final item in lessons) {
    if (item is! Map) continue;
    final raw = item.cast<String, Object?>();
    if (LessonRow.fromLegacy(raw, day).status == 'cancelled') continue;
    final clock = lessonClock(raw, day);
    if (clock != null) out.add((start: clock.start, end: clock.end, raw: raw));
  }
  out.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.end.compareTo(b.end);
  });
  return out;
}

/// Splits one day into running / upcoming lessons for `now` —
/// like `schedule.resolve_day_lessons`. Phase is one of
/// `empty | before | running | between | done`.
({
  String phase,
  Map<String, Object?>? current,
  Map<String, Object?>? upcoming,
}) resolveDayLessons(List<Object?> dayLessons, DateTime now,
    [Object? day]) {
  final nowMin = now.hour * 60 + now.minute;
  final clocked = _clocked(dayLessons, day);
  if (clocked.isEmpty) {
    return (phase: 'empty', current: null, upcoming: null);
  }
  for (final item in clocked) {
    if (item.start <= nowMin && nowMin < item.end) {
      return (phase: 'running', current: item.raw, upcoming: null);
    }
  }
  final upcoming = [for (final c in clocked) if (c.start > nowMin) c];
  if (upcoming.isEmpty) {
    return (phase: 'done', current: null, upcoming: null);
  }
  if (nowMin < clocked.first.start) {
    return (phase: 'before', current: null, upcoming: upcoming.first.raw);
  }
  return (phase: 'between', current: null, upcoming: upcoming.first.raw);
}

// -- stable baseline --------------------------------------------------------

/// The stable lesson for one (weekday, period) slot —
/// like `schedule.SlotBaseline`.
class SlotBaseline {
  final int weekday;
  final int period;
  final String subject;
  final String teacher;
  final String room;
  final int? startMin;

  const SlotBaseline({
    required this.weekday,
    required this.period,
    this.subject = '',
    this.teacher = '',
    this.room = '',
    this.startMin,
  });

  factory SlotBaseline.fromMap(Map<String, Object?> map) {
    int? toInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}');
    }

    return SlotBaseline(
      weekday: toInt(map['weekday']) ?? 0,
      period: toInt(map['period']) ?? 0,
      subject: '${map['subject'] ?? ''}',
      teacher: '${map['teacher'] ?? ''}',
      room: '${map['room'] ?? ''}',
      startMin: toInt(map['start_min'] ?? map['startMin']),
    );
  }
}

/// Baseline key `'$weekday|$period'`.
String slotKey(int weekday, int period) => '$weekday|$period';

/// Renders the baseline as plain lesson dicts on one Mon–Sun week —
/// like `schedule.stable_template_week`. Lesson dicts carry
/// subject/teacher/room plus `"<period> (<HH:MM>)"` clocks (start only).
Map<DateTime, List<Map<String, Object?>>> stableTemplateWeek(
    Map<String, List<SlotBaseline>> baseline, DateTime monday) {
  final mon = DateTime(monday.year, monday.month, monday.day)
      .subtract(Duration(days: monday.weekday - 1));
  final days = <DateTime, List<Map<String, Object?>>>{};
  baseline.forEach((key, variants) {
    final parts = key.split('|');
    if (parts.length != 2) return;
    final weekday = int.tryParse(parts[0]);
    final period = int.tryParse(parts[1]);
    if (weekday == null || period == null) return;
    if (weekday < 0 || weekday > 6) return;
    for (final v in variants) {
      final start = v.startMin;
      final timeLabel = start != null
          ? '$period (${start ~/ 60}:${(start % 60).toString().padLeft(2, '0')})'
          : '$period';
      final day = mon.add(Duration(days: weekday));
      (days[day] ??= []).add({
        'subject': v.subject,
        'teacher': v.teacher,
        'room': v.room,
        'time': timeLabel,
      });
    }
  });
  for (final lessons in days.values) {
    lessons.sort((a, b) {
      final pa = schedulePeriodOf(a, null) ?? 999;
      final pb = schedulePeriodOf(b, null) ?? 999;
      return pa.compareTo(pb);
    });
  }
  final sorted = Map.fromEntries(days.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key)));
  return sorted;
}

/// Period resolution with the scraped `hourIndex` fallback —
/// like `schedule._period_of`.
int? schedulePeriodOf(Map<String, Object?> raw, Object? day) {
  final parsed = LessonRow.fromLegacy(raw, day);
  int? num = parsed.period ?? extractLessonNum(parsed.time);
  if (num == null) {
    final hi = raw['hourIndex'];
    if (hi != null) {
      final candidate = (hi is int ? hi : int.tryParse('$hi') ?? 0) - 2;
      if (candidate >= 1 && candidate <= 15) num = candidate;
    }
  }
  return num;
}

// -- classification ---------------------------------------------------------

/// Notice keywords that — without any baseline to compare against —
/// still mean a real schedule change.
const List<String> changeKeywords = [
  'supl', 'substitut', 'změn', 'zmen', 'odpad', 'zruš', 'zrus',
  'vyjm', 'vynat', 'vyňat', 'přid', 'prid',
  'přesun', 'presun',
  'náhrad', 'nahrad', 'cancel', 'moved',
];

/// Classification of one actual lesson against the stable baseline —
/// like `schedule.LessonDiff`.
class LessonDiff {
  /// True for real schedule changes (teacher notes excluded).
  final bool isChange;

  /// Changed fields: subject/teacher/room/time/status + notice/added/missing.
  final List<String> changed;

  /// Teacher description — always shown, never a change by itself.
  final String note;

  const LessonDiff({
    this.isChange = false,
    this.changed = const [],
    this.note = '',
  });
}

String _normText(Object? value) => '${value ?? ''}'.trim().toLowerCase();

String _surnameKey(Object? fullName) =>
    teacherSurname(fullName).toLowerCase();

List<String> _fieldDiffs(
    LessonRow parsed, int? clockStart, SlotBaseline variant) {
  final changed = <String>[];
  if (_normText(parsed.subject) != _normText(variant.subject)) {
    changed.add('subject');
  }
  if (_surnameKey(parsed.teacher) != _surnameKey(variant.teacher)) {
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

/// The stable variant a lesson resembles most (fewest field diffs) —
/// like `schedule.closest_variant`.
SlotBaseline? closestVariant(
    List<SlotBaseline>? variants, Map<String, Object?> raw, Object? day) {
  if (variants == null || variants.isEmpty) return null;
  final parsed = LessonRow.fromLegacy(raw, day);
  final clock = lessonClock(raw, day);
  final start = clock?.start;
  var best = variants.first;
  var bestLen = _fieldDiffs(parsed, start, best).length;
  for (final v in variants.skip(1)) {
    final len = _fieldDiffs(parsed, start, v).length;
    if (len < bestLen) {
      best = v;
      bestLen = len;
    }
  }
  return best;
}

int? _periodByClock(
    Map<String, List<SlotBaseline>> baseline, int weekday, int? start) {
  if (baseline.isEmpty || start == null) return null;
  final hits = <int>{};
  baseline.forEach((key, variants) {
    final parts = key.split('|');
    if (parts.length != 2) return;
    if (int.tryParse(parts[0]) != weekday) return;
    final period = int.tryParse(parts[1]);
    if (period == null) return;
    for (final v in variants) {
      if (v.startMin == start) hits.add(period);
    }
  });
  return hits.length == 1 ? hits.single : null;
}

/// Compares one lesson against the stable baseline —
/// like `schedule.classify_lesson`.
LessonDiff classifyLesson(Map<String, Object?> raw,
    {Object? day,
    Map<String, List<SlotBaseline>>? baseline,
    bool complete = false}) {
  final parsed = LessonRow.fromLegacy(raw, day);
  final note = parsed.change;
  final status = parsed.status.toLowerCase();

  if (status == 'cancelled') {
    return LessonDiff(isChange: true, changed: const ['status'], note: note);
  }

  final infoCode = '${raw['infoChangeCode'] ?? ''}'.trim().toLowerCase();
  final flagged =
      '${raw['type'] ?? ''}'.trim().toLowerCase() == 'removed' ||
      '${raw['type'] ?? ''}'.trim().toLowerCase() == 'event' ||
      (infoCode.isNotEmpty && infoCode != 'nochange');

  final dayObj = parsed.day;
  int? period = parsed.period;
  if (period == null && dayObj != null && baseline != null) {
    // Cancelled rows carry a bare clock with no period number — resolve
    // the slot via the stable day's clocks.
    try {
      period = _periodByClock(
          baseline, dayObj.weekday - 1, lessonClock(raw, day)?.start);
    } catch (_) {
      period = null;
    }
  }
  LessonDiff noticeOrNote() {
    final lowered = note.toLowerCase();
    if (flagged ||
        (note.isNotEmpty &&
            !cancelNegated(note) &&
            changeKeywords.any(lowered.contains))) {
      return LessonDiff(isChange: true, changed: const ['notice'], note: note);
    }
    return LessonDiff(isChange: false, note: note);
  }

  if (dayObj == null || period == null || baseline == null) {
    return noticeOrNote();
  }
  final variants = baseline[slotKey(dayObj.weekday - 1, period)] ?? const [];
  if (variants.isEmpty) {
    if (complete) {
      // Complete template week: the slot is a free period, so any
      // actual lesson there is an added hour.
      return LessonDiff(isChange: true, changed: const ['added'], note: note);
    }
    return noticeOrNote();
  }
  final clock = lessonClock(raw, day);
  final start = clock?.start;
  var best = _fieldDiffs(parsed, start, variants.first);
  for (final v in variants.skip(1)) {
    final diffs = _fieldDiffs(parsed, start, v);
    if (diffs.length < best.length) best = diffs;
  }
  if (best.isEmpty) {
    if (flagged) {
      return LessonDiff(isChange: true, changed: const ['notice'], note: note);
    }
    return LessonDiff(isChange: false, note: note);
  }
  return LessonDiff(isChange: true, changed: best, note: note);
}

/// A changed item: day key, day, lesson and diff —
/// like the `iter_changes` / `iter_notes` dicts.
class ChangeItem {
  final String dayKey;
  final DateTime? day;
  final Map<String, Object?> lesson;
  final LessonDiff diff;
  const ChangeItem(this.dayKey, this.day, this.lesson, this.diff);
}

/// Real schedule changes across the timetable (notes excluded) —
/// like `schedule.iter_changes`.
List<ChangeItem> iterChanges(Map<String, List<Object?>> timetable,
    {Map<String, List<SlotBaseline>>? baseline, bool complete = false}) {
  final base = baseline ?? const <String, List<SlotBaseline>>{};
  final out = <ChangeItem>[];
  timetable.forEach((dayKey, lessons) {
    final day = parseCzDate(dayKey);
    for (final item in lessons) {
      if (item is! Map) continue;
      final raw = item.cast<String, Object?>();
      final diff =
          classifyLesson(raw, day: dayKey, baseline: base, complete: complete);
      if (diff.isChange) out.add(ChangeItem(dayKey, day, raw, diff));
    }
  });
  if (complete && base.isNotEmpty) {
    try {
      out.addAll(_missingChanges(timetable, base));
    } catch (_) {}
  }
  return out;
}

/// Lessons carrying a teacher note that is NOT a schedule change —
/// like `schedule.iter_notes`.
List<ChangeItem> iterNotes(Map<String, List<Object?>> timetable,
    {Map<String, List<SlotBaseline>>? baseline, bool complete = false}) {
  final base = baseline ?? const <String, List<SlotBaseline>>{};
  final out = <ChangeItem>[];
  timetable.forEach((dayKey, lessons) {
    final day = parseCzDate(dayKey);
    for (final item in lessons) {
      if (item is! Map) continue;
      final raw = item.cast<String, Object?>();
      final diff =
          classifyLesson(raw, day: dayKey, baseline: base, complete: complete);
      if (!diff.isChange && diff.note.isNotEmpty) {
        out.add(ChangeItem(dayKey, day, raw, diff));
      }
    }
  });
  return out;
}

/// Stable slots with no actual lesson on a fetched day —
/// like `schedule._missing_changes` (complete template weeks only).
List<ChangeItem> _missingChanges(Map<String, List<Object?>> timetable,
    Map<String, List<SlotBaseline>> baseline) {
  final out = <ChangeItem>[];
  timetable.forEach((dayKey, lessons) {
    final day = parseCzDate(dayKey);
    if (day == null) return;
    final present = <int>{};
    for (final item in lessons) {
      if (item is! Map) continue;
      final period = schedulePeriodOf(item.cast<String, Object?>(), dayKey);
      if (period != null) present.add(period);
    }
    baseline.forEach((key, variants) {
      final parts = key.split('|');
      if (parts.length != 2) return;
      final weekday = int.tryParse(parts[0]);
      final period = int.tryParse(parts[1]);
      if (weekday == null || period == null) return;
      if (weekday != day.weekday - 1 || present.contains(period)) return;
      if (variants.isEmpty) return;
      final first = variants.first;
      final start = first.startMin;
      final timeLabel = start != null
          ? '$period (${start ~/ 60}:${(start % 60).toString().padLeft(2, '0')})'
          : '$period';
      out.add(ChangeItem(
          dayKey,
          day,
          {
            'subject': first.subject,
            'teacher': first.teacher,
            'room': first.room,
            'time': timeLabel,
            'date': dayKey,
            'period': period,
            'group': '',
            'theme': '',
            'notice': '',
            'status': '',
          },
          const LessonDiff(
              isChange: true, changed: ['missing'], note: '')));
    });
  });
  return out;
}
