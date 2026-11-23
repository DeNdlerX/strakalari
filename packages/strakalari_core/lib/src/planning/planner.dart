// Year-aware vacation planner (pure functions — no I/O, no UI).
//
// Port of strakalari/core/planner.py. Answers "which days can I stay home
// this school year without risking my absence limits — and when should I
// take them?".
//
// The model, per semester (term) and subject:
//
// * `total = taught + future` — hours actually taught by the absence
//   closure. `taught` comes from the absence overview (or an estimate),
//   `future` is counted day by day from the concrete fetched weeks and the
//   stable template, so holidays falling on one weekday only shrink the
//   subjects taught that day.
// * `free = limit% * total - missed - planned - buffer` — hours the planner
//   may still hand out. `planned` are lessons on already planned future
//   days off, `buffer = reserve% * future` (at least one lesson, or one
//   double for double-lesson subjects) is kept aside for illness and
//   other unplanned absences. The buffer only covers lessons that are still
//   ahead (the past is known), so it shrinks as the term goes on and budget
//   is released gradually instead of being locked away until the closure.
// * Days are scored by how much scarce budget they burn (hours weighted by
//   `1 / free` of each subject), how many lessons they hold, whether they
//   make a long weekend or bridge a holiday, and whether they fall into the
//   risky final weeks before the closure.
// * The recommended plan spreads the affordable days evenly across the rest
//   of the term (one per window) instead of front-loading the next few days
//   or leaving everything for the last week.
//
// Local mirrors (canonical ports landed in phase 3 alongside this file;
// these stay identical): [normalizeHolidays] and [schoolDaysBetween]
// mirror `forecast.py`; [normalizePlannedEntry] and [entryDays] mirror
// `planned_skips.py`. [canonSubject] is imported from `forecast.dart`
// (same normalization; planner.py calls `canon_subject` from forecast).
import 'dart:math' as math;

import 'package:clock/clock.dart';

import '../models.dart';
import 'forecast.dart' show canonSubject, normalizeHolidays, schoolDaysBetween;
import 'planned_skips.dart' show entryDays, normalizePlannedEntry;
import 'schedule.dart' show SlotBaseline;

/// School days before the closure that the plan avoids (grading crunch,
/// no time left to recover from an unexpected illness).
const int finalWeekDays = 5;

/// The week before that is still allowed, just discouraged.
const int lateWeekDays = 10;

/// Days with at most this many lessons count as "light".
const int lightDayLessons = 4;

const double _eps = 1e-9;

/// Monday=0 .. Sunday=6 (Python `date.weekday()`; Dart's is Monday=1).
int _weekday(DateTime day) => day.weekday - 1;

DateTime _day(DateTime day) => DateTime(day.year, day.month, day.day);

/// Next/previous calendar day. Plain `+ Duration(days: 1)` drifts across
/// DST (a 23h/25h day lands at 23:00/01:00 and breaks midnight
/// comparisons); the constructor form is real date arithmetic like
/// Python's `date + timedelta`.
DateTime _nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);
DateTime _prevDay(DateTime day) => DateTime(day.year, day.month, day.day - 1);

/// Whole calendar days from [a] to [b] (DST-proof: UTC has no transitions).
int _dayDiff(DateTime a, DateTime b) =>
    DateTime.utc(a.year, a.month, a.day)
        .difference(DateTime.utc(b.year, b.month, b.day))
        .inDays;

int? _toInt(Object? value) {
  if (value == null) return null;
  if (value is bool) return value ? 1 : 0;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, Object?> _stringMap(Map<Object?, Object?> raw) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is String) out[entry.key as String] = entry.value;
  }
  return out;
}

// -- planned-skip entries (canonical: planned_skips.dart, like planner.py's -
// `from .planned_skips import entry_days, normalize_planned_entry`) ---------

// -- lesson source -------------------------------------------------------------

/// Which lessons a given date holds.
///
/// Priority: (1) the concrete fetched week for that exact date —
/// substitutions and cancellations win; (2) the stable template for the
/// weekday; (3) the union of loaded weeks for that weekday when no
/// baseline is known. `null` means "unknown" (nothing to go on).
class LessonSource {
  final Map<DateTime, List<Lesson>> concrete = {};
  final Map<int, List<Lesson>> template = {};
  final Map<int, List<Lesson>> union = {};
  bool hasTemplate = false;

