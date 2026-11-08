import '../common/format.dart';
import '../common/lesson_model.dart';

/// Pending-excuse task logic ported from
/// `strakalari/flet_ui/state_excuses.py` (plus the core pieces it uses:
/// `models.excuse_tasks_from_lessons`, `excuse_history.task_covered`
/// / `excuse_window_start`).
///
/// All functions are pure; the controller owns the mutable ignore list,
/// the sending set and the history/config inputs.

// -- tasks ----------------------------------------------------------------

/// One pending excuse task — like the dicts `_all_excuse_tasks` builds.
class ExcuseTask {
  /// Key format `<iso>|<period>|<subject>` (from `excuse_tasks_from_lessons`).
  final String key;
  final String kind; // late | early | soon | short
  final String label;
  final String detail;
  final DateTime? date;
  final int? period;

  const ExcuseTask({
    required this.key,
    required this.kind,
    required this.label,
    this.detail = '',
    this.date,
    this.period,
  });
}

/// Builds pending excuse tasks from unexcused absent/late lessons —
/// like `models.excuse_tasks_from_lessons` (subset used by the UI).
List<ExcuseTask> excuseTasksFromLessons(
    Iterable<LessonRow> lessons, String periodWord) {
  const taskStatuses = {
    'absent',
    'absence',
    'nepritomen',
    'neprítomen',
    'unexcused',
    'late',
    'early',
    'soon',
    'absentlate',
    'absentearly',
  };
  final out = <ExcuseTask>[];
  for (final lesson in lessons) {
    if (lesson.excused ||
        const {'excused', 'cancelled', '', 'present'}
            .contains(lesson.status)) {
      continue;
    }
    if (!taskStatuses.contains(lesson.status)) continue;
    final String kind;
    if (lesson.status == 'soon') {
      kind = 'soon';
    } else if (lesson.status == 'late' || lesson.status == 'absentlate') {
      kind = 'late';
    } else if (lesson.status == 'early' || lesson.status == 'absentearly') {
      kind = 'early';
    } else {
      kind = 'short';
    }
    final day = lesson.day;
    final dayLabel =
        day == null ? '?' : '${day.day}. ${day.month}.';
    final periodLabel =
        lesson.period != null ? ', ${lesson.period}. $periodWord' : '';
    final iso = day == null ? '?' : isoDay(day);
    out.add(ExcuseTask(
      key: '$iso|${lesson.period}|${lesson.subject}',
      kind: kind,
      label: '${lesson.subject} — $dayLabel$periodLabel',
      detail: [lesson.teacher, lesson.room]
          .where((p) => p.isNotEmpty)
          .join(' · '),
      date: lesson.day,
      period: lesson.period,
    ));
  }
  return out;
}

/// Flattens `{dayKey: [lessonDict, ...]}` into lessons —
/// like `models.lessons_from_timetable`.
List<LessonRow> lessonsFromTimetable(Map<String, List<Object?>> timetable) {
  final out = <LessonRow>[];
  timetable.forEach((dayKey, lessons) {
    for (final item in lessons) {
      if (item is Map) {
        out.add(LessonRow.fromLegacy(
            item.cast<String, Object?>(), dayKey));
      }
    }
  });
  return out;
}

// -- window + coverage ------------------------------------------------------

/// Only absences this recent are ever excused (Komens → Odeslané lists
/// the last month of sent messages by default).
const int excuseWindowDays = 30;

/// First day an absence may still be excused — like
/// `excuse_history.excuse_window_start`. `outboxFrom` is the start of
/// the range Odeslané actually showed; when later than the default
/// month, the narrower range wins.
DateTime excuseWindowStart(DateTime today, [DateTime? outboxFrom]) {
  final start = DateTime(today.year, today.month, today.day)
      .subtract(const Duration(days: excuseWindowDays));
  if (outboxFrom != null &&
      start.isBefore(outboxFrom) &&
      !outboxFrom.isAfter(today)) {
    return DateTime(outboxFrom.year, outboxFrom.month, outboxFrom.day);
  }
  return start;
}

