// Parity with the real Python code around the Prague DST switches
// (test/parity/dst.json, from `dump_dst` in tools/parity/dump.py).
//
// The real Dart code runs under `withClock` on 30.3.2026 and 26.10.2026
// and must ask for the same Mondays and send the same dates as Python.
// Run with `TZ=Europe/Prague` (dart.yml): on a UTC machine the old
// `Duration(days: n)` bug hides.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/client.dart';

import 'fake_bakalari.dart';
import 'parity_cases.dart';

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The local day a `…T…Z` request value stands for.
DateTime localDay(String utc) {
  final d = DateTime.parse(utc).toLocal();
  return DateTime(d.year, d.month, d.day);
}

void main() {
  group('dstParityWithPython', () {
    test('fetchTimetableWeeksAsksForPythonsMondays', () async {
      final cases = loadParityCases('dst')
          .where((c) => c['fn'] == 'fetchTimetableWeeks');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final args = (c['args'] as List).map(decodeParityValue).toList();
        final today = args[0] as DateTime;
        final expected = c['expected'] as Map;
        final server = FakeBakalari({
          'POST /Timetable/GetContentData': (FakeRequest req) =>
              weekContent(const []),
        });
        final bak = BakalariClient({
          ...fakeConfig,
          'go_back_weeks': args[1],
          'go_forward_weeks': args[2],
        }, transport: server);
        bak.historyWeeks = [...(args[3] as List).cast<DateTime>()];
        await withClock(Clock.fixed(DateTime(today.year, today.month,
            today.day, 9, 30)), () => bak.fetchTimetableWeeks());
        final asked = [
          for (final r in server.calls('POST', '/Timetable/GetContentData'))
            (jsonDecode(utf8.decode(r.body)) as Map)['date']
        ];
        expect(asked, expected['asked'], reason: iso(today));
        expect([for (final m in bak.timetableLoadedWeeks) iso(m)]..sort(),
            expected['loaded'],
            reason: iso(today));
      }
    });

    test('substitutionRangeIsPythonsCalendarRange', () async {
      final cases = loadParityCases('dst')
          .where((c) => c['fn'] == 'substitutionRange');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final today =
            decodeParityValue((c['args'] as List).first) as DateTime;
        final server = FakeBakalari({
          'POST /Timetable/substitutions/dates': {
            'success': true,
            'data': <Object?>[],
          },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await withClock(Clock.fixed(DateTime(today.year, today.month,
            today.day, 9, 30)), () => bak.fetchSubstitutions());
        final request =
            server.calls('POST', '/Timetable/substitutions/dates').single;
        final form = Uri.splitQueryString(utf8.decode(request.body));
        expect(
            [iso(localDay(form['dateFrom']!)), iso(localDay(form['dateTo']!))],
            c['expected'],
            reason: iso(today));
      }
    });
  });
}