  /// [timetable] maps day keys to lesson-dict rows; [stableBaseline] maps
  /// `(weekday, period)` slots (records, 2-lists or `"w|p"` strings) to a
  /// [Lesson], a subject dict or a list of those (split-group variants).
  LessonSource(
      [Map<Object?, Object?>? timetable,
      Map<Object?, Object?>? stableBaseline]) {
    for (final dayEntry in (timetable ?? const {}).entries) {
      final day = parseCzDate(dayEntry.key);
      if (day == null) continue;
      final bucket = concrete.putIfAbsent(day, () => []);
      final rows = dayEntry.value;
      if (rows is! Iterable) continue;
      for (final raw in rows) {
        if (raw is! Map<Object?, Object?> || isClassEvent(raw)) continue;
        final lesson = Lesson.fromLegacy(_stringMap(raw), dayEntry.key);
        // Cancelled lessons and class events cost no absence budget.
        if (lesson.status != 'cancelled' &&
            lesson.subject.trim() != '' &&
            lesson.subject.trim() != '?') {
          bucket.add(lesson);
        }
      }
    }
    for (final slotEntry in (stableBaseline ?? const {}).entries) {
      final slot = _slotKey(slotEntry.key);
      if (slot == null) continue;
      final rawVariants = slotEntry.value;
      final variants =
          rawVariants is List ? rawVariants : [rawVariants];
      final seen = <String>{};
      for (final variant in variants) {
        String subject;
        if (variant is Lesson) {
          subject = variant.subject;
        } else if (variant is SlotBaseline) {
          // Live baseline objects (Python reads any object with
          // `.subject` via hasattr; the serialized dicts go through
          // the Map branch below).
          subject = variant.subject;
        } else if (variant is Map<Object?, Object?>) {
          subject = '${variant['subject'] ?? ''}';
        } else {
          continue;
        }
        final canon = canonSubject(subject);
        // Split-group slots: every distinct subject costs budget
        // once (mirrors schedule.stable_weekly_hours).
        if (canon.isEmpty || seen.contains(canon)) continue;
        seen.add(canon);
        template
            .putIfAbsent(slot.$1, () => [])
            .add(Lesson(subject: subject, period: slot.$2));
      }
    }
    hasTemplate = template.isNotEmpty;
    if (!hasTemplate) {
      // Legacy fallback: one representative week per weekday (the
      // latest loaded one) — merging all weeks would inflate counts.
      final latest = <int, DateTime>{};
      for (final day in concrete.keys) {
        if (_weekday(day) < 5 &&
            (!latest.containsKey(_weekday(day)) ||
                day.isAfter(latest[_weekday(day)]!))) {
          latest[_weekday(day)] = day;
        }
      }
      for (final entry in latest.entries) {
        union[entry.key] = List<Lesson>.of(concrete[entry.value]!);
      }
    }
  }

  List<Lesson>? lessons(DateTime day) {
    if (concrete.containsKey(day)) return List<Lesson>.of(concrete[day]!);
    if (hasTemplate) return List<Lesson>.of(template[_weekday(day)] ?? []);
    if (union.containsKey(_weekday(day))) {
      return List<Lesson>.of(union[_weekday(day)]!);
    }
    return null;
  }

  bool get known => concrete.isNotEmpty || template.isNotEmpty;
}

/// Subjects taught only in back-to-back pairs (double lessons) in the
/// regular week, as `canon -> 2`.
///
/// Reads the stable week (or the representative loaded week without
/// one). A subject qualifies when every run of consecutive periods it
/// has on a weekday is of even length; any single lesson or a lesson
/// without a period number leaves it out.
Map<String, int> lessonBlocks(LessonSource source) {
  final week = source.hasTemplate ? source.template : source.union;
  final runs = <String, List<int>>{};
  final unknown = <String>{};
  for (final lessons in week.values) {
    final periods = <String, Set<int>>{};
    for (final l in lessons) {
      final canon = canonSubject(l.subject);
      if (canon.isEmpty) continue;
      if (l.period == null) {
        unknown.add(canon);
      } else {
        periods.putIfAbsent(canon, () => {}).add(l.period!);
      }
    }
    for (final e in periods.entries) {
      final sorted = e.value.toList()..sort();
      var run = 1;
      for (var i = 1; i <= sorted.length; i++) {
        if (i < sorted.length && sorted[i] == sorted[i - 1] + 1) {
          run += 1;
        } else {
          runs.putIfAbsent(e.key, () => []).add(run);
          run = 1;
        }
      }
    }
  }
  return {
    for (final e in runs.entries)
      if (!unknown.contains(e.key) && e.value.every((r) => r.isEven))
        e.key: 2
  };
}

(int, int)? _slotKey(Object? key) {
  if (key is (int, int)) return (key.$1, key.$2);
  if (key is List && key.length == 2) {
    final weekday = _toInt(key[0]);
    final period = _toInt(key[1]);
    if (weekday == null || period == null) return null;
    return (weekday, period);
  }
  if (key is String) {
    final parts = key.split('|');
    if (parts.length != 2) return null;
    final weekday = int.tryParse(parts[0].trim());
    final period = int.tryParse(parts[1].trim());
    if (weekday == null || period == null) return null;
    return (weekday, period);
  }
  return null;
}

bool _inPeriodRange(Lesson lesson, int? startPeriod, int? endPeriod) {
  if (lesson.period == null) return true;
  if (startPeriod != null && lesson.period! < startPeriod) return false;
  if (endPeriod != null && lesson.period! > endPeriod) return false;
  return true;
}