int? _lessonNum(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v'.trim());
}

/// True when one history entry covers `lesson` (null = whole day) on
/// `day` — like `excuse_history._covers`.
bool historyEntryCovers(
    Map<String, Object?> entry, DateTime day, int? lesson) {
  final start = parseCzDate(entry['starting_day']);
  final end = parseCzDate(entry['ending_day']) ?? start;
  if (start == null ||
      end == null ||
      day.isBefore(start) ||
      day.isAfter(end)) {
    return false;
  }
  if ('${entry['type'] ?? ''}'.toLowerCase() == 'pure days') return true;
  final first = _lessonNum(entry['starting_lesson']);
  final last = _lessonNum(entry['ending_lesson']);
  if (first == null || last == null) return false;
  if (start.isBefore(day) && day.isBefore(end)) return true;
  if (lesson == null) return false;
  if (start == end) return first <= lesson && lesson <= last;
  if (day == start) return lesson >= first;
  return lesson <= last;
}

/// True when a single lesson task (day + period) is already excused —
/// like `excuse_history.task_covered`.
bool taskCovered(DateTime day, int? period, List<Object?> history) {
  for (final h in history) {
    if (h is! Map) continue;
    if (period == null &&
        '${h['type'] ?? ''}'.toLowerCase() != 'pure days') {
      continue;
    }
    if (historyEntryCovers(h.cast<String, Object?>(), day, period)) {
      return true;
    }
  }
  return false;
}

// -- filtering --------------------------------------------------------------

/// Unexcused tasks: drops sent keys and history-covered tasks —
/// like `ExcuseTasksMixin._unexcused_tasks`.
List<ExcuseTask> unexcusedTasks({
  required bool demoMode,
  required Map<String, List<Object?>> timetable,
  required String periodWord,
  required Set<String> sentKeys,
  required List<Object?> history,
}) {
  if (demoMode) return [];
  var tasks = excuseTasksFromLessons(
      lessonsFromTimetable(timetable), periodWord);
  if (sentKeys.isNotEmpty) {
    tasks = tasks.where((t) => !sentKeys.contains(t.key)).toList();
  }
  if (history.isNotEmpty) {
    tasks = tasks.where((t) {
      if (t.date == null) return true;
      return !taskCovered(t.date!, t.period, history);
    }).toList();
  }
  return tasks;
}

/// Pending tasks: window + ignore-list filtering —
/// like `ExcuseTasksMixin.excuse_tasks`. Older absences are history,
/// not tasks (Odeslané no longer lists their excuses, so a send could
/// not be checked for duplicates).
List<ExcuseTask> pendingTasks({
  required List<ExcuseTask> unexcused,
  required DateTime today,
  DateTime? outboxFrom,
  Set<String> ignoredKeys = const {},
}) {
  final windowStart = excuseWindowStart(today, outboxFrom);
  return unexcused.where((t) {
    if (t.date != null && t.date!.isBefore(windowStart)) return false;
    if (ignoredKeys.contains(t.key)) return false;
    return true;
  }).toList();
}

/// Currently ignored tasks (still unexcused in the timetable) —
/// like `ExcuseTasksMixin.ignored_tasks`.
List<ExcuseTask> ignoredTasks(
    List<ExcuseTask> unexcused, Set<String> ignoredKeys) {
  if (ignoredKeys.isEmpty) return [];
  return unexcused.where((t) => ignoredKeys.contains(t.key)).toList();
}

// -- plans ------------------------------------------------------------------

/// The one-lesson excuse for a pending task — like
/// `state_excuses._lesson_excuse`. `dayLabel` is `DD.MM.YYYY`.
Map<String, Object?> lessonExcuse(
    String kind, String dayLabel, int period) {
  final k = kind.toLowerCase();
  return {
    // `early` (generic předčasný odchod) uses the same hour-based web
    // form as `soon`; `late` is a late arrival.
    'type': k == 'soon' || k == 'early'
        ? 'soon'
        : (k == 'late' ? 'income' : 'days and hours'),
    'starting_day': dayLabel,
    'ending_day': dayLabel,
    'starting_lesson': period,
    'ending_lesson': period,
  };
}

