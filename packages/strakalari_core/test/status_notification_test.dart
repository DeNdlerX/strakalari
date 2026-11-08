// Port of tests/test_status_notification.py (pure cases).
//
// Deferred to their owners: TestAndroidBridge (Java/pyjnius bridge, phase 8),
// TestPhoneWiring/TestSettings (app wiring and Flet views, phase 7/8) and the
// config-validation subtest's UI half. The pure selection asserts are here;
// background_notification_items validation itself is covered by config tests.
import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/status_notification.dart';
import 'package:strakalari_core/src/storage/config.dart';

// No school holidays, the 12:00 lunch cutoff.
const Map<String, Object?> cfg = {
  'school_preset_id': 'custom',
  'user_free_days': [],
  'holidays': [],
};
const List<String> all = [
  'next_lesson',
  'lunch',
  'lunch_orders',
  'excuses',
  'wakeup',
  'updated',
];
const Map<String, Object?> allCfg = {
  'school_preset_id': 'custom',
  'user_free_days': [],
  'holidays': [],
  'background_notification_items': all,
};

// Monday 9 November 2026 and the rest of that week.
const String mon = '09.11.2026';
const String tue = '10.11.2026';
const String wed = '11.11.2026';
const String thu = '12.11.2026';
const String fri = '13.11.2026';
const String nextMon = '16.11.2026';

Map<String, Object?> menu(String table, List<String> dishes) => {
  '$table&-1&0': 'Monday 09/11/2026', // the day's "no lunch" control
  for (var i = 0; i < dishes.length; i++) '$table&${i + 1}&0': dishes[i],
};

final Map<String, Object?> food = {
  mon: menu('table0', [
    'oběd 1 - Polévka,Kuřecí řízek, kaše(01, 07 )',
    'oběd 2 - Guláš(01)',
  ]),
  tue: menu('table1', ['oběd 1 - Svíčková(01)']),
  wed: menu('table2', ['oběd 1 - Rizoto']),
  fri: menu('table4', ['oběd 1 - Ryba']),
  nextMon: menu('table5', ['oběd 1 - Buchtičky se šodó']),
};

