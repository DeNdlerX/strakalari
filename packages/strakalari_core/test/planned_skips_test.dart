import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/planned_skips.dart';

DateTime day(String iso) => DateTime.parse(iso);

/// Mirrors the Python test helper: entries compared without the template key.
Map<String, Object?> withoutTemplate(Map<String, Object?> entry) {
  final copy = Map<String, Object?>.of(entry)..remove('template');
  return copy;
}

List<Map<String, Object?>> select(
  Map<String, List<int>> picked, [
  Map<String, List<int>>? lessons,
]) {
  final pickedDays = <DateTime, List<int>>{
    for (final e in picked.entries) day(e.key): e.value,
  };
  final lessonDays = <DateTime, List<int>>{
    for (final e in (lessons ?? {}).entries) day(e.key): e.value,
  };
  for (final d in pickedDays.keys) {
    lessonDays.putIfAbsent(d, () => [1, 2, 3, 4, 5, 6]);
  }
  return entriesForSelection(picked: pickedDays, lessons: lessonDays)
      .map(withoutTemplate)
      .toList();
}

void main() {
  group('normalizePlannedEntry', () {
    test('keeps period zero', () {
      final entry = normalizePlannedEntry({
        'start_date': '2026-10-05',
        'end_date': '2026-10-05',
        'start_period': 0,
        'end_period': 0,
        'template': 't',
      });
      expect(entry, isNotNull);
      expect(entry!['start_period'], 0);
      expect(entry['end_period'], 0);
    });

    test('upgrades legacy single-day shape', () {
      expect(
        normalizePlannedEntry({'date': '2026-10-05', 'template': 't'}),
        {
          'start_date': '2026-10-05',
          'end_date': '2026-10-05',
          'template': 't',
        },
      );
    });

    test('swaps a reversed range', () {
      final entry = normalizePlannedEntry({
        'start_date': '2026-10-07',
        'end_date': '2026-10-05',
        'template': 't',
      });
      expect(entry!['start_date'], '2026-10-05');
      expect(entry['end_date'], '2026-10-07');
    });

    test('rejects unparseable input', () {
      expect(normalizePlannedEntry(null), isNull);
      expect(normalizePlannedEntry('nope'), isNull);
      expect(normalizePlannedEntry({'template': 't'}), isNull);
      expect(
        normalizePlannedEntry({'date': 'not-a-date', 'template': 't'}),
        isNull,
      );
    });

    test('stores cancel_lunch only when explicitly false', () {
      final kept = normalizePlannedEntry(
          {'date': '2026-10-05', 'cancel_lunch': false});
      expect(kept!['cancel_lunch'], isFalse);
      final dropped = normalizePlannedEntry(
          {'date': '2026-10-05', 'cancel_lunch': true});
      expect(dropped!.containsKey('cancel_lunch'), isFalse);
      final missing = normalizePlannedEntry({'date': '2026-10-05'});
      expect(missing!.containsKey('cancel_lunch'), isFalse);
    });
  });

  group('entry helpers', () {
    test('cancels lunch unless the user kept it', () {
      expect(cancelsLunch({}), isTrue);
      expect(cancelsLunch({'cancel_lunch': false}), isFalse);
      expect(cancelsLunch({'cancel_lunch': true}), isTrue);
    });

    test('entry days are inclusive', () {
      expect(
        entryDays({
          'start_date': '2026-11-09',
          'end_date': '2026-11-11',
        }),
        [day('2026-11-09'), day('2026-11-10'), day('2026-11-11')],
      );
    });

    test('entry days honor the cap', () {
      final days = entryDays(
        {'start_date': '2026-11-01', 'end_date': '2026-12-31'},
        5,
      );
      expect(days, hasLength(5));
      expect(days.first, day('2026-11-01'));
    });

    test('entry covers follows the planner rule', () {
      final entry = {
        'start_date': '2026-11-09',
        'end_date': '2026-11-11',
        'start_period': 4,
        'end_period': 2,
      };
      expect(entryCovers(entry, day('2026-11-09'), 5), isTrue);
      // Before the start on day one.
      expect(entryCovers(entry, day('2026-11-09'), 3), isFalse);
      // Middle day: whole.
      expect(entryCovers(entry, day('2026-11-10'), 1), isTrue);
      expect(entryCovers(entry, day('2026-11-11'), 2), isTrue);
      // After the end on the last day.
      expect(entryCovers(entry, day('2026-11-11'), 3), isFalse);
      expect(entryCovers(entry, day('2026-11-12'), 1), isFalse);
      // Unnumbered lesson: covered.
      expect(entryCovers(entry, day('2026-11-09'), null), isTrue);
    });
  });

  group('entriesForSelection', () {
    test('whole days in a row merge across a weekend', () {
      const six = [1, 2, 3, 4, 5, 6];
      final entries = select({
        '2026-11-12': six,
        '2026-11-13': six,
        '2026-11-16': six,
      });
      expect(entries, [
        {'start_date': '2026-11-12', 'end_date': '2026-11-16'},
      ]);
    });

    test('a gap day splits the range', () {
      const six = [1, 2, 3, 4, 5, 6];
      final entries = select({'2026-11-10': six, '2026-11-12': six});
      expect(
        [for (final e in entries) e['start_date']],
        ['2026-11-10', '2026-11-12'],
      );
      expect(
        entries.every((e) => e['start_date'] == e['end_date']),
        isTrue,
      );
    });

    test('range may start late and end early', () {
      // Leave after the 3rd lesson on Monday, whole Tuesday,
      // back for the 3rd on Wednesday.
      final entries = select({
        '2026-11-09': [4, 5, 6],
        '2026-11-10': [1, 2, 3, 4, 5, 6],
        '2026-11-11': [1, 2],
      });
      expect(entries, [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-11',
          'start_period': 4,
          'end_period': 2,
        },
      ]);
    });

    test('scattered lessons become separate entries', () {
      final entries = select({
        '2026-11-09': [1, 2, 5],
      });
      expect(entries, [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'end_period': 2,
        },
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 5,
          'end_period': 5,
        },
      ]);
    });

    test('free periods do not split a run', () {
      // No lesson in period 3: picking 2 and 4 is one block.
      final entries = select(
        {
          '2026-11-09': [2, 4],
        },
        {
          '2026-11-09': [1, 2, 4, 5],
        },
      );
      expect(entries, [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 2,
          'end_period': 4,
        },
      ]);
    });

    test('a partial day does not join the next one', () {
      const six = [1, 2, 3, 4, 5, 6];
      final entries = select({'2026-11-09': [1, 2], '2026-11-10': six});
      expect(
        [
          for (final e in entries) (e['start_date'], e['end_date']),
        ],
        [
          ('2026-11-09', '2026-11-09'),
          ('2026-11-10', '2026-11-10'),
        ],
      );
    });

    test('ranges are capped at 31 days', () {
      const six = [1, 2, 3, 4, 5, 6];
      final start = day('2026-11-02');
      final picked = <String, List<int>>{};
      String two(int n) => n.toString().padLeft(2, '0');
      for (var n = 0; n < 40; n++) {
        final d = start.add(Duration(days: n));
        if (d.weekday <= DateTime.friday) {
          picked['${d.year}-${two(d.month)}-${two(d.day)}'] = six;
        }
      }
      final entries = select(picked);
      expect(entries, hasLength(2));
      for (final e in entries) {
        final span = day(e['end_date'] as String)
            .difference(day(e['start_date'] as String))
            .inDays;
        expect(span, lessThan(31));
      }
    });

    test('entries keep the template and lunch choice', () {
      final kept = entriesForSelection(
        picked: {day('2026-11-09'): [1]},
        lessons: {
          day('2026-11-09'): [1, 2],
        },
        template: 'T',
        cancelLunch: false,
      );
      expect(kept, [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'end_period': 1,
          'template': 'T',
          'cancel_lunch': false,
        },
      ]);
    });
  });

  group('config helpers', () {
    test('load planned skips normalizes and skips junk', () {
      expect(loadPlannedSkips(null), isEmpty);
      expect(loadPlannedSkips({}), isEmpty);
      expect(loadPlannedSkips({'planned_skips': 'nope'}), isEmpty);
      expect(
        loadPlannedSkips({
          'planned_skips': [
            {'date': '2026-10-05', 'template': 't'},
            'junk',
            {'date': 'bogus'},
          ],
        }),
        [
          {
            'start_date': '2026-10-05',
            'end_date': '2026-10-05',
            'template': 't',
          },
        ],
      );
    });

    test('planned lunch days are zero-padded DD.MM.YYYY', () {
      final days = plannedLunchDays({
        'planned_skips': [
          {
            'start_date': '2026-11-09',
            'end_date': '2026-11-10',
            'template': 't',
          },
          {
            'start_date': '2026-11-11',
            'end_date': '2026-11-11',
            'template': 't',
            'cancel_lunch': false,
          },
        ],
      });
      expect(days, {'09.11.2026', '10.11.2026'});
    });
  });
}
