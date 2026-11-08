import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/planning/forecast.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<String, List<Map<String, Object?>>> timetableOf(Object? value) {
  if (value == null) return {};
  return (value as Map).map((k, v) => MapEntry(k as String,
      (v as List).map((e) => strMap(e)).toList()));
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, Object?> stateJson(SubjectState s) => {
      'name': s.name,
      'currentPct': s.currentPct,
      'limitPct': s.limitPct,
      'weeklyHours': s.weeklyHours,
      'safeHoursLeft': s.safeHoursLeft,
      'projectedPct': s.projectedPct,
      'warnPct': s.warnPct,
      'planLimitPct': s.planLimitPct,
      'planSafeHoursLeft': s.planSafeHoursLeft,
      'approaching': s.approaching,
      'unclassifiable': s.unclassifiable,
      'taughtHours': s.taughtHours,
    };

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('forecast')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'normalizeHolidays':
          result = normalizeHolidays(
                  (args[0] as List).cast<Object?>())
              .map(iso)
              .toList()
            ..sort();
        case 'weeklyHoursPerSubject':
          result = weeklyHoursPerSubject(timetableOf(args[0]));
        case 'schoolDaysBetween':
          result = schoolDaysBetween(
            args[0] as DateTime,
            args[1] as DateTime,
            <DateTime>{...(args[2] as List).cast<DateTime>()},
          );
        case 'semesterBounds':
          final r = semesterBounds(args[0] as DateTime);
          result = [r.$1, r.$2];
        case 'canonSubject':
          result = canonSubject(args[0]);
        case 'forecastSubject':
          result = stateJson(forecastSubject(
            currentPct: (args[0] as num).toDouble(),
            weeklyHours: (args[1] as num).toInt(),
            schoolDaysLeft: (args[2] as num).toInt(),
            schoolDaysTotal: (args[3] as num).toInt(),
            limitPct: (args[4] as num).toDouble(),
            warnPct: args[5] == null ? null : (args[5] as num).toDouble(),
            reservePct: (args[6] as num?)?.toDouble() ?? 0.0,
            taughtHours: args[7] == null
                ? null
                : (args[7] as num).toDouble(),
          ));
        case 'forecastAll':
          final m = strMap(args[0]);
          final r = forecastAll(
            absence: (m['absence'] as Map?)
                ?.map((k, v) => MapEntry(k as String, v)),
            timetable: m['timetable'] == null
                ? null
                : timetableOf(m['timetable']),
            subjectLimits: (m['subjectLimits'] as Map?)
                ?.map((k, v) => MapEntry(k as String, v)),
            holidays: (m['holidays'] as List?)?.cast<Object?>(),
            today: m['today'] as DateTime?,
            defaultLimit:
                (m['defaultLimit'] as num?)?.toDouble() ?? 25.0,
            schoolYearEnd: m['schoolYearEnd'],
            sem1Close: m['sem1Close'],
            sem2Close: m['sem2Close'],
            warnPct: (m['warnPct'] as num?)?.toDouble(),
            stableBaseline: m['stableBaseline'] as Map?,
            reservePct: (m['reservePct'] as num?)?.toDouble() ?? 0.0,
            trackedSubjects:
                (m['trackedSubjects'] as List?)?.cast<Object?>(),
            absenceDetails: m['absenceDetails'] as Map?,
          );
          result = [
            [for (final s in r.$1) stateJson(s)],
            r.$2,
          ];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
