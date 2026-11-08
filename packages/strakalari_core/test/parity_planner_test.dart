import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/planning/planner.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<Object?, Object?> anyMap(Object? value) =>
    Map<Object?, Object?>.from(value as Map);

/// Baseline with plain-map slots (the shape both LessonSource ports
/// accept): `{'w|p': {...}}` decoded from JSON becomes
/// `{(w, p): {...}}`. `baselineFromDict` is NOT used here on purpose —
/// it yields SlotBaseline values, which the Dart LessonSource drops
/// while the Python one reads (reported port deviation).
Map<(int, int), Object?> liveBaseline(Object? dictForm) {
  final out = <(int, int), Object?>{};
  for (final e in (dictForm as Map).entries) {
    final parts = (e.key as String).split('|');
    out[(int.parse(parts[0]), int.parse(parts[1]))] = e.value;
  }
  return out;
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, List<Map<String, Object?>>> timetableOf(Object? value) =>
    (value as Map).map((k, v) => MapEntry(k as String,
        (v as List).map((e) => strMap(e)).toList()));

Map<String, Object?> lessonJson(Lesson l) => {
      'subject': l.subject,
      'day': l.day,
      'period': l.period,
      'time': l.time,
      'room': l.room,
      'teacher': l.teacher,
      'status': l.status,
      'change': l.change,
      'excused': l.excused,
    };

Map<String, Object?> optionJson(DayOption o) => {
      'day': o.day,
      'term': o.term,
      'lessons': o.lessons,
      'cost': o.cost,
      'names': o.names,
      'streak': o.streak,
      'finalWeek': o.finalWeek,
      'lateWeek': o.lateWeek,
      'feasible': o.feasible,
      'blockedBy': o.blockedBy,
      'score': o.score,
    };

DayOption optionOf(Map<String, Object?> m) => DayOption(
      day: m['day'] as DateTime,
      term: m['term'] as String,
      lessons: (m['lessons'] as List).cast<String>(),
      cost: (m['cost'] as Map).map((k, v) =>
          MapEntry(k as String, (v as num).toInt())),
      names: (m['names'] as Map?)
              ?.map((k, v) => MapEntry(k as String, v as String)) ??
          {},
      streak: (m['streak'] as num?)?.toInt() ?? 1,
      finalWeek: m['finalWeek'] as bool? ?? false,
      lateWeek: m['lateWeek'] as bool? ?? false,
      feasible: m['feasible'] as bool? ?? true,
      blockedBy: (m['blockedBy'] as List?)?.cast<String>(),
      score: (m['score'] as num?)?.toDouble() ?? 0.0,
    );

Map<String, Object?> budgetJson(Budget b) => {
      'name': b.name,
      'canon': b.canon,
      'limitPct': b.limitPct,
      'reservePct': b.reservePct,
      'currentPct': b.currentPct,
      'taught': b.taught,
      'missed': b.missed,
      'future': b.future,
      'planned': b.planned,
      'blocked': b.blocked,
      'weekly': b.weekly,
      'peak': b.peak,
    };

Map<String, Object?> termJson(TermPlan t) => {
      'key': t.key,
      'start': t.start,
      'close': t.close,
      'hasData': t.hasData,
      'active': t.active,
      'capacity': t.capacity,
      'target': t.target,
      'budgets': {
        for (final b in t.budgets) b.canon: budgetJson(b),
      },
      'recommended': [for (final o in t.recommended) optionJson(o)],
      'planned': [
        for (final p in t.planned)
          {
            'entry': p.entry,
            'days': {
              for (final e in p.days.entries) iso(e.key): e.value,
            },
            'cost': p.cost,
            'over': p.over,
            'reserve': p.reserve,
          },
      ],
    };

Map<String, Object?> yearPlanJson(YearPlan p) => {
      'terms': [for (final t in p.terms) termJson(t)],
      'today': p.today,
      'firstDay': p.firstDay,
      'defaultTerm': p.defaultTerm?.key,
    };

SubjectState stateOf(Map<String, Object?> m) => SubjectState(
      name: m['name'] as String? ?? '',
      currentPct: (m['currentPct'] as num?)?.toDouble() ?? 0.0,
      limitPct: (m['limitPct'] as num?)?.toDouble() ?? 25.0,
      weeklyHours: (m['weeklyHours'] as num?)?.toInt() ?? 0,
      safeHoursLeft: (m['safeHoursLeft'] as num?)?.toInt() ?? 0,
      projectedPct: (m['projectedPct'] as num?)?.toDouble() ?? 0.0,
      warnPct: (m['warnPct'] as num?)?.toDouble() ?? 0.0,
      planLimitPct: (m['planLimitPct'] as num?)?.toDouble(),
      planSafeHoursLeft: (m['planSafeHoursLeft'] as num?)?.toInt(),
      approaching: m['approaching'] as bool? ?? false,
      unclassifiable: m['unclassifiable'] as bool? ?? false,
      taughtHours: (m['taughtHours'] as num?)?.toDouble() ?? 0.0,
    );

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('planner')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'schoolYearTerms':
          final opts =
              args.length > 1 ? strMap(args[1]) : <String, Object?>{};
          result = [
            for (final t in schoolYearTerms(
              args[0] as DateTime,
              sem1Close: opts['sem1Close'],
              sem2Close: opts['sem2Close'],
              schoolYearEnd: opts['schoolYearEnd'],
            ))
              [t.$1, t.$2, t.$3],
          ];
        case 'entryLessons':
          final opts = strMap(args[1]);
          final source = LessonSource(
            timetableOf(opts['timetable']),
            liveBaseline(opts['baseline']),
          );
          final out = entryLessons(
            strMap(args[0]),
            source,
            <DateTime>{
              ...((opts['holidays'] as List?)?.cast<DateTime>() ?? const []),
            },
            fromDay: opts['fromDay'] as DateTime?,
          );
          result = {
            for (final e in out.entries)
              iso(e.key): [for (final l in e.value) lessonJson(l)],
          };
        case 'spreadPlan':
          result = [
            for (final o in spreadPlan(
              [(args[0] as List).map((e) => optionOf(strMap(e)))]
                  .expand((l) => l)
                  .toList(),
              (args[1] as Map).map((k, v) =>
                  MapEntry(k as String, (v as num).toDouble())),
              args[2] as int,
              (args[3] as List).cast<DateTime>(),
            ))
              optionJson(o),
          ];
        case 'buildYearPlan':
          final m = strMap(args[0]);
          result = yearPlanJson(buildYearPlan(
            [(m['states'] as List).map((e) => stateOf(strMap(e)))]
                .expand((l) => l)
                .toList(),
            timetable: m['timetable'] == null
                ? null
                : timetableOf(m['timetable']),
            stableBaseline: m['baseline'] == null
                ? null
                : liveBaseline(m['baseline']),
            holidays: (m['holidays'] as List?)?.cast<Object?>(),
            planned: (m['planned'] as List?)
                ?.map((e) => strMap(e))
                .toList(),
            today: m['today'] as DateTime?,
            firstDay: m['firstDay'] as DateTime?,
            sem1Close: m['sem1Close'],
            sem2Close: m['sem2Close'],
            schoolYearEnd: m['schoolYearEnd'],
            reservePct:
                (m['reservePct'] as num?)?.toDouble() ?? 10.0,
            targetDays: (m['targetDays'] as num?)?.toInt() ?? 0,
          ));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
