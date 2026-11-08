// Port of tests/test_news.py (pure cases).
//
// test_refresh_reports_news_against_the_cache needs the refresh pipeline
// (phase 4) and is ported with it.
import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/news.dart';

final DateTime today = DateTime(2099, 10, 1);
const String past = '29.9.2099 (úterý)';
const String future = '5.10.2099 (pondělí)';

Map<String, Object?> lesson(
  int period, [
  String subject = 'M',
  Map<String, Object?> extra = const {},
]) => {'subject': subject, 'time': '$period (8:00 - 8:45)', ...extra};

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));

  group('newMarks', () {
    test('newMarkReportedOnce', () {
      final old = {
        'grades': {
          'M': [
            {'Id': '1', 'Grade': '2', 'Date': '1.9.2099'},
          ],
        },
      };
      final fresh = {
        'grades': {
          'M': [
            {'Id': '1', 'Grade': '2', 'Date': '1.9.2099'},
            {'Id': '2', 'Grade': '1', 'Date': '2.9.2099', 'Caption': 'Test'},
          ],
          'F': [
            {'Grade': '3', 'Date': '2.9.2099'},
          ],
        },
      };
      expect(newMarks(old, fresh), ['M 1 (Test)', 'F 3']);
      expect(newMarks(fresh, fresh), isEmpty);
    });

    test('marksNeedAPreviousStateAndSkipAnnouncedOnes', () {
      final fresh = {
        'grades': {
          'M': [
            {'Id': '1', 'Grade': '1'},
          ],
        },
      };
      expect(newMarks({}, fresh), isEmpty); // first sync
      expect(newMarks(fresh, {}), isEmpty); // grades did not load this time
      final planned = {
        'grades': {
          'M': [
            {'Id': '1', 'Grade': '?'},
          ],
        },
      };
      expect(newMarks({'grades': {}}, planned), isEmpty);
      // The announced mark given later keeps its id: still a new mark.
      expect(newMarks(planned, fresh), ['M 1']);
    });
  });

  group('newQuarterlyMarks', () {
    test('newOrChangedQuarterlyMarkReportedOnce', () {
      final old = {
        'quarterly_marks': {
          'M': {'Grade': '2'},
          'F': {'Grade': '1'},
        },
      };
      final fresh = {
        'quarterly_marks': {
          'M': {'Grade': '1'},
          'F': {'Grade': '1'},
          'D': {'Grade': '3'},
        },
      };
      expect(newQuarterlyMarks(old, fresh), ['M 1', 'D 3']);
      expect(newQuarterlyMarks(fresh, fresh), isEmpty);
      expect(newQuarterlyMarks({}, fresh), isEmpty); // never read before
      expect(newQuarterlyMarks(fresh, {}), isEmpty); // not loaded this time
      final news = Map.fromEntries(
        findNews(
          {'quarterly_marks': {}},
          {
            'quarterly_marks': {
              'M': {'Grade': '1'},
            },
          },
        ),
      );
      expect(news, {'new_quarterly_mark': 'Čtvrtletní známka: M 1'});
    });
  });

  group('newAbsences', () {
    test('newAbsenceOnlyOnKnownDays', () {
      final old = {
        'timetable': {
          past: [
            lesson(1),
            lesson(2, 'M', {'absenceType': 'Absent'}),
          ],
        },
      };
      final fresh = {
        'timetable': {
          past: [
            lesson(1, 'M', {'absenceType': 'Absent'}),
            lesson(2, 'M', {
              'absenceType': 'Excused',
              'absencetext': 'Omluveno',
            }),
          ],
          // First loaded now (history week): nothing to compare with.
          '1.9.2099': [
            lesson(1, 'M', {'absenceType': 'Absent'}),
          ],
        },
      };
      expect(newAbsences(old, fresh), ['M 29. 9., 1. hodina']);
      expect(newAbsences(fresh, fresh), isEmpty);
    });
  });

  group('newChanges', () {
    test('newTimetableChangeFromTodayOn', () {
      final old = {
        'timetable': {
          past: [lesson(1)],
          future: [lesson(1), lesson(2)],
        },
      };
      final fresh = {
        'timetable': {
          past: [
            lesson(1, 'M', {'infoChangeCode': 'Removed', 'type': 'removed'}),
          ],
          future: [
            lesson(1),
            lesson(2, 'M', {'infoChangeCode': 'Removed', 'type': 'removed'}),
          ],
        },
      };
      expect(newChanges(old, fresh, today), ['M 5. 10., 2. hodina: odpadá']);
      expect(newChanges(fresh, fresh, today), isEmpty);
    });
  });

  group('findNews', () {
    test('findNewsBuildsMessages', () {
      final old = <String, Object?>{
        'grades': {},
        'timetable': {
          future: [lesson(1)],
        },
      };
      final marks = [
        for (var i = 0; i < 6; i++) {'Id': '$i', 'Grade': '1'},
      ];
      final fresh = {
        'grades': {'M': marks},
        'timetable': {
          future: [
            lesson(1, 'M', {'infoChangeCode': 'Removed', 'type': 'removed'}),
          ],
        },
      };
      final news = Map.fromEntries(findNews(old, fresh, today));
      expect(news['new_mark'], 'Nové známky: M 1; M 1; M 1; M 1 a další (2)');
      expect(
        news['timetable_change'],
        'Změna v rozvrhu: M 5. 10., 1. hodina: odpadá',
      );
      expect(news, isNot(contains('new_absence')));
    });
  });
}