/// Lessons a planned entry skips, per school day (partial days honored).
///
/// `start_period` limits the first day, `end_period` the last one;
/// middle days are whole. Days before [fromDay] are dropped (their
/// absences are already in the school data).
Map<DateTime, List<Lesson>> entryLessons(
    Map<String, Object?> entry, LessonSource source, Set<DateTime> holidays,
    {DateTime? fromDay}) {
  final norm = normalizePlannedEntry(entry);
  if (norm == null) return {};
  final days = entryDays(norm);
  if (days.isEmpty) return {};
  final startP = norm['start_period'] is int
      ? norm['start_period'] as int
      : _toInt(norm['start_period']);
  final endP = norm['end_period'] is int
      ? norm['end_period'] as int
      : _toInt(norm['end_period']);
  final out = <DateTime, List<Lesson>>{};
  for (final day in days) {
    if (_weekday(day) >= 5 || holidays.contains(day)) continue;
    if (fromDay != null && day.isBefore(_day(fromDay))) continue;
    final lessons = source.lessons(day) ?? [];
    final first = day == days.first ? startP : null;
    final last = day == days.last ? endP : null;
    final picked =
        lessons.where((l) => _inPeriodRange(l, first, last)).toList();
    if (picked.isNotEmpty) out[day] = picked;
  }
  return out;
}

// -- models --------------------------------------------------------------------

/// One subject's absence budget for one term (hours).
class Budget {
  final String name;
  final String canon;
  final double limitPct;
  final double reservePct;
  double currentPct;
  double taught;
  double missed;
  double future;
  double planned;
  final bool blocked; // school flagged the subject unclassifiable
  double weekly; // normal lessons per week (for "tight" checks)
  int peak; // most lessons of this subject on one day (double periods)
  final int block; // 2 = taught only in double lessons (see lessonBlocks)

  Budget({
    required this.name,
    required this.canon,
    required this.limitPct,
    required this.reservePct,
    this.currentPct = 0.0,
    this.taught = 0.0,
    this.missed = 0.0,
    this.future = 0.0,
    this.planned = 0.0,
    this.blocked = false,
    this.weekly = 0.0,
    this.peak = 1,
    this.block = 1,
  });

  /// Roughly how many days holding this subject still fit the budget.
  double get daysLeft => free / math.max(1, peak);

  double get total => math.max(1.0, taught + future);

  /// Hours missable over the whole term before hitting the limit.
  double get schoolCap => limitPct / 100.0 * total;

  /// Illness reserve: `reserve%` of the lessons still ahead, but never
  /// under one lesson (one double for double-lesson subjects) while
  /// lessons remain. A 0 % reserve setting switches it off entirely.
  double get buffer {
    final share = reservePct / 100.0 * future;
    if (reservePct <= 0) return share;
    return math.max(share, math.min(block.toDouble(), future));
  }

  /// Hours the planner may still hand out (can go negative).
  double get free {
    if (blocked) {
      return math.min(0.0, schoolCap - missed - planned - buffer);
    }
    return schoolCap - missed - planned - buffer;
  }

  int get freeHours => math.max(0, (free + _eps).floor());

  /// Hours left before the school limit (buffer included).
  double get schoolLeft => schoolCap - missed - planned;

  /// Final % if every planned day happens and nothing else.
  double get projectedPct => (missed + planned) / total * 100.0;

  /// ok / tight / reserve (eats into the buffer) / over (school limit).
  String get status {
    if (schoolLeft < -_eps) return 'over';
    if (blocked || free < -_eps) return 'reserve';
    if (free < math.max(1.0, peak.toDouble())) return 'tight';
    return 'ok';
  }

  /// Spent share of the term budget vs. share of the term elapsed.
  ///
  /// > 1 means absences so far run faster than an even spread would
  /// allow. `null` early in the term (too little data to judge).
  double? paceRatio(double elapsed) {
    if (elapsed < 0.1 || taught <= 0) return null;
    final planCap =
        math.max(0.0, (limitPct - reservePct)) / 100.0 * total;
    if (planCap <= _eps) return null;
    return (missed / planCap) / elapsed;
  }
}

/// One candidate day off.
class DayOption {
  final DateTime day;
  final String term;
  List<String> lessons;
  Map<String, int> cost; // canon -> hours
  Map<String, String> names; // canon -> display
  int streak; // free block length (days) if taken
  bool finalWeek;
  bool lateWeek;
  bool feasible;
  List<String> blockedBy;
  double score;

  DayOption({
    required this.day,
    required this.term,
    List<String>? lessons,
    Map<String, int>? cost,
    Map<String, String>? names,
    this.streak = 1,
    this.finalWeek = false,
    this.lateWeek = false,
    this.feasible = true,
    List<String>? blockedBy,
    this.score = 0.0,
  })  : lessons = lessons ?? [],
        cost = cost ?? {},
        names = names ?? {},
        blockedBy = blockedBy ?? [];

  int get lessonsCount => lessons.length;

  int get budgetHours => cost.values.fold(0, (a, b) => a + b);

