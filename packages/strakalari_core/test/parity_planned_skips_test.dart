import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/planned_skips.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<DateTime, List<int>> intDays(Object? value) => {
      for (final e in (value as Map).entries)
        DateTime.parse(e.key as String):
            (e.value as List).map((p) => (p as num).toInt()).toList(),
    };

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('planned_skips')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'normalizePlannedEntry':
          result = normalizePlannedEntry(args[0]);
        case 'cancelsLunch':
          result = cancelsLunch(strMap(args[0]));
        case 'entryStartIso':
          result = entryStartIso(strMap(args[0]));
        case 'entryEndIso':
          result = entryEndIso(strMap(args[0]));
        case 'entryDays':
          result = entryDays(strMap(args[0]),
              args.length > 1 ? args[1] as int : 62);
        case 'entryCovers':
          result = entryCovers(
              strMap(args[0]), args[1] as DateTime, args[2] as int?);
        case 'entriesForSelection':
          result = entriesForSelection(
            picked: {
              for (final e in intDays(args[0]).entries)
                e.key: e.value.cast<Object?>(),
            },
            lessons: {
              for (final e in intDays(args[1]).entries)
                e.key: e.value.cast<Object?>(),
            },
            template: args.length > 2 ? args[2] as String : '',
            cancelLunch: args.length > 3 ? args[3] as bool : true,
          );
        case 'loadPlannedSkips':
          result = loadPlannedSkips(
              args[0] == null ? null : strMap(args[0]));
        case 'plannedLunchDays':
          result = plannedLunchDays(
              args[0] == null ? null : strMap(args[0])).toList()
            ..sort();
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
