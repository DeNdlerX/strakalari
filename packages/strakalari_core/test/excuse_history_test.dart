import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/excuse_history.dart';
import 'package:strakalari_core/src/planning/planner.dart' show schoolYearTerms;
import 'package:strakalari_core/src/storage/config.dart';

Map<String, Object?> dayEntry(String d, int first, int last,
    [String kind = 'days and hours']) => {
      'type': kind,
      'starting_day': d,
      'ending_day': d,
      'starting_lesson': first,
      'ending_lesson': last,
    };

void main() {
  final week = {
    'type': 'pure days',
    'starting_day': '07.09.2026',
    'ending_day': '11.09.2026',
  };
  final hours = {
    'type': 'days and hours',
    'starting_day': '14.09.2026',
    'ending_day': '14.09.2026',
    'starting_lesson': 2,
    'ending_lesson': 4,
  };
  final span = {
    'type': 'days and hours',
    'starting_day': '15.09.2026',
    'ending_day': '17.09.2026',
    'starting_lesson': 5,
    'ending_lesson': 2,
  };

  group('coverage', () {
    test('broaderWebExcuseCoversSingleDay', () {
      expect(
          excuseCovered({
            'type': 'pure days',
            'starting_day': '9.9.2026',
            'ending_day': '9.9.2026',
          }, [week]),
          isTrue);
      expect(excuseCovered(dayEntry('10.09.2026', 1, 3), [week]), isTrue);
    });

    test('partialOverlapIsNotCovered', () {
      expect(
          excuseCovered({
            'type': 'pure days',
            'starting_day': '10.09.2026',
            'ending_day': '14.09.2026',
          }, [week]),
          isFalse);
      expect(excuseCovered(dayEntry('14.09.2026', 3, 5), [hours]), isFalse);
      expect(excuseCovered(dayEntry('14.09.2026', 3, 4, 'income'), [hours]),
          isTrue);
    });

    test('hourRangeNeverCoversWholeDay', () {
      expect(
          excuseCovered({
            'type': 'pure days',
            'starting_day': '14.09.2026',
            'ending_day': '14.09.2026',
          }, [hours]),
          isFalse);
    });

    test('multiDayHourSpanSemantics', () {
      expect(excuseCovered(dayEntry('15.09.2026', 5, 7), [span]), isTrue);
      expect(excuseCovered(dayEntry('15.09.2026', 4, 4), [span]), isFalse);
      expect(excuseCovered(dayEntry('16.09.2026', 1, 8), [span]), isTrue);
      expect(excuseCovered(dayEntry('17.09.2026', 1, 2), [span]), isTrue);
      expect(excuseCovered(dayEntry('17.09.2026', 3, 3), [span]), isFalse);
    });

    test('taskCoveredMatchesUiRules', () {
      expect(taskCovered(DateTime(2026, 9, 8), 3, [week]), isTrue);
      expect(taskCovered(DateTime(2026, 9, 14), 2, [hours]), isTrue);
      expect(taskCovered(DateTime(2026, 9, 14), 5, [hours]), isFalse);
      expect(taskCovered(DateTime(2026, 9, 14), null, [hours]), isFalse);
    });
  });

  group('normalization', () {
    test('nonPaddedDatesCanonicalized', () {
      final item = normalizeHistoryItem({
        'type': 'pure days',
        'starting_day': '7.9.2026',
        'ending_day': '8.9.2026',
      });
      expect(item['starting_day'], '07.09.2026');
      expect(item['ending_day'], '08.09.2026');
    });

    test('stripsUiKeys', () {
      final base = baseExcuse({
        'type': 'income',
        'starting_day': '10.09.2026',
        'ending_day': '10.09.2026',
        'starting_lesson': 1,
        'ending_lesson': 1,
        'templates': ['t'],
        'default_preview': 'p',
        'signature': 's',
      });
      expect(base, {
        'type': 'income',
        'starting_day': '10.09.2026',
        'ending_day': '10.09.2026',
        'starting_lesson': 1,
        'ending_lesson': 1,
      });
    });

    test('historyEntriesStoreEveryHourShape', () {
      final rows = historyEntries({
        'type': 'soon',
        'starting_day': '3.9.2026',
        'ending_day': '3.9.2026',
        'starting_lesson': 5,
        'ending_lesson': 5,
        'templates': ['ui-only'],
      });
      expect(rows.map((r) => r['type']).toList(),
          ['income', 'soon', 'days and hours']);
      expect(
          rows.every((r) =>
              r['starting_day'] == '03.09.2026' &&
              !r.containsKey('templates')),
          isTrue);
      expect(
          historyEntries({
            'type': 'pure days',
            'starting_day': '1.9.2026',
            'ending_day': '2.9.2026',
          }),
          [
            {
              'type': 'pure days',
              'starting_day': '01.09.2026',
              'ending_day': '02.09.2026',
            }
          ]);
    });
  });

  group('exampleFallback', () {
    test('managerFiltersExampleFallback', () {
      final dir =
          Directory.systemTemp.createTempSync('history_example_');
      try {
        final hist = '${dir.path}/hist.json';
        File('${dir.path}/hist.example.json').writeAsStringSync(jsonEncode([
          {
            'type': 'pure days',
            'starting_day': 'VAS_DEMO_DEN',
            'ending_day': 'VAS_DEMO_DEN'
          },
          {'type': 'pure days', 'starting_day': '01.09.2026', 'ending_day': '02.09.2026'},
          'junk',
          {'no': 'days'},
        ]));
        final mgr = ConfigManager('${dir.path}/c.json');
        mgr.set('already_excused_file', hist);
        expect(mgr.getExcuseHistory(), [
          {
            'type': 'pure days',
            'starting_day': '01.09.2026',
            'ending_day': '02.09.2026',
          }
        ]);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('historyQuarantine', () {
      final dir =
          Directory.systemTemp.createTempSync('history_quarantine_');
      try {
        final bad = '${dir.path}/hist.json';
        File(bad).writeAsStringSync('{corrupt');
        final mgr = ConfigManager('${dir.path}/c.json');
        mgr.set('already_excused_file', bad);
        expect(mgr.getExcuseHistory(), isEmpty);
        expect(
            Directory(dir.path)
                .listSync()
                .where((e) =>
                    e.path.contains('hist.json.corrupt') ||
                    e.path.contains('hist'))
                .toList(),
            isNotEmpty);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('unconfirmedHelpers', () {
    final lesson = {
      'type': 'days and hours',
      'starting_day': '21.09.2026',
      'ending_day': '21.09.2026',
      'starting_lesson': 3,
      'ending_lesson': 4,
    };
    final day = {
      'type': 'pure days',
      'starting_day': '22.09.2026',
      'ending_day': '22.09.2026',
    };
    final now = DateTime(2026, 9, 25, 12, 0);

    test('sidecarSitsNextToHistory', () {
      expect(unconfirmedPath('/d/already_excused_lessons.json'),
          '/d/already_excused_lessons.unconfirmed.json');
    });

    test('overlapBlocksEvenAPartialResend', () {
      final pending = [unconfirmedEntry(lesson, now)];
      expect(unconfirmedBlocks(Map.of(lesson), pending), isTrue);
      expect(
          unconfirmedBlocks(
              {...lesson, 'starting_lesson': 4, 'ending_lesson': 4},
              pending),
          isTrue);
      expect(
          unconfirmedBlocks(
              {...lesson, 'starting_lesson': 6, 'ending_lesson': 6},
              pending),
          isFalse);
      expect(unconfirmedBlocks(day, pending), isFalse);
    });

    test('wholeDayBlocksItsLessons', () {
      final pending = [unconfirmedEntry(day, now)];
      expect(
          unconfirmedBlocks({
            ...lesson,
            'starting_day': '22.09.2026',
            'ending_day': '22.09.2026',
          }, pending),
          isTrue);
    });

    test('resolve', () {
      final old = now.subtract(
          unconfirmedMinAge + const Duration(minutes: 1));
      final sent = unconfirmedEntry(lesson, old);
      final lost = unconfirmedEntry(day, old);
      final fresh = unconfirmedEntry({
        ...day,
        'starting_day': '23.09.2026',
        'ending_day': '23.09.2026',
      }, now);
      final (still, confirmed, notSent) = resolveUnconfirmed(
          [sent, lost, fresh], [Map.of(lesson)], DateTime(2026, 8, 26),
          now);
      expect(confirmed, [sent]);
      expect(notSent, [lost]);
      expect(still, [fresh]);
    });

    test('submitBeforeTheOutboxRangeStaysOpen', () {
      final old = unconfirmedEntry(day, DateTime(2026, 8, 1, 9, 0));
      final (still, confirmed, notSent) =
          resolveUnconfirmed([old], [], DateTime(2026, 8, 26), now);
      expect(still, [old]);
      expect(confirmed, isEmpty);
      expect(notSent, isEmpty);
    });

    test('sidecarRoundtrip', () {
      final dir =
          Directory.systemTemp.createTempSync('unconfirmed_io_');
      try {
        final hist = '${dir.path}/history.json';
        File(hist).writeAsStringSync('[]');
        expect(loadUnconfirmed(hist), isEmpty);
        saveUnconfirmed(hist, [unconfirmedEntry(lesson, now)]);
        final loaded = loadUnconfirmed(hist);
        expect(loaded, hasLength(1));
        expect(loaded.single['starting_lesson'], 3);
        saveUnconfirmed(hist, []);
        expect(File(unconfirmedPath(hist)).existsSync(), isFalse);
        expect(loadUnconfirmed(hist), isEmpty);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('corruptSidecarIsQuarantinedAndReadAsEmpty', () {
      for (final bytes in [
        utf8.encode('{not json'),
        [0xff, 0xfe, 0x00, 0x80], // invalid UTF-8
      ]) {
        final dir =
            Directory.systemTemp.createTempSync('unconfirmed_bad_');
        try {
          final hist = '${dir.path}/history.json';
          File(unconfirmedPath(hist)).writeAsBytesSync(bytes);
          expect(loadUnconfirmed(hist), isEmpty);
          expect(File(unconfirmedPath(hist)).existsSync(), isFalse);
          expect(
              dir.listSync().any((e) => e.path.contains('.corrupt-')),
              isTrue);
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
    });
  });

  group('mergeSentExcuses', () {
    test('addsOnlyNew', () {
      final history = [
        {
          'type': 'pure days',
          'starting_day': '07.09.2026',
          'ending_day': '08.09.2026',
        }
      ];
      final discovered = [
        {
          'type': 'pure days',
          'starting_day': '07.09.2026',
          'ending_day': '08.09.2026',
        },
        {
          'type': 'pure days',
          'starting_day': '10.09.2026',
          'ending_day': '10.09.2026',
        },
      ];
      final (merged, added) = mergeSentExcuses(history, discovered);
      expect(added, 1);
      expect(merged, hasLength(2));
    });

    test('canonicalizesSpellings', () {
      final history = [
        {
          'type': 'pure days',
          'starting_day': '7.9.2026',
          'ending_day': '8.9.2026',
        }
      ];
      final discovered = [
        {
          'type': 'pure days',
          'starting_day': '07.09.2026',
          'ending_day': '08.09.2026',
        }
      ];
      final (merged, added) = mergeSentExcuses(history, discovered);
      expect(added, 0);
      expect(merged, hasLength(1));
    });

    test('stripsUiKeysAndIgnoresJunk', () {
      final (merged, added) = mergeSentExcuses([], [
        {
          'type': 'pure days',
          'starting_day': '10.09.2026',
          'ending_day': '10.09.2026',
          'templates': ['x'],
          'default_preview': 'y',
        },
        'not-a-dict',
        null,
      ]);
      expect(added, 1);
      expect(merged, [
        {
          'type': 'pure days',
          'starting_day': '10.09.2026',
          'ending_day': '10.09.2026',
        }
      ]);
    });
  });

  group('semesterExcuseWindowStart', () {
    test('currentSemesterStartMatchesSchoolYearTermsAcrossAllMonths', () {
      for (var m = 1; m <= 12; m++) {
        final d = DateTime(2026, m, 15);
        final terms = schoolYearTerms(d);
        final expected = (m >= 2 && m <= 7) ? terms[1].$2 : terms[0].$2;
        expect(currentSemesterStart(d), expected, reason: 'month $m');
      }
      expect(currentSemesterStart(DateTime(2027, 1, 15)), DateTime(2026, 9, 1));
      expect(currentSemesterStart(DateTime(2027, 2, 1)), DateTime(2027, 2, 1));
    });

    test('coversFullCurrentSemesterAndTransitionsCleanly', () {
      // Mid-1st semester with school-year outbox.
      expect(
        semesterExcuseWindowStart(DateTime(2026, 11, 20), DateTime(2026, 8, 20)),
        DateTime(2026, 9, 1),
      );
      // Mid-2nd semester with school-year outbox.
      expect(
        semesterExcuseWindowStart(DateTime(2027, 3, 15), DateTime(2026, 8, 20)),
        DateTime(2027, 2, 1),
      );
      // Semester transition: 30-day rolling window beats Feb 1.
      expect(
        semesterExcuseWindowStart(DateTime(2027, 2, 5), DateTime(2026, 8, 20)),
        DateTime(2027, 1, 6),
      );
      // Narrower outboxFrom clamps to outboxFrom.
      expect(
        semesterExcuseWindowStart(DateTime(2026, 11, 20), DateTime(2026, 10, 21)),
        DateTime(2026, 10, 21),
      );
      // Unknown or future outboxFrom stays on rolling 30-day window.
      expect(
        semesterExcuseWindowStart(DateTime(2026, 11, 20), null),
        DateTime(2026, 10, 21),
      );
      expect(
        semesterExcuseWindowStart(DateTime(2026, 11, 20), DateTime(2026, 11, 25)),
        DateTime(2026, 10, 21),
      );
      // DST dates stay at local midnight.
      final spring =
          semesterExcuseWindowStart(DateTime(2026, 3, 30), DateTime(2026, 1, 1));
      expect(spring, DateTime(2026, 2, 1));
      expect((spring.hour, spring.minute), (0, 0));
      final autumn =
          semesterExcuseWindowStart(DateTime(2026, 10, 26), DateTime(2026, 8, 20));
      expect(autumn, DateTime(2026, 9, 1));
      expect((autumn.hour, autumn.minute), (0, 0));
    });
  });
}