final Map<String, Object?> tt = {
  mon: [
    {
      'time': '1 (8:00 - 8:45)',
      'subject': 'Matematika',
      'room': '214',
      'teacher': 'Mgr. Jan Novák',
    },
    {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika', 'room': '105'},
    {'time': '4 (10:55 - 11:40)', 'subject': 'Dějepis', 'room': '12'},
  ],
  tue: [
    {'time': '1 (8:00 - 8:45)', 'subject': 'Chemie', 'room': 'L1'},
  ],
};

StatusInputs inputs({
  Map<String, Object?>? timetable,
  Map<String, Object?>? foodOverride,
  Map<String, Object?>? webOrders,
  Map<String, Object?>? config,
  int pendingExcuses = 0,
  DateTime? lastUpdated,
  Set<DateTime>? freeDays,
}) => StatusInputs(
  timetable: timetable ?? Map.of(tt),
  food: foodOverride ?? Map.of(food),
  webOrders: webOrders ?? {mon: 'table0&1&0'},
  config: config ?? Map.of(allCfg),
  pendingExcuses: pendingExcuses,
  lastUpdated: lastUpdated,
  freeDays: freeDays,
);

/// The rows as "label: value"; dates keep the no-break space read as a space.
List<String> lines(StatusContent content) => [
  for (final row in content.rows) row.line.replaceAll('\u00a0', ' '),
];

(String, String)? lunch(StatusContent content) {
  for (final row in content.rows) {
    if (row.kind == 'lunch') return (row.label, row.value);
  }
  return null;
}

// Periods 1-7 at a typical school's times.
const Map<int, String> clock = {
  1: '8:00 - 8:45',
  2: '8:55 - 9:40',
  3: '10:00 - 10:45',
  4: '10:55 - 11:40',
  5: '11:50 - 12:35',
  6: '12:45 - 13:30',
  7: '13:40 - 14:25',
};

List<Map<String, Object?>> day(
  List<int> periods, {
  List<int> cancelled = const [],
}) => [
  for (final p in periods)
    {
      'time': '$p (${clock[p]})',
      'subject': 'Předmět $p',
      if (cancelled.contains(p)) 'status': 'cancelled',
    },
];

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() {
    setLanguage('cs');
    lunchOrdersRowBuilder = buildLunchOrdersRow;
  });

  group('selectedItems', () {
    test('defaultsMatchTheConfigSchema', () {
      expect(
        canonicalDefaults['background_notification_items'],
        orderedEquals(defaultItems),
      );
      expect(selectedItems({}), orderedEquals(defaultItems));
      expect(defaultItems.toSet().difference(items.toSet()), isEmpty);
    });

    test('selectionKeepsDisplayOrderAndDropsUnknown', () {
      expect(
        selectedItems({
          'background_notification_items': [
            'excuses',
            'bogus',
            'lunch',
            'next_lesson',
          ],
        }),
        ['next_lesson', 'lunch', 'excuses'],
      );
      expect(
        selectedItems({'background_notification_items': 'lunch'}),
        orderedEquals(defaultItems),
      );
      expect(selectedItems({'background_notification_items': []}), isEmpty);
    });

    test('switchingAnItem', () {
      expect(
        withItem(
          {
            'background_notification_items': ['excuses'],
          },
          'lunch',
          true,
        ),
        ['lunch', 'excuses'],
      );
      expect(
        withItem(
          {
            'background_notification_items': ['excuses'],
          },
          'excuses',
          false,
        ),
        isEmpty,
      );
    });

    test('configValidation', () {
      List<String> problems(Object? value) => validateConfig({
        'use_strava': false,
        'background_notification_items': value,
      }).where((p) => p.contains('background_notification_items')).toList();
      expect(problems(['lunch', 'updated']), isEmpty);
      expect(problems([]), isEmpty);
      expect(problems(['lunch', 'weather']), isNotEmpty);
      expect(problems('lunch'), isNotEmpty);
    });
  });

  group('lunchOverAt', () {
    String? at(
      List<Map<String, Object?>> monday, [
      Map<String, List<Map<String, Object?>>>? rest,
    ]) {
      final timetable = <String, Object?>{
        mon: monday,
        for (final entry in (rest ?? {}).entries) entry.key: entry.value,
      };
      final minute = lunchOverAt(
        StatusInputs(timetable: timetable, config: Map.of(cfg)),
        DateTime(2026, 11, 9),
      );
      return minute == null
          ? null
          : '${minute ~/ 60}:${(minute % 60).toString().padLeft(2, '0')}';
    }

    test('theFirstFreePeriodAfterTheFourth', () {
      // Period 5 is free on Monday; Tuesday shows when period 5 ends.
      expect(
        at(day([1, 2, 3, 4, 6]), {
          tue: day([1, 2, 3, 4, 5]),
        }),
        '12:35',
      );
    });

    test('aFreePeriodOfUnknownTimeEndsWhenTheNextLessonStarts', () {
      expect(at(day([1, 2, 3, 4, 6])), '12:45');
    });

    test('onlyTheFirstOfTwoFreePeriods', () {
      expect(
        at(day([1, 2, 3, 4, 7]), {
          tue: day([1, 2, 3, 4, 5, 6]),
        }),
        '12:35',
      );
    });

    test('aCancelledLessonLeavesItsPeriodFree', () {
      expect(at(day([1, 2, 3, 4, 5, 6], cancelled: [5])), '12:35');
    });

    test('withoutAGapAfterTheFourthLunchEndsWithTheClasses', () {
      expect(at(day([1, 2, 3, 4, 5, 6])), '13:30');
      // A gap before the 4th doesn't count.
      expect(at(day([1, 2, 4])), '11:40');
      expect(at(day([1, 2, 3])), '10:45');
    });

    test('noLessons', () {
      expect(at([]), isNull);
      expect(at(day([1, 2], cancelled: [1, 2])), isNull);
    });

    test('theLunchLineFollowsIt', () {
      final timetable = {
        mon: day([1, 2, 3, 4, 6]),
        tue: day([1, 2, 3, 4, 5]),
      };
      final before = buildStatus(
        inputs(timetable: timetable),
        now: DateTime(2026, 11, 9, 12, 34),
        lang: 'cs',
      );
      expect(lunch(before), (
        'Oběd dnes',
        'Oběd 1 - Polévka, Kuřecí řízek, kaše',
      ));
      final after = buildStatus(
        inputs(timetable: timetable),
        now: DateTime(2026, 11, 9, 12, 35),
        lang: 'cs',
      );
      expect(lunch(after), ('Oběd zítra', 'Neobjednáno'));
    });

    test('aDayWithoutLessonsSwitchesAtThree', () {
      final before = buildStatus(
        inputs(timetable: {}),
        now: DateTime(2026, 11, 9, 14, 59),
        lang: 'en',
      );
      expect(lunch(before)!.$1, 'Lunch today');
      final after = buildStatus(
        inputs(timetable: {}),
        now: DateTime(2026, 11, 9, 15, 0),
        lang: 'en',
      );
      expect(lunch(after)!.$1, 'Lunch tomorrow');
    });
  });

  group('lunchRow', () {
    test('todaysLunchUntilClassesEndThenTheNext', () {
      // Monday: periods 1, 2 and 4, so lunch is over when period 4 ends.
      final morning = buildStatus(
        inputs(),
        now: DateTime(2026, 11, 9, 11, 39),
        lang: 'cs',
      );
      expect(lunch(morning), (
        'Oběd dnes',
        'Oběd 1 - Polévka, Kuřecí řízek, kaše',
      ));
      final afternoon = buildStatus(
        inputs(),
        now: DateTime(2026, 11, 9, 11, 40),
        lang: 'cs',
      );
      expect(lunch(afternoon), ('Oběd zítra', 'Neobjednáno'));
    });

    test('weekendAndGapsShowTheNextMenuDay', () {
      final withOrders = inputs(
        webOrders: {fri: 'table4&1&0', nextMon: 'table5&1&0'},
      );
      final thursday = buildStatus(
        withOrders,
        now: DateTime(2026, 11, 12, 9, 0),
        lang: 'cs',
      );
      // No menu on Thursday.
      expect(lunch(thursday), ('Oběd zítra', 'Oběd 1 - Ryba'));
      final friday = buildStatus(
        withOrders,
        now: DateTime(2026, 11, 13, 16, 0),
        lang: 'en',
      );
      expect(lunch(friday), ('Lunch on Monday', 'Oběd 1 - Buchtičky se šodó'));
      expect(
        lunch(
          buildStatus(
            withOrders,
            now: DateTime(2026, 11, 13, 16, 0),
            lang: 'cs',
          ),
        )!.$1,
        'Oběd v pondělí',
      );
    });

    test('noLunchAndUnknownMeal', () {
      final none = inputs(webOrders: {mon: 'table0&-1&0'});
      expect(
        lunch(buildStatus(none, now: DateTime(2026, 11, 9, 7, 0), lang: 'en')),
        ('Lunch today', 'Not ordered'),
      );
      // Ordered, but not on the menu.
      final gone = inputs(webOrders: {mon: 'table0&9&0'});
      expect(
        lunch(
          buildStatus(gone, now: DateTime(2026, 11, 9, 7, 0), lang: 'cs'),
        )!.$2,
        'Objednáno',
      );
    });

    test('stravaOffHidesTheLunchLines', () {
      final noStrava = inputs(config: {...allCfg, 'use_strava': false});
      final result = lines(
        buildStatus(noStrava, now: DateTime(2026, 11, 9, 7, 0), lang: 'cs'),
      );
      expect(result.first, startsWith('Další hodina'));
      expect(
        result.where((l) => l.contains('Oběd') || l.contains('obědy')),
        isEmpty,
      );
    });

    test('mealText', () {
      expect(
        mealText('oběd 1 - Polévka,Hlavní jídlo, příloha(01, 07 )'),
        'Oběd 1 - Polévka, Hlavní jídlo, příloha',
      );
      expect(mealText('  Kulajda;  Svíčková (1,3,7)'), 'Kulajda; Svíčková');
      // Not an allergen list.
      expect(mealText('Rizoto (hrášek)'), 'Rizoto (hrášek)');
    });
  });

  group('nextLessonRow', () {
    String line(DateTime now, {StatusInputs? argv, String lang = 'cs'}) {
      final result = lines(
        buildStatus(
          argv ?? inputs(config: {...allCfg, 'use_strava': false}),
          now: now,
          lang: lang,
        ),
      );
      return result.firstWhere(
        (l) => l.contains('hodina') || l.contains('lesson'),
        orElse: () => '',
      );
    }

    test('beforeAndDuringSchool', () {
      expect(
        line(DateTime(2026, 11, 9, 7, 0)),
        'Další hodina: 1. Matematika · 8:00 · 214 · Novák',
      );
      // Fyzika runs since 8:55; period 3 is free.
      expect(
        line(DateTime(2026, 11, 9, 9, 0)),
        'Další hodina: 4. Dějepis · 10:55 · 12',
      );
      expect(
        line(DateTime(2026, 11, 9, 9, 0), lang: 'en'),
        'Next lesson: 4. Dějepis · 10:55 · 12',
      );
    });

    test('afterSchoolTheNextSchoolDay', () {
      expect(
        line(DateTime(2026, 11, 9, 12, 0)),
        'Další hodina zítra: 1. Chemie · 8:00 · L1',
      );
      final holiday = {
        ...allCfg,
        'use_strava': false,
        'user_free_days': [
          {'date': tue, 'label': 'Ředitelské volno'},
        ],
      };
      final withThu = inputs(
        timetable: {
          ...tt,
          thu: [
            {'time': '2 (8:55 - 9:40)', 'subject': 'Biologie'},
          ],
        },
        config: holiday,
      );
      expect(
        line(DateTime(2026, 11, 9, 12, 0), argv: withThu, lang: 'en'),
        'Next lesson on Thursday: 2. Biologie · 8:55',
      );
    });

    test('daysOffHandedOverWithTheData', () {
      // The app passes the calendar's days off along (no preset reads/tick).
      final withWed = inputs(
        timetable: {
          ...tt,
          wed: [
            {'time': '1 (8:00 - 8:45)', 'subject': 'Zeměpis'},
          ],
        },
        config: {...allCfg, 'use_strava': false},
        freeDays: {DateTime(2026, 11, 10)},
      );
      expect(
        line(DateTime(2026, 11, 9, 12, 0), argv: withWed),
        'Další hodina ve středu: 1. Zeměpis · 8:00',
      );
    });

    test('cancelledAndPlannedLessonsAreSkipped', () {
      final timetable = {
        mon: [
          {
            'time': '1 (8:00 - 8:45)',
            'subject': 'Matematika',
            'status': 'cancelled',
          },
          {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika'},
          {'time': '3 (10:00 - 10:45)', 'subject': 'Chemie'},
        ],
      };
      final config = {
        ...allCfg,
        'use_strava': false,
        'planned_skips': [
          {
            'start_date': '2026-11-09',
            'end_date': '2026-11-09',
            'start_period': 2,
            'end_period': 2,
          },
        ],
      };
      expect(
        line(
          DateTime(2026, 11, 9, 7, 0),
          argv: inputs(timetable: timetable, config: config),
        ),
        'Další hodina: 3. Chemie · 10:00',
      );
    });

    test('noTimetableNoLine', () {
      expect(
        line(DateTime(2026, 11, 9, 7, 0), argv: inputs(timetable: {})),
        isEmpty,
      );
    });
  });

  group('otherLines', () {
    test('openOrdersNameTheDaysAndTheFirstDeadline', () {
      final result = lines(
        buildStatus(inputs(), now: DateTime(2026, 11, 9, 7, 0), lang: 'cs'),
      );
      expect(
        result,
        contains(
          'Neobjednané obědy: Út 10. 11., St 11. 11., Pá 13. 11. '
          'a další 1 · uzávěrka dnes 12:00',
        ),
      );
      // Past Monday noon Tuesday closed; a planned day off doesn't count.
      final config = {
        ...allCfg,
        'planned_skips': [
          {'start_date': '2026-11-11', 'end_date': '2026-11-11'},
        ],
      };
      final en = lines(
        buildStatus(
          inputs(config: config),
          now: DateTime(2026, 11, 9, 13, 0),
          lang: 'en',
        ),
      );
      expect(
        en,
        contains(
          'Lunches not ordered: Fri 13. 11., Mon 16. 11. · '
          'order by Thursday 12:00',
        ),
      );
    });

    test('moreThanThreeOpenDays', () {
      final withThu = Map.of(food)
        ..[thu] = menu('table3', ['oběd 1 - Halušky']);
      // Sunday: Monday's lunch closed on Friday, the other five are open.
      final result = lines(
        buildStatus(
          inputs(foodOverride: withThu, webOrders: {}),
          now: DateTime(2026, 11, 8, 10, 0),
          lang: 'cs',
        ),
      );
      expect(
        result,
        contains(
          'Neobjednané obědy: Út 10. 11., St 11. 11., Čt 12. 11. '
          'a další 2 · uzávěrka zítra 12:00',
        ),
      );
    });

    test('excusesAlsoWhenNoneWait', () {
      final now = DateTime(2026, 11, 9, 7, 0);
      expect(
        lines(buildStatus(inputs(pendingExcuses: 2), now: now, lang: 'cs')),
        contains('Omluvenky k odeslání: 2'),
      );
      expect(
        lines(buildStatus(inputs(), now: now, lang: 'cs')),
        contains('Omluvenky k odeslání: 0'),
      );
      // Alone, "none to send" gives way to the plain text.
      final only = {
        ...cfg,
        'background_notification_items': ['excuses'],
      };
      expect(
        buildStatus(
          inputs(config: only),
          now: now,
          fallback: ('A', 'B'),
        ),
        StatusContent('A', 'B', ''),
      );
      expect(
        lines(
          buildStatus(
            inputs(config: only, pendingExcuses: 1),
            now: now,
            lang: 'en',
          ),
        ),
        ['Excuses to send: 1'],
      );
    });

    test('wakeupAlarm', () {
      final config = {
        ...allCfg,
        'wakeup_enabled': true,
        'wakeup_minutes_before': 60,
      };
      final result = lines(
        buildStatus(
          inputs(config: config),
          now: DateTime(2026, 11, 9, 7, 30),
          lang: 'cs',
        ),
      );
      expect(result, contains('Budík: zítra v 7:00'));
      final en = lines(
        buildStatus(
          inputs(config: config),
          now: DateTime(2026, 11, 9, 6, 0),
          lang: 'en',
        ),
      );
      expect(en, contains('Alarm: today at 7:00'));
      final short = {
        for (final r in buildStatus(
          inputs(config: config),
          now: DateTime(2026, 11, 9, 6, 0),
          lang: 'en',
        ).rows)
          r.kind: r.short,
      };
      expect(short['wakeup'], '7:00');
      final withNextMon = inputs(
        config: config,
        timetable: {
          ...tt,
          nextMon: [
            {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
          ],
        },
      );
      final friday = buildStatus(
        withNextMon,
        now: DateTime(2026, 11, 13, 9, 0),
        lang: 'cs',
      );
      expect(lines(friday), contains('Budík: v pondělí v 7:00'));
      expect(
        {for (final r in friday.rows) r.kind: r.short}['wakeup'],
        'Po 7:00',
      );
      // Picked by default, shown only while the alarm is on.
      final defaults = Map.of(config)..remove('background_notification_items');
      final now = DateTime(2026, 11, 9, 7, 30);
      expect(
        lines(
          buildStatus(
            inputs(config: defaults),
            now: now,
            lang: 'cs',
          ),
        ),
        contains('Budík: zítra v 7:00'),
      );
      expect(
        lines(
          buildStatus(
            inputs(config: {...defaults, 'wakeup_enabled': false}),
            now: now,
            lang: 'cs',
          ),
        ).where((l) => l.startsWith('Budík')),
        isEmpty,
      );
    });

    test('updatedGoesToTheHeader', () {
      final stamp = DateTime(2026, 11, 9, 6, 40);
      final now = DateTime(2026, 11, 9, 7, 0);
      expect(
        buildStatus(
          inputs(lastUpdated: stamp),
          now: now,
          lang: 'cs',
        ).sub,
        'Aktualizováno 6:40',
      );
      expect(
        buildStatus(
          inputs(lastUpdated: stamp),
          now: now.add(const Duration(days: 1)),
          lang: 'en',
        ).sub,
        'Updated 9.\u00a011. 6:40',
      );
      final off = {
        ...allCfg,
        'background_notification_items': ['lunch'],
      };
      expect(
        buildStatus(
          inputs(lastUpdated: stamp, config: off),
          now: now,
        ).sub,
        isEmpty,
      );
    });

    test('nothingToShowKeepsThePlainText', () {
      final noExcuses = StatusInputs(
        config: Map.of(allCfg),
        lastUpdated: DateTime(2026, 11, 9, 6, 40),
      );
      final content = buildStatus(
        noExcuses,
        now: DateTime(2026, 11, 9, 7, 0),
        fallback: ('Běží na pozadí', 'Každých 30 min'),
        lang: 'cs',
      );
      expect(
        content,
        StatusContent('Běží na pozadí', 'Každých 30 min', 'Aktualizováno 6:40'),
      );
      final none = <String, Object?>{
        ...cfg,
        'background_notification_items': [],
      };
      expect(
        buildStatus(
          inputs(config: none),
          now: DateTime(2026, 11, 9, 7, 0),
          fallback: ('A', 'B'),
        ),
        StatusContent('A', 'B', ''),
      );
    });

    test('aBrokenLineLeavesTheOthers', () {
      lunchOrdersRowBuilder = (_, _, _) => throw StateError('broken calendar');
      final content = buildStatus(
        inputs(pendingExcuses: 1),
        now: DateTime(2026, 11, 9, 7, 0),
        lang: 'en',
      );
      expect(lunch(content)!.$1, 'Lunch today');
      expect(lines(content), contains('Excuses to send: 1'));
      expect(content.rows.where((r) => r.kind == 'lunch_orders'), isEmpty);
    });

    test('rowsInOrderAndAsTitleAndText', () {
      final content = buildStatus(
        inputs(pendingExcuses: 2),
        now: DateTime(2026, 11, 9, 7, 0),
        lang: 'cs',
      );
      expect(
        [for (final r in content.rows) r.kind],
        ['next_lesson', 'lunch', 'lunch_orders', 'excuses'],
      );
      // Where no rows are drawn: the first row's label, its value and lines.
      expect(content.title, 'Další hodina');
      final text = content.text.split('\n');
      expect(text[0], '1. Matematika · 8:00 · 214 · Novák');
      expect(text[1], 'Oběd dnes: Oběd 1 - Polévka, Kuřecí řízek, kaše');
      expect(text.last, 'Omluvenky k odeslání: 2');
    });

    test('shortValuesForTheCollapsedView', () {
      final content = buildStatus(
        inputs(pendingExcuses: 2),
        now: DateTime(2026, 11, 9, 11, 50),
        lang: 'cs',
      );
      final rows = <String, Map<String, Object?>>{
        for (final Map<String, Object?> row
            in (jsonDecode(content.rowsJson()) as List)
                .cast<Map<String, Object?>>())
          row['kind'] as String: row,
      };
      // Today's lesson is over: the next one says when; so does tomorrow's.
      expect(rows['next_lesson']!['short'], 'zítra: 1. Chemie · 8:00 · L1');
      expect(rows['next_lesson']!['label'], 'Další hodina zítra');
      expect(rows['lunch']!['short'], 'zítra: Neobjednáno');
      // Counts stand next to their icon (a collapsed line is ~250 dp across).
      expect(rows['excuses'], {
        'kind': 'excuses',
        'label': 'Omluvenky k odeslání',
        'value': '2',
        'short': '2',
      });
      // Tuesday open until 12:00.
      expect(rows['lunch_orders']!['short'], '4');
      final friday = buildStatus(
        inputs(webOrders: {nextMon: 'table5&1&0'}),
        now: DateTime(2026, 11, 13, 16, 0),
        lang: 'cs',
      );
      final fridayLunch = (jsonDecode(friday.rowsJson()) as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((r) => r['kind'] == 'lunch');
      expect(fridayLunch['short'], 'Po: Oběd 1 - Buchtičky se šodó');
      final morning = buildStatus(
        inputs(),
        now: DateTime(2026, 11, 9, 7, 0),
        lang: 'cs',
      );
      final morningLunch = (jsonDecode(morning.rowsJson()) as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((r) => r['kind'] == 'lunch');
      expect(morningLunch['short'], 'Oběd 1 - Polévka, Kuřecí řízek, kaše');
      expect(morningLunch['short'], morningLunch['value']);
      expect(const StatusContent('A', 'B').rowsJson(), isEmpty);
    });
  });

  group('statusNotifier', () {
    _Notifier notifier([StatusInputs? argv]) {
      final state = <String, Object?>{
        'inputs': argv ?? inputs(),
        'gathered': 0,
        'ok': true,
      };
      final posted = <StatusContent>[];
      StatusInputs? gather() {
        state['gathered'] = (state['gathered'] as int) + 1;
        return state['inputs'] as StatusInputs?;
      }

      bool post(StatusContent content) {
        if (state['ok'] as bool) posted.add(content);
        return state['ok'] as bool;
      }

      return _Notifier(
        StatusNotifier(gather, post, () => ('F', 'f')),
        state,
        posted,
      );
    }

    test('postsChangesOnlyAndMovesWithTheClock', () {
      final n = notifier();
      expect(n.inner.tick(DateTime(2026, 11, 9, 8, 50)), isTrue);
      expect(lines(n.posted.last).first, startsWith('Další hodina: 2. Fyzika'));
      // Same minute.
      expect(n.inner.tick(DateTime(2026, 11, 9, 8, 50, 30)), isFalse);
      expect(n.inner.tick(DateTime(2026, 11, 9, 8, 51)), isFalse);
      // Fyzika has begun.
      expect(n.inner.tick(DateTime(2026, 11, 9, 8, 55)), isTrue);
      expect(n.posted.last.text, contains('4. Dějepis'));
      expect(n.state['gathered'], 1);
    });

    test('aPokeGathersAgain', () {
      final n = notifier();
      n.inner.tick(DateTime(2026, 11, 9, 7, 0));
      n.state['inputs'] = inputs(pendingExcuses: 3);
      n.inner.poke();
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 0)), isTrue);
      expect(n.posted.last.text, contains('Omluvenky k odeslání: 3'));
      expect(n.state['gathered'], 2);
    });

    test('aNewDayGathersAgain', () {
      final n = notifier();
      n.inner.tick(DateTime(2026, 11, 9, 23, 59));
      n.inner.tick(DateTime(2026, 11, 10, 0, 0));
      expect(n.state['gathered'], 2);
    });

    test('hiddenNotificationPostsNothingThenStartsAfresh', () {
      final n = notifier();
      n.inner.tick(DateTime(2026, 11, 9, 7, 0));
      n.state['inputs'] = null; // background running switched off
      n.inner.poke();
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 1)), isFalse);
      n.state['inputs'] = inputs();
      n.inner.poke();
      // Same content, sent again.
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 2)), isTrue);
      expect(n.posted[0], n.posted[1]);
    });

    test('aFailedPostIsTriedAgain', () {
      final n = notifier();
      n.state['ok'] = false;
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 0)), isFalse);
      n.state['ok'] = true;
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 1)), isTrue);
      expect(n.posted, hasLength(1));
    });

    test('currentCountsAsDelivered', () {
      final n = notifier();
      final content = n.inner.current(DateTime(2026, 11, 9, 7, 0));
      expect(content!.title, 'Další hodina');
      expect(n.inner.tick(DateTime(2026, 11, 9, 7, 0, 10)), isFalse);
      expect(n.posted, isEmpty);
    });

    test('aFailedGatherIsRetried', () {
      var calls = 0;
      StatusInputs? gather() {
        calls++;
        if (calls == 1) throw StateError('history file busy');
        return inputs();
      }

      final inner = StatusNotifier(gather, (_) => true);
      expect(() => inner.tick(DateTime(2026, 11, 9, 7, 0)), throwsStateError);
      expect(inner.tick(DateTime(2026, 11, 9, 7, 0, 5)), isTrue);
    });

    test('startAndStop', () {
      final n = notifier();
      n.inner.start();
      expect(n.inner.running, isTrue);
      n.inner.stop();
      expect(n.inner.running, isFalse);
    });
  });
}

class _Notifier {
  final StatusNotifier inner;
  final Map<String, Object?> state;
  final List<StatusContent> posted;
  _Notifier(this.inner, this.state, this.posted);
}