  List<String> get tags {
    final tags = <String>[];
    if (streak >= 4) {
      tags.add('bridge');
    } else if (streak >= 3) {
      tags.add('long_weekend');
    }
    if (cost.isEmpty) {
      tags.add('free');
    } else if (lessonsCount <= lightDayLessons) {
      tags.add('light');
    }
    if (finalWeek) {
      tags.add('final_week');
    } else if (lateWeek) {
      tags.add('late_week');
    }
    return tags;
  }
}

/// A planned entry's share inside one term.
class PlannedDay {
  final Map<String, Object?> entry;
  Map<DateTime, List<String>> days;
  Map<String, int> cost;
  List<String> over; // canon subjects past the school limit
  List<String> reserve; // canon subjects eating the buffer

  PlannedDay({
    required this.entry,
    Map<DateTime, List<String>>? days,
    Map<String, int>? cost,
    List<String>? over,
    List<String>? reserve,
  })  : days = days ?? {},
        cost = cost ?? {},
        over = over ?? [],
        reserve = reserve ?? [];

  int get hours => days.values.fold(0, (a, v) => a + v.length);
}

class ImpactRow {
  final String name;
  final int cost;
  final double freeAfter;
  final double projectedAfter;
  final double limitPct;
  final String level; // ok | reserve | over

  const ImpactRow({
    required this.name,
    required this.cost,
    required this.freeAfter,
    required this.projectedAfter,
    required this.limitPct,
    required this.level,
  });
}

class TermPlan {
  final String key; // "sem1" | "sem2"
  final DateTime start;
  final DateTime close;
  final bool hasData;
  final bool active;
  List<DateTime> schoolDays;
  List<DateTime> remainingDays;
  List<Budget> budgets;
  Map<DateTime, DayOption> options;
  List<PlannedDay> planned;
  Set<DateTime> plannedDates;
  List<DayOption> recommended;
  int capacity; // extra whole days affordable on top of the plans
  int target; // whole days off the plan aims for (incl. planned)

  TermPlan({
    required this.key,
    required this.start,
    required this.close,
    required this.hasData,
    required this.active,
    List<DateTime>? schoolDays,
    List<DateTime>? remainingDays,
    List<Budget>? budgets,
    Map<DateTime, DayOption>? options,
    List<PlannedDay>? planned,
    Set<DateTime>? plannedDates,
    List<DayOption>? recommended,
    this.capacity = 0,
    this.target = 0,
  })  : schoolDays = schoolDays ?? [],
        remainingDays = remainingDays ?? [],
        budgets = budgets ?? [],
        options = options ?? {},
        planned = planned ?? [],
        plannedDates = plannedDates ?? {},
        recommended = recommended ?? [];

  double get elapsed {
    if (schoolDays.isEmpty) return 0.0;
    return 1.0 - remainingDays.length / schoolDays.length;
  }

  Map<String, Budget> get budgetByCanon =>
      {for (final b in budgets) b.canon: b};

  Budget? get tightest {
    if (budgets.isEmpty) return null;
    return budgets.reduce((a, b) {
      if (b.daysLeft != a.daysLeft) {
        return b.daysLeft < a.daysLeft ? b : a;
      }
      return b.name.compareTo(a.name) < 0 ? b : a;
    });
  }

  List<Budget> get fastPace {
    final out = <Budget>[];
    for (final b in budgets) {
      final ratio = b.paceRatio(elapsed);
      if (ratio != null && ratio > 1.25 && b.missed >= 2) out.add(b);
    }
    return out;
  }

  /// What skipping these lessons does to each touched budget.
  List<ImpactRow> impact(Map<DateTime, List<String>> byDay) {
    final counts = <String, int>{};
    for (final entry in byDay.entries) {
      if (entry.key.isBefore(start) || entry.key.isAfter(close)) continue;
      for (final name in entry.value) {
        final canon = canonSubject(name);
        counts[canon] = (counts[canon] ?? 0) + 1;
      }
    }
    final rows = <ImpactRow>[];
    final budgets = budgetByCanon;
    for (final entry in counts.entries) {
      final budget = budgets[entry.key];
      if (budget == null) continue;
      final cost = entry.value;
      final freeAfter = budget.free - cost;
      final schoolAfter = budget.schoolLeft - cost;
      final projected =
          (budget.missed + budget.planned + cost) / budget.total * 100.0;
      final level = schoolAfter < -_eps
          ? 'over'
          : (freeAfter < -_eps ? 'reserve' : 'ok');
      rows.add(ImpactRow(
          name: budget.name,
          cost: cost,
          freeAfter: freeAfter,
          projectedAfter: projected,
          limitPct: budget.limitPct,
          level: level));
    }
    const order = {'over': 0, 'reserve': 1, 'ok': 2};
    rows.sort((a, b) {
      if (order[a.level] != order[b.level]) {
        return order[a.level]! - order[b.level]!;
      }
      if (a.freeAfter != b.freeAfter) {
        return a.freeAfter.compareTo(b.freeAfter);
      }
      return a.name.compareTo(b.name);
    });
    return rows;
  }
}

