import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/schedule.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<Object?, Object?> anyMap(Object? value) =>
    Map<Object?, Object?>.from(value as Map);

Map<String, Object?> slotJson(SlotBaseline s) => {
      'weekday': s.weekday,
      'period': s.period,
      'subject': s.subject,
      'teacher': s.teacher,
      'room': s.room,
      'startMin': s.startMin,
      'support': s.support,
    };

Map<String, Object?> diffJson(LessonDiff d) => {
      'isChange': d.isChange,
      'changed': d.changed,
      'note': d.note,
    };

Map<String, Object?> changeJson(Map<String, Object?> item) => {
      ...item,
      'diff': diffJson(item['diff'] as LessonDiff),
    };

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('schedule')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseTimeRange':
          final r = parseTimeRange(args[0]);
          result = r == null ? null : [r.$1, r.$2, r.$3, r.$4];
        case 'lessonClock':
          final r = lessonClock(
              args[0] as Map?, args.length > 1 ? args[1] : null);
          result = r == null ? null : [r.$1, r.$2];
        case 'periodOf':
          result = periodOf(
              args[0] as Map?, args.length > 1 ? args[1] : null);
        case 'resolveDayLessons':
          result = resolveDayLessons(
            (args[0] as List).cast<Object?>(),
            args.length > 1 ? args[1] as DateTime? : null,
            args.length > 2 ? args[2] : null,
          );
        case 'futureLessons':
          result = futureLessons(
            (args[0] as List).cast<Object?>(),
            args.length > 1 ? args[1] as DateTime? : null,
            args.length > 2 ? args[2] : null,
          );
        case 'stableWeeklyHours':
          result = stableWeeklyHours(baselineFromDict(anyMap(args[0])));
        case 'baselineToDict':
          result = baselineToDict(baselineFromDict(anyMap(args[0])));
        case 'baselineFromDict':
          result = baselineToDict(baselineFromDict(anyMap(args[0])));
        case 'stableTemplateWeek':
          final week = stableTemplateWeek(
            baselineFromDict(anyMap(args[0])),
            args.length > 1 ? args[1] as DateTime? : null,
          );
          result = {for (final e in week.entries) iso(e.key): e.value};
        case 'closestVariant':
          final slot = args[0] == null
              ? null
              : SlotBaseline(
                  weekday: (args[0] as Map)['weekday'] as int,
                  period: (args[0] as Map)['period'] as int,
                  subject: '${(args[0] as Map)['subject'] ?? ''}',
                  teacher: '${(args[0] as Map)['teacher'] ?? ''}',
                  room: '${(args[0] as Map)['room'] ?? ''}',
                  startMin: (args[0] as Map)['startMin'] as int?,
                  support: (args[0] as Map)['support'] as int? ?? 0,
                );
          final found = closestVariant(
              slot, args[1] as Map?, args.length > 2 ? args[2] : null);
          result = found == null ? null : slotJson(found);
        case 'classifyLesson':
          final base = baselineFromDict(anyMap(args[2]));
          result = diffJson(classifyLesson(
            args[0] as Map?,
            args.length > 1 ? args[1] : null,
            base,
            args.length > 3 ? args[3] as bool : false,
          ));
        case 'iterChanges':
          final base = args.length > 1
              ? baselineFromDict(anyMap(args[1]))
              : <Object?, Object?>{};
          result = [
            for (final item in iterChanges(anyMap(args[0]), base))
              changeJson(item),
          ];
        case 'iterNotes':
          final base = args.length > 1
              ? baselineFromDict(anyMap(args[1]))
              : <Object?, Object?>{};
          result = [
            for (final item in iterNotes(anyMap(args[0]), base))
              changeJson(item),
          ];
        case 'backfillStableFacts':
          final table = anyMap(args[0]);
          final base = baselineFromDict(anyMap(args[1]));
          final n = backfillStableFacts(table, base);
          result = [n, table, baselineToDict(base)];
        case 'applySubstitutionFeed':
          final table = anyMap(args[0]);
          final n = applySubstitutionFeed(
              table, (args[1] as List).cast<Object?>());
          result = [n, table];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