/// True when every lesson of the day that took place is a pending
/// absence — like `ExcuseTasksMixin.day_fully_absent`. Only then does a
/// whole-day (`pure days`) excuse describe what happened.
bool dayFullyAbsent({
  required String dayIso,
  required List<ExcuseTask> pending,
  required Map<String, List<Object?>> timetable,
}) {
  final day = parseCzDate(dayIso);
  if (day == null) return false;
  final tasks =
      pending.where((t) => isoDayOf(t.date) == dayIso).toList();
  final absentKeys = {
    for (final t in tasks)
      if (t.kind == 'short') t.key,
  };
  final lessons = <LessonRow>[];
  for (final entry in timetable.entries) {
    if (parseCzDate(entry.key) != day) continue;
    for (final item in entry.value) {
      if (item is Map) {
        final lesson =
            LessonRow.fromLegacy(item.cast<String, Object?>(), entry.key);
        if (!isClassEvent(item)) lessons.add(lesson);
      }
    }
  }
  final held =
      lessons.where((l) => l.status != 'cancelled').toList();
  if (held.isEmpty || absentKeys.isEmpty) return false;
  return held.every((l) =>
      absentKeys.contains('$dayIso|${l.period}|${l.subject}'));
}

String isoDayOf(DateTime? day) => day == null ? '' : isoDay(day);

/// The excuses covering every pending task of one day —
/// like `ExcuseTasksMixin.day_excuse_plan`.
List<Map<String, Object?>> dayExcusePlan({
  required String dayIso,
  required List<ExcuseTask> pending,
  required Map<String, List<Object?>> timetable,
  bool perLesson = false,
}) {
  final day = parseCzDate(dayIso);
  if (day == null) return [];
  final dayLabel = dayKey(day);
  final tasks =
      pending.where((t) => isoDayOf(t.date) == dayIso).toList();
  if (tasks.isEmpty) return [];
  if (perLesson) {
    final singles = <Map<String, Object?>>[];
    for (final task in tasks) {
      if (task.period == null) continue;
      final excuse = lessonExcuse(task.kind, dayLabel, task.period!);
      if (!singles.any((e) => _excuseEquals(e, excuse))) {
        singles.add(excuse);
      }
    }
    singles.sort((a, b) => (a['starting_lesson'] as int)
        .compareTo(b['starting_lesson'] as int));
    return singles;
  }
  if (dayFullyAbsent(
      dayIso: dayIso, pending: pending, timetable: timetable)) {
    return [
      {
        'type': 'pure days',
        'starting_day': dayLabel,
        'ending_day': dayLabel,
      }
    ];
  }
  final plan = <Map<String, Object?>>[];
  final absent = <int>[];
  for (final task in tasks) {
    if (task.period == null) continue;
    final kind = task.kind.toLowerCase();
    if (kind == 'short') {
      absent.add(task.period!);
      continue;
    }
    plan.add({
      'type': kind == 'soon' || kind == 'early' ? 'soon' : 'income',
      'starting_day': dayLabel,
      'ending_day': dayLabel,
      'starting_lesson': task.period,
      'ending_lesson': task.period,
    });
  }
  final sorted = absent.toSet().toList()..sort();
  var run = <int>[];
  for (final period in sorted) {
    if (run.isNotEmpty && period != run.last + 1) {
      plan.add({
        'type': 'days and hours',
        'starting_day': dayLabel,
        'ending_day': dayLabel,
        'starting_lesson': run.first,
        'ending_lesson': run.last,
      });
      run = [];
    }
    run.add(period);
  }
  if (run.isNotEmpty) {
    plan.add({
      'type': 'days and hours',
      'starting_day': dayLabel,
      'ending_day': dayLabel,
      'starting_lesson': run.first,
      'ending_lesson': run.last,
    });
  }
  return plan;
}

bool _excuseEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k) || b[k] != a[k]) return false;
  }
  return true;
}