class YearPlan {
  List<TermPlan> terms;
  DateTime today;
  DateTime firstDay;
  LessonSource? source;
  Set<DateTime> holidays;
  Map<DateTime, String> freeLabels;

  YearPlan({
    List<TermPlan>? terms,
    DateTime? today,
    DateTime? firstDay,
    this.source,
    Set<DateTime>? holidays,
    Map<DateTime, String>? freeLabels,
  })  : terms = terms ?? [],
        today = today ?? _day(clock.now()),
        firstDay = firstDay ?? _day(clock.now()),
        holidays = holidays ?? {},
        freeLabels = freeLabels ?? {};

  TermPlan? term(String? key) {
    for (final term in terms) {
      if (term.key == key) return term;
    }
    return null;
  }

  TermPlan? get defaultTerm {
    for (final term in terms) {
      if (term.active) return term;
    }
    return terms.isEmpty ? null : terms.first;
  }

  List<String> lessonsOn(DateTime day) {
    if (source == null || _weekday(day) >= 5 || holidays.contains(day)) {
      return [];
    }
    return [for (final l in (source!.lessons(day) ?? <Lesson>[])) l.subject];
  }

  Map<DateTime, List<String>> entryBreakdown(Map<String, Object?> entry) {
    if (source == null) return {};
    final raw = entryLessons(entry, source!, holidays, fromDay: today);
    return {for (final e in raw.entries) e.key: [for (final l in e.value) l.subject]};
  }

  List<(TermPlan, List<ImpactRow>)> impactOfEntry(
          Map<String, Object?> entry) =>
      impactOfEntries([entry]);

  /// What planning all [entries] together does to each term's budgets.
  List<(TermPlan, List<ImpactRow>)> impactOfEntries(
      Iterable<Map<String, Object?>> entries) {
    final byDay = <DateTime, List<String>>{};
    for (final entry in entries) {
      for (final dayEntry in entryBreakdown(entry).entries) {
        byDay.putIfAbsent(dayEntry.key, () => []).addAll(dayEntry.value);
      }
    }
    final out = <(TermPlan, List<ImpactRow>)>[];
    for (final term in terms) {
      final part = <DateTime, List<String>>{
        for (final e in byDay.entries)
          if (!e.key.isBefore(term.start) && !e.key.isAfter(term.close))
            e.key: e.value
      };
      if (part.isNotEmpty) out.add((term, term.impact(part)));
    }
    return out;
  }
}

// -- terms ---------------------------------------------------------------------

/// (key, first_day, closure) for both semesters of today's school year.
List<(String, DateTime, DateTime)> schoolYearTerms(DateTime today,
    {Object? sem1Close, Object? sem2Close, Object? schoolYearEnd}) {
  final year = today.month >= 8 ? today.year : today.year - 1;
  var sem1End = DateTime(year + 1, 1, 31);
  var sem2End = DateTime(year + 1, 6, 30);
  final sem1Start = DateTime(year, 9, 1);
  final sem2Start = DateTime(year + 1, 2, 1);
  final close1 = (sem1Close is String && sem1Close.isEmpty) ||
          sem1Close == null
      ? null
      : parseCzDate(sem1Close);
  final sem2Raw = sem2Close ?? schoolYearEnd;
  final close2 =
      (sem2Raw is String && sem2Raw.isEmpty) || sem2Raw == null
          ? null
          : parseCzDate(sem2Raw);
  if (close1 != null &&
      !close1.isBefore(sem1Start) &&
      !close1.isAfter(
          DateTime(sem1End.year, sem1End.month, sem1End.day + 14))) {
    sem1End = close1;
  }
  if (close2 != null &&
      !close2.isBefore(sem2Start) &&
      !close2.isAfter(
          DateTime(sem2End.year, sem2End.month, sem2End.day + 14))) {
    sem2End = close2;
  }
  return [('sem1', sem1Start, sem1End), ('sem2', sem2Start, sem2End)];
}

/// Length of the contiguous off-block containing [day] once taken.
int _freeStreak(DateTime day, bool Function(DateTime) isOff) {
  var length = 1;
  var cursor = _prevDay(day);
  while (isOff(cursor) && length < 40) {
    length += 1;
    cursor = _prevDay(cursor);
  }
  cursor = _nextDay(day);
  while (isOff(cursor) && length < 40) {
    length += 1;
    cursor = _nextDay(cursor);
  }
  return length;
}

