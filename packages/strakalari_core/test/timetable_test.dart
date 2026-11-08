import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/bakalari/timetable.dart';

import 'fake_bakalari.dart';

List<Object?> fixtureDetails(String name) {
  final raw = File('../../tests/fixtures/$name').readAsStringSync();
  return (jsonDecode(raw) as List).cast<Object?>();
}

void main() {
  group('addTimetableDetails', () {
    test('mergesDetailsGroupedPerDaySortedByPeriod', () {
      final bak = BakalariClient({});
      bak.addTimetableDetails([
        {
          'teacher': 'Mgr. Jan Novák',
          'subjecttext': 'Matematika',
          'subjectshort': 'M',
          'room': 'U1',
          'day': '10.09.2026',
          'time': '2 (8:55 - 9:40)',
          'absencetext': 'Absence',
          'absenceType': 'Absent',
        },
        {
          'teacher': 'Mgr. Eva Bílá',
          'subjecttext': 'Fyzika',
          'subjectshort': 'FY',
          'room': 'L1',
          'day': '10.09.2026',
          'time': '1 (8:00 - 8:45)',
          'absencetext': '',
          'absenceType': '',
        },
        // Entry with missing teacher should be skipped.
        {
          'teacher': '',
          'subjecttext': 'Volná hodina',
          'day': '10.09.2026',
          'time': '3',
        },
      ]);

      expect(bak.timetableData.containsKey('10.09.2026'), isTrue);
      final lessons =
          (bak.timetableData['10.09.2026'] as List).cast<Map<String, Object?>>();
      expect(lessons, hasLength(2));
      // Sorted by lesson time (period 1 before period 2).
      expect(lessons[0]['subject'], 'Fyzika');
      expect(lessons[1]['subject'], 'Matematika');
      expect(lessons[1]['absenceType'], 'Absent');
    });

    test('intoSeparateTarget', () {
      final bak = BakalariClient({});
      final Map<String, Object?> stable = {};
      bak.addTimetableDetails([
        {
          'teacher': 'Novák',
          'subjecttext': 'M',
          'day': '07.09.2026',
          'time': '1 (8:00 - 8:45)',
        }
      ], target: stable);
      expect(bak.timetableData, isEmpty);
      expect(stable.containsKey('07.09.2026'), isTrue);
      expect((stable['07.09.2026'] as List).single['subject'], 'M');
    });

    test('extractKeepsRemovedRows', () {
      final bak = BakalariClient({});
      Map<String, Object?> removedDetail() => {
            'type': 'removed',
            'subjecttext': null,
            'teacher': null,
            'room': null,
            'absentinfo': null,
            'removedinfo': 'Zrušeno (FG, Dušek Filip)',
            'AbsentInfo': null,
            'day': '18.9.2026 (pátek)',
            'time': '13:40 - 14:25',
          };
      Map<String, Object?> movedDetail() => {
            'type': 'atom',
            'subjecttext': 'Matematika',
            'teacher': 'Mgr. Jana Tláskalová',
            'room': 'II - (313)',
            'group': '8.1 celá - celá třída',
            'theme': '',
            'notice': '',
            'changeinfo': 'Změna místnosti: II (I)',
            'absencetext': '',
            'absenceType': 'NoAbsent',
            'day': '18.9.2026 (pátek)',
            'time': '3 (10:05 - 10:50)',
            'hourIndex': 5,
            'changeBadgeChar': 'M',
            'infoChangeCode': 'RoomChanged',
          };
      bak.addTimetableDetails([movedDetail(), removedDetail()]);
      final friday =
          (bak.timetableData['18.9.2026 (pátek)'] as List).cast<Map<String, Object?>>();
      expect(friday, hasLength(2));
      final removed =
          friday.where((l) => l['type'] == 'removed').toList();
      expect(removed, hasLength(1));
      expect(removed.single['status'], 'cancelled');
    });
  });

  group('permView', () {
    test('isToldApartByIdentCode', () {
      final perm = fixtureDetails('timetable_perm_view.json');
      final actual = fixtureDetails('timetable_actual_week.json');
      expect(isPermView(perm), isTrue);
      expect(isPermView(actual), isFalse);
      expect(isPermView([...perm, ...actual]), isFalse);
      expect(isPermView([]), isFalse);
    });

    test('extractStableTimetableScrapesPermView', () async {
      final perm = fixtureDetails('timetable_perm_view.json');
      final actual = fixtureDetails('timetable_actual_week.json');
      final server = FakeBakalari({
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final payload = jsonDecode(utf8.decode(req.body)) as Map;
          final term = '${payload['term']}';
          return weekContent(term == 'perm'
              ? perm.cast<Map<String, Object?>>()
              : actual.cast<Map<String, Object?>>());
        },
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      expect(await bak.extractStableTimetable(), isTrue);
      // Asks for exactly the stable ("perm") view.
      final calls = server.calls('POST', '/Timetable/GetContentData');
      expect(calls, hasLength(1));
      final asked =
          jsonDecode(utf8.decode(calls.single.body)) as Map;
      expect(asked['term'], 'perm');
      // Stable rows land in their own dict, actual weeks untouched.
      expect(bak.timetableData, isEmpty);
      expect(bak.stableTimetableData.isNotEmpty, isTrue);
    });

    test('extractStableTimetableRejectsStaleActualWeek', () async {
      final actual = fixtureDetails('timetable_actual_week.json');
      final server = FakeBakalari({
        'POST /Timetable/GetContentData': (_) => weekContent(
            actual.cast<Map<String, Object?>>()),
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      expect(await bak.extractStableTimetable(), isFalse);
      expect(bak.stableTimetableData, isEmpty);
    });
  });

  group('fetchTimetableWeeks', () {
    Map<String, Object?> lesson(DateTime day) => {
          'day': '${day.day}.${day.month}.${day.year}',
          'teacher': 'Novák',
          'subjecttext': 'Matematika',
          'time': '1 (8:00 - 8:45)',
        };

    test('eachWeekIsRequestedByItsMonday', () async {
      final server = FakeBakalari({
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final payload =
              jsonDecode(utf8.decode(req.body)) as Map;
          final date = DateTime.parse('${payload['date']}');
          return weekContent([
            lesson(date),
          ]);
        },
      });
      final bak = BakalariClient(
          {...fakeConfig, 'go_back_weeks': 2, 'go_forward_weeks': 1},
          transport: server);
      await bak.fetchTimetableWeeks();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final monday =
          today.subtract(Duration(days: today.weekday - 1));
      final asked = [
        for (final r
            in server.calls('POST', '/Timetable/GetContentData'))
          jsonDecode(utf8.decode(r.body)) as Map
      ];
      String isoDay(DateTime d) => d.toIso8601String().split('T').first;
      expect(
          [for (final a in asked) a['date']],
          [
            for (final off in [1, 0, -1])
              isoDay(monday.add(Duration(days: off * 7)))
          ]);
      expect({for (final a in asked) a['term']}, {'cal'});
      expect(bak.timetableSources, hasLength(3));
      expect(bak.timetableLoadedWeeks, contains(monday));
    });
  });
}
