// The phone's morning brief (morning_brief.dart): settings, the school days
// it comes on, what it says and the queue handed to the phone.
import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/morning_brief.dart';
import 'package:strakalari_core/src/status_notification.dart';
import 'package:strakalari_core/src/storage/config.dart';

// Monday 9 November 2026 and the rest of that week.
const String mon = '09.11.2026';
const String tue = '10.11.2026';
const String wed = '11.11.2026';

Map<String, Object?> menu(String table, List<String> dishes) => {
  '$table&-1&0': 'no lunch',
  for (var i = 0; i < dishes.length; i++) '$table&${i + 1}&0': dishes[i],
};

final Map<String, Object?> tt = {
  mon: [
    {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika', 'room': '214'},
    {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika', 'room': '105'},
  ],
  tue: [
    {
      'time': '1 (8:00 - 8:45)',
      'subject': 'Chemie',
      'room': 'L1',
      'status': 'cancelled',
    },
  ],
  wed: [
    {'time': '3 (10:00 - 10:45)', 'subject': 'Dějepis', 'room': '12'},
  ],
};

Map<String, Object?> cfg([Map<String, Object?> extra = const {}]) => {
  'school_preset_id': 'custom',
  'user_free_days': [],
  'holidays': [],
  'morning_brief_enabled': true,
  'morning_brief_time': '06:30',
  'morning_brief_items': ['next_lesson', 'lunch'],
  ...extra,
};

StatusInputs inputs({
  Map<String, Object?>? config,
  Set<DateTime>? freeDays,
  int pendingExcuses = 0,
}) => StatusInputs(
  timetable: Map.of(tt),
  food: {
    mon: menu('table0', ['oběd 1 - Řízek(01)']),
    wed: menu('table2', ['oběd 1 - Rizoto']),
  },
  webOrders: {mon: 'table0&1&0'},
  config: config ?? cfg(),
  pendingExcuses: pendingExcuses,
  freeDays: freeDays ?? {},
);

class _Bridge implements MorningBriefPhoneBridge {
  final List<(String, String)> calls = [];

  @override
  bool setMorningBriefs(String queueJson, String channelName) {
    calls.add((queueJson, channelName));
    return true;
  }
}

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() {
    setLanguage('cs');
    morningBriefPhoneBridge = null;
    resetMorningBriefSyncState();
  });

  group('settings', () {
    test('defaultsMatchTheConfigSchema', () {
      expect(canonicalDefaults['morning_brief_enabled'], isFalse);
      expect(canonicalDefaults['morning_brief_time'], defaultBriefTime);
      expect(
        canonicalDefaults['morning_brief_items'],
        orderedEquals(defaultBriefItems),
      );
      expect(selectedBriefItems({}), orderedEquals(defaultBriefItems));
      expect(defaultBriefItems.toSet().difference(items.toSet()), isEmpty);
    });

    test('timeParsing', () {
      expect(parseBriefTime('6:30'), (6, 30));
      expect(parseBriefTime('06:05'), (6, 5));
      expect(parseBriefTime(' 7.15 '), (7, 15));
      expect(parseBriefTime('24:00'), isNull);
      expect(parseBriefTime('6:60'), isNull);
      expect(parseBriefTime('soon'), isNull);
      expect(parseBriefTime(null), isNull);
      expect(formatBriefTime(6, 5), '06:05');
      expect(briefTimeOf({'morning_brief_time': 'x'}), (6, 30));
    });

    test('itemSelectionKeepsDisplayOrder', () {
      expect(
        selectedBriefItems({
          'morning_brief_items': ['excuses', 'bogus', 'next_lesson'],
        }),
        ['next_lesson', 'excuses'],
      );
      expect(
        withBriefItem(
          {
            'morning_brief_items': ['excuses'],
          },
          'lunch',
          true,
        ),
        ['lunch', 'excuses'],
      );
      expect(
        withBriefItem({}, 'lunch', false),
        ['next_lesson', 'lunch_orders', 'excuses'],
      );
    });

    test('validation', () {
      // Fresh-install defaults flag empty Strava creds; this tests the brief.
      Map<String, Object?> base() =>
          Map.of(defaultConfig())..['use_strava'] = false;
      expect(validateConfig(base()), isEmpty);
      expect(
        validateConfig(base()..['morning_brief_time'] = '25:00'),
        contains(contains('morning_brief_time')),
      );
      expect(
        validateConfig(base()..['morning_brief_items'] = ['bogus']),
        contains(contains('morning_brief_items')),
      );
      expect(
        validateConfig(base()..['morning_brief_enabled'] = 'yes'),
        contains(contains('morning_brief_enabled')),
      );
    });
  });

  group('upcomingMorningBriefs', () {
    test('oneBriefPerSchoolDayAtTheSetTime', () {
      final briefs = upcomingMorningBriefs(
        inputs(),
        since: DateTime(2026, 11, 8, 20),
        horizonDays: 5,
      );
      // Tuesday's only lesson is cancelled: no school, no brief.
      expect([for (final b in briefs) b.at], [
        DateTime(2026, 11, 9, 6, 30),
        DateTime(2026, 11, 11, 6, 30),
      ]);
    });

    test('offMeansNone', () {
      expect(
        upcomingMorningBriefs(
          inputs(config: cfg({'morning_brief_enabled': false})),
          since: DateTime(2026, 11, 8, 20),
        ),
        isEmpty,
      );
    });

    test('aDayPlannedOffGetsNoBrief', () {
      List<DateTime> briefDays(Map<String, Object?> skip) => [
        for (final b in upcomingMorningBriefs(
          inputs(config: cfg({'planned_skips': [skip]})),
          since: DateTime(2026, 11, 8, 20),
          horizonDays: 5,
        ))
          DateTime(b.at.year, b.at.month, b.at.day),
      ];
      // Monday's both lessons planned off: like the alarm, no brief.
      expect(
        briefDays({'start_date': '2026-11-09', 'end_date': '2026-11-09'}),
        [DateTime(2026, 11, 11)],
      );
      // Only the first one: Monday still has school.
      expect(
        briefDays({
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 1,
          'end_period': 1,
        }),
        [DateTime(2026, 11, 9), DateTime(2026, 11, 11)],
      );
    });

    test('freeDaysAndPassedTimesAreSkipped', () {
      final briefs = upcomingMorningBriefs(
        inputs(freeDays: {DateTime(2026, 11, 11)}),
        since: DateTime(2026, 11, 9, 7),
        horizonDays: 5,
      );
      expect(briefs, isEmpty);
    });

    test('theRowsAreWorkedOutForTheBriefsTime', () {
      final brief = upcomingMorningBriefs(
        inputs(),
        since: DateTime(2026, 11, 8, 20),
        horizonDays: 1,
      ).single;
      final content = brief.content;
      expect(content.title, 'Ranní přehled');
      expect(content.sub, 'Ranní přehled');
      expect([for (final r in content.rows) r.kind], ['next_lesson', 'lunch']);
      // The day's first lesson and today's lunch, not "tomorrow".
      expect(content.rows.first.label, 'Další hodina');
      expect(content.rows.first.value, startsWith('1. Matematika · 8:00'));
      expect(content.rows.last.label, 'Oběd dnes');
      expect(content.rows.last.value, 'Oběd 1 - Řízek');
      expect(content.text.split('\n'), [
        for (final r in content.rows) r.line,
      ]);
    });

    test('nothingToSayMeansNoBrief', () {
      // "0 excuses" alone says nothing (as in the always-on notification).
      final briefs = upcomingMorningBriefs(
        inputs(config: cfg({'morning_brief_items': ['excuses']})),
        since: DateTime(2026, 11, 8, 20),
        horizonDays: 1,
      );
      expect(briefs, isEmpty);
      final some = upcomingMorningBriefs(
        inputs(
          config: cfg({'morning_brief_items': ['excuses']}),
          pendingExcuses: 2,
        ),
        since: DateTime(2026, 11, 8, 20),
        horizonDays: 1,
      );
      expect(some.single.content.rows.single.value, '2');
    });

    test('followsTheLanguage', () {
      final brief = upcomingMorningBriefs(
        inputs(),
        since: DateTime(2026, 11, 8, 20),
        horizonDays: 1,
        lang: 'en',
      ).single;
      expect(brief.content.title, 'Morning brief');
      expect(brief.content.rows.last.label, 'Lunch today');
    });
  });

  group('syncMorningBrief', () {
    test('handsOverTheQueueOnlyWhenItChanges', () {
      final bridge = _Bridge();
      morningBriefPhoneBridge = bridge;
      final now = DateTime(2026, 11, 8, 20);
      syncMorningBrief(inputs(), now: now);
      syncMorningBrief(inputs(), now: now);
      expect(bridge.calls, hasLength(1));
      final (json, channel) = bridge.calls.single;
      expect(channel, 'Ranní přehled');
      final queue = (jsonDecode(json) as List).cast<Map<String, Object?>>();
      expect(queue.first['at'], DateTime(2026, 11, 9, 6, 30).millisecondsSinceEpoch);
      expect(
        queue.first['until'],
        DateTime(2026, 11, 9, 8, 30).millisecondsSinceEpoch,
      );
      final rows = jsonDecode(queue.first['rows'] as String) as List;
      expect([for (final r in rows) (r as Map)['kind']], [
        'next_lesson',
        'lunch',
      ]);

      // Off: an empty queue cancels what the phone holds.
      syncMorningBrief(null, now: now);
      expect(bridge.calls.last.$1, '[]');
    });

    test('keepsABriefThatIsJustDue', () {
      final bridge = _Bridge();
      morningBriefPhoneBridge = bridge;
      // Five minutes past Monday's brief: still in the queue (a late
      // delivery must not drop out), the phone never arms it anew.
      syncMorningBrief(inputs(), now: DateTime(2026, 11, 9, 6, 35));
      final queue = jsonDecode(bridge.calls.single.$1) as List;
      expect(
        (queue.first as Map)['at'],
        DateTime(2026, 11, 9, 6, 30).millisecondsSinceEpoch,
      );
    });

    test('noBridgeNoWork', () {
      syncMorningBrief(inputs(), now: DateTime(2026, 11, 8, 20));
    });
  });
}