/// Lower is better.
///
/// [repeats] = days of the same weekday already in the plan: skipping
/// every Thursday would always miss the same subjects, so each repeat
/// costs a little (the plan varies weekdays when prices are close).
/// [streak] overrides the option's free-block length (a pick next to
/// another pick makes a longer vacation).
double _score(DayOption option, Map<String, double> free,
    [int repeats = 0, int? streak]) {
  var pain = 0.0;
  for (final entry in option.cost.entries) {
    pain += entry.value / math.max(free[entry.key] ?? 0.0, 0.5);
  }
  var score = 10.0 * pain + 0.35 * option.lessonsCount + 2.0 * repeats;
  streak ??= option.streak;
  if (streak >= 4) {
    score -= math.min(6.0, 4.0 + 0.5 * (streak - 4));
  } else if (streak >= 3) {
    score -= 2.0;
  }
  if (option.finalWeek) {
    score += 6.0;
  } else if (option.lateWeek) {
    score += 2.0;
  }
  return score;
}

bool _fits(DayOption option, Map<String, double> free) {
  for (final entry in option.cost.entries) {
    if (entry.value > (free[entry.key] ?? 0.0) + _eps) return false;
  }
  return true;
}

void _spend(DayOption option, Map<String, double> free) {
  for (final entry in option.cost.entries) {
    free[entry.key] = (free[entry.key] ?? 0.0) - entry.value;
  }
}

/// How many more whole days fit (greedy, cheapest first).
int _capacity(List<DayOption> options, Map<String, double> free) {
  final left = Map<String, double>.of(free);
  var count = 0;
  final sorted = List<DayOption>.of(options)
    ..sort((a, b) {
      final sa = _score(a, free);
      final sb = _score(b, free);
      if (sa != sb) return sa.compareTo(sb);
      return a.day.compareTo(b.day);
    });
  for (final option in sorted) {
    if (_fits(option, left)) {
      _spend(option, left);
      count += 1;
    }
  }
  return count;
}

/// Picks up to [quota] days spread evenly across [span].
///
/// [span] (remaining school days) is cut into equal windows, one per
/// day off wanted in total ([taken] = days already planned). Windows
/// already holding a planned day are skipped; every other window gets
/// its best affordable day, re-scored against the budgets left after
/// the earlier picks. Days crowding an earlier pick pay a proximity
/// penalty (unless they join it into one longer vacation — [isOff]
/// tells weekends/holidays apart). Leftover quota (windows with nothing
/// affordable) is filled with the affordable days farthest from every
/// pick.
List<DayOption> spreadPlan(
    List<DayOption> options, Map<String, double> free, int quota,
    List<DateTime> span,
    {Iterable<DateTime> taken = const [],
    bool Function(DateTime)? isOff}) {
  if (quota <= 0 || options.isEmpty || span.isEmpty) return [];
  final takenList = taken.toSet().toList()..sort();
  final left = Map<String, double>.of(free);
  final index = <DateTime, int>{for (var i = 0; i < span.length; i++) span[i]: i};
  final windowsN =
      quota + takenList.where((d) => index.containsKey(d)).length;
  final length = span.length;
  final ideal = math.max(1.0, length / math.max(1, windowsN));
  final picks = <DayOption>[];
  final byDay = {for (final o in options) o.day: o};
  final weekdays = <int, int>{};
  for (final d in takenList) {
    weekdays[_weekday(d)] = (weekdays[_weekday(d)] ?? 0) + 1;
  }
  final chosen = takenList.toSet();

  double rank(DayOption o) {
    int? streak;
    var joined = false;
    if (isOff != null && chosen.isNotEmpty) {
      streak = _freeStreak(o.day, (d) => isOff(d) || chosen.contains(d));
      joined = streak > o.streak;
    }
    var penalty = 0.0;
    if (!joined && index.containsKey(o.day)) {
      final near = [
        for (final d in chosen)
          if (index.containsKey(d)) (index[o.day]! - index[d]!).abs()
      ];
      if (near.isNotEmpty) {
        penalty = 4.0 *
            math.max(0.0, 1.0 - near.reduce(math.min) / ideal);
      }
    }
    return _score(o, left, weekdays[_weekday(o.day)] ?? 0, streak) +
        penalty;
  }

  void take(DayOption best) {
    picks.add(best);
    chosen.add(best.day);
    weekdays[_weekday(best.day)] = (weekdays[_weekday(best.day)] ?? 0) + 1;
    _spend(best, left);
  }

  for (var w = 0; w < windowsN; w++) {
    if (picks.length >= quota) break;
    final lo = (w * length) ~/ windowsN;
    final hi = math.max(lo + 1, ((w + 1) * length) ~/ windowsN);
    final windowDays = span.sublist(lo, hi > length ? length : hi);
    if (windowDays.any(takenList.contains)) continue;
    DayOption? best;
    for (final d in windowDays) {
      final o = byDay[d];
      if (o == null || !_fits(o, left)) continue;
      if (best == null) {
        best = o;
      } else {
        final rBest = rank(best);
        final rO = rank(o);
        if (rO < rBest || (rO == rBest && o.day.isBefore(best.day))) {
          best = o;
        }
      }
    }
    if (best == null) continue;
    take(best);
  }
  while (picks.length < quota) {
    final pool = [
      for (final o in options)
        if (!chosen.contains(o.day) && _fits(o, left)) o
    ];
    if (pool.isEmpty) break;

    int gap(DayOption o) {
      if (chosen.isEmpty) return 10000;
      return chosen.map((d) => _dayDiff(o.day, d).abs()).reduce(math.min);
    }

    var best = pool.first;
    for (final o in pool.skip(1)) {
      final gb = math.min(gap(best), 21);
      final go = math.min(gap(o), 21);
      if (go > gb) {
        best = o;
      } else if (go == gb) {
        final rBest = rank(best);
        final rO = rank(o);
        if (rO < rBest || (rO == rBest && o.day.isBefore(best.day))) {
          best = o;
        }
      }
    }
    take(best);
  }
  picks.sort((a, b) => a.day.compareTo(b.day));
  return picks;
}

// -- entry point ---------------------------------------------------------------

/// Budgets, candidate days and a balanced plan for the school year.
///
/// [states] (from `forecast.forecast_all`) define which subjects
/// count and their limits/current %. [firstDay] is the first date that
/// can still be planned (today, or tomorrow once today's lessons began).
/// [targetDays] caps the whole days off per term (0 = as many as the
/// budgets allow). The term holding today uses the school's absence data;
/// the next term starts from a clean slate.
YearPlan buildYearPlan(
  List<SubjectState> states, {
  Map<Object?, Object?>? timetable,
  Map<Object?, Object?>? stableBaseline,
  Iterable<Object?>? holidays,
  List<Map<String, Object?>>? planned,
  DateTime? today,
  DateTime? firstDay,
  Object? sem1Close,
  Object? sem2Close,
  Object? schoolYearEnd,
  double reservePct = 10.0,
  int targetDays = 0,
  Map<Object?, Object?>? freeLabels,
}) {
  final now = _day(today ?? clock.now());
  final first = _day(firstDay != null && firstDay.isAfter(now) ? firstDay : now);
  final holidaySet = normalizeHolidays(holidays);
  final reserve = math.max(0.0, reservePct);
  final source = LessonSource(timetable, stableBaseline);
  final plan = YearPlan(
      today: now,
      firstDay: first,
      source: source,
      holidays: holidaySet,
      freeLabels: {
        for (final entry in (freeLabels ?? const {}).entries)
          if (entry.key is DateTime) entry.key as DateTime: '${entry.value}'
      });
  if (states.isEmpty) return plan;

  final entries = <Map<String, Object?>>[];
  for (final x in planned ?? const <Map<String, Object?>>[]) {
    final norm = normalizePlannedEntry(x);
    if (norm != null) entries.add(norm);
  }
  final plannedLessons = <(Map<String, Object?>, Map<DateTime, List<Lesson>>)>[
    for (final entry in entries)
      (entry, entryLessons(entry, source, holidaySet, fromDay: now))
  ];
  final plannedDatesAll = <DateTime>{};
  for (final entry in entries) {
    plannedDatesAll.addAll(entryDays(entry));
  }

  bool isOff(DateTime day) =>
      _weekday(day) >= 5 ||
      holidaySet.contains(day) ||
      plannedDatesAll.contains(day);
  final blocks = lessonBlocks(source);

  for (final (key, start, close)
      in schoolYearTerms(now,
          sem1Close: sem1Close,
          sem2Close: sem2Close,
          schoolYearEnd: schoolYearEnd)) {
    if (close.isBefore(now)) continue; // closed term: nothing left to plan
    final isCurrent =
        !start.isAfter(now) && !now.isAfter(close);
    final schoolDays = schoolDaysBetween(start, close, holidaySet);
    final remaining = [
      for (final d in schoolDays) if (!d.isBefore(now)) d
    ];
    final term = TermPlan(
        key: key,
        start: start,
        close: close,
        hasData: isCurrent,
        active: isCurrent,
        schoolDays: schoolDays,
        remainingDays: remaining);

    // Future hours per subject, counted day by day.
    final future = <String, int>{};
    var unknownDays = 0;
    for (final day in remaining) {
      final lessons = source.lessons(day);
      if (lessons == null) {
        unknownDays += 1;
        continue;
      }
      for (final l in lessons) {
        final canon = canonSubject(l.subject);
        future[canon] = (future[canon] ?? 0) + 1;
      }
    }

    final names = <String, String>{};
    for (final state in states) {
      final canon = canonSubject(state.name);
      if (canon.isEmpty || names.containsKey(canon)) continue;
      names[canon] = state.name;
      final weekly = math.max(1, state.weeklyHours).toDouble();
      final fut = (future[canon] ?? 0).toDouble() + weekly * unknownDays / 5.0;
      double taught, current, missed;
      var blocked = false;
      if (isCurrent) {
        taught = state.taughtHours;
        if (taught <= 0) {
          final elapsedDays = schoolDays.length - remaining.length;
          taught = weekly * elapsedDays / 5.0;
        }
        current = math.max(0.0, state.currentPct);
        missed = current / 100.0 * taught;
        blocked = state.unclassifiable;
      } else {
        taught = 0.0;
        current = 0.0;
        missed = 0.0;
        blocked = false;
      }
      term.budgets.add(Budget(
          name: state.name,
          canon: canon,
          limitPct: state.limitPct,
          reservePct: reserve,
          currentPct: current,
          taught: taught,
          missed: missed,
          future: fut,
          blocked: blocked,
          weekly: weekly,
          block: blocks[canon] ?? 1));
    }
    final budgets = term.budgetByCanon;

    // Already planned days inside this term.
    for (final (entry, byDay) in plannedLessons) {
      final inTerm = <DateTime, List<Lesson>>{
        for (final e in byDay.entries)
          if (!e.key.isBefore(start) && !e.key.isAfter(close)) e.key: e.value
      };
      final touches = [
        for (final d in entryDays(entry))
          if (!d.isBefore(start) && !d.isAfter(close)) d
      ];
      if (touches.isEmpty) continue;
      final row = PlannedDay(entry: entry, days: {
        for (final e in inTerm.entries)
          e.key: [for (final l in e.value) l.subject]
      });
      final counts = <String, int>{};
      for (final ls in inTerm.values) {
        for (final l in ls) {
          final canon = canonSubject(l.subject);
          if (budgets.containsKey(canon)) {
            counts[canon] = (counts[canon] ?? 0) + 1;
          }
        }
      }
      row.cost = counts;
      for (final e in counts.entries) {
        budgets[e.key]!.planned += e.value;
      }
      term.planned.add(row);
      term.plannedDates.addAll([
        for (final d in touches)
          if (_weekday(d) < 5 && !holidaySet.contains(d)) d
      ]);
    }
    for (final row in term.planned) {
      for (final canon in row.cost.keys) {
        final status = budgets[canon]!.status;
        if (status == 'over') {
          row.over.add(canon);
        } else if (status == 'reserve') {
          row.reserve.add(canon);
        }
      }
    }

    // Candidate days.
    final free = {for (final b in term.budgets) b.canon: b.free};
    // The closing weeks, flagged only when they really are the term's
    // last weeks (a short horizon mid-term is not the grading crunch).
    final finalSet = schoolDays.length > finalWeekDays
        ? schoolDays.sublist(schoolDays.length - finalWeekDays).toSet()
        : <DateTime>{};
    final lateSet = schoolDays.length > lateWeekDays
        ? schoolDays
            .sublist(
                schoolDays.length - lateWeekDays, schoolDays.length - finalWeekDays)
            .toSet()
        : <DateTime>{};
    for (final day in remaining) {
      if (day.isBefore(first) || plannedDatesAll.contains(day)) continue;
      final lessons = source.lessons(day);
      if (lessons == null || lessons.isEmpty) {
        continue; // unknown or no lessons: nothing to plan
      }
      final subjects = [for (final l in lessons) l.subject];
      final counts = <String, int>{};
      for (final s in subjects) {
        final canon = canonSubject(s);
        counts[canon] = (counts[canon] ?? 0) + 1;
      }
      final cost = <String, int>{
        for (final e in counts.entries)
          if (budgets.containsKey(e.key)) e.key: e.value
      };
      final option = DayOption(
        day: day,
        term: key,
        lessons: subjects,
        cost: cost,
        names: {for (final c in cost.keys) c: budgets[c]!.name},
        streak: _freeStreak(day, isOff),
        finalWeek: finalSet.contains(day),
        lateWeek: lateSet.contains(day),
      );
      option.blockedBy = [
        for (final e in cost.entries)
          if (e.value > (free[e.key] ?? 0.0) + _eps) e.key
      ];
      option.feasible = option.blockedBy.isEmpty;
      option.score = _score(option, free);
      term.options[day] = option;
    }

    for (final option in term.options.values) {
      for (final e in option.cost.entries) {
        if (e.value > budgets[e.key]!.peak) budgets[e.key]!.peak = e.value;
      }
    }

    // Balanced plan: capacity from the non-final days (the final week
    // only when nothing else is left), then spread evenly.
    final feasible = [
      for (final o in term.options.values) if (o.feasible) o
    ];
    final useFinal = !feasible.any((o) => !o.finalWeek);
    final pool =
        feasible.where((o) => useFinal || !o.finalWeek).toList();
    term.capacity = _capacity(pool, free);
    final already =
        term.plannedDates.where(remaining.contains).length;
    var wanted = term.capacity;
    if (targetDays > 0) {
      wanted =
          math.min(term.capacity, math.max(0, targetDays - already));
    }
    term.target = already + wanted;
    final span = [
      for (final d in remaining)
        if (!d.isBefore(first) && (useFinal || !finalSet.contains(d))) d
    ];
    term.recommended = spreadPlan(pool, free, wanted, span,
        taken: term.plannedDates, isOff: isOff);
    term.budgets.sort((a, b) {
      if (a.daysLeft != b.daysLeft) return a.daysLeft.compareTo(b.daysLeft);
      return a.name.compareTo(b.name);
    });
    plan.terms.add(term);
  }
  return plan;
}
