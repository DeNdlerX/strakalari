import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/common.dart';

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

void main() {
  group('parseTimetableDetail', () {
    test('removedRowParsesToCancelledLesson', () {
      final lesson = parseTimetableDetail(removedDetail());
      expect(lesson, isNotNull);
      expect(lesson!['status'], 'cancelled');
      expect(lesson['type'], 'removed');
      expect(lesson['notice'], 'Zrušeno (FG, Dušek Filip)');
      expect(lesson['time'], '13:40 - 14:25');
      expect(lesson['date'], '18.9.2026 (pátek)');
      expect(lesson['subject'], 'FG');
      expect(lesson['teacher'], 'Dušek Filip');
    });

    test('emptyRemovedRowStillDropped', () {
      expect(parseTimetableDetail({'type': 'removed'}), isNull);
      expect(parseTimetableDetail(null), isNull);
      expect(parseTimetableDetail('garbage'), isNull);
    });

    test('atomRowWithoutTeacherStillDropped', () {
      expect(
          parseTimetableDetail({
            'type': 'atom',
            'teacher': '',
            'subjecttext': 'Volná hodina',
            'day': '10.09.2026',
            'time': '3',
          }),
          isNull);
    });

    test('roomMoveKeepsChangeinfoAsNote', () {
      final lesson = parseTimetableDetail(movedDetail());
      expect(lesson, isNotNull);
      expect(lesson!['notice'], 'Změna místnosti: II (I)');
      expect(lesson['infoChangeCode'], 'RoomChanged');
      expect(lesson['changeBadgeChar'], 'M');
      expect(lesson['room'], 'II');
      expect(lesson['period'], 3);
    });

    test('classEventStandsInForSubject', () {
      final lesson = parseTimetableDetail({
        'absentinfo': 'B',
        'removedinfo': 'beseda / přednáška',
        'day': '18.09.2026',
        'time': '1 (8:00 - 8:45)',
      });
      expect(lesson, isNotNull);
      expect(lesson!['type'], 'event');
      expect(lesson['subject'], 'beseda / přednáška');
      expect(lesson['status'], isNot(contains('cancelled')));
    });

    test('classEventWithoutNameDropped', () {
      expect(
          parseTimetableDetail({
            'absentinfo': 'B',
            'day': '18.09.2026',
          }),
          isNull);
    });

    test('hourIndexFallbackNeverInventsPeriodZero', () {
      final base = {
        'teacher': 'T',
        'subjecttext': 'M',
        'day': '07.09.2026',
        'time': 'bez čísla',
      };
      expect(
          parseTimetableDetail({...base, 'hourIndex': 2})!
              .containsKey('period'),
          isFalse);
      expect(
          parseTimetableDetail({...base, 'hourIndex': 3})!['period'], 1);
    });
  });

  group('detailDays', () {
    test('collectsDaysSkipsGarbage', () {
      final days = detailDays([
        {'day': '07.09.2026'},
        {'Day': '08.09.2026'},
        {'day': 'nonsense'},
        'junk',
      ]);
      expect(days,
          {DateTime(2026, 9, 7), DateTime(2026, 9, 8)});
    });
  });

  group('weekOffsets', () {
    test('coverForwardAndBack', () {
      // Default config: 4 back (incl. current) + 1 forward = next week first.
      expect(weekOffsets(4, 1), [1, 0, -1, -2, -3]);
      // Old behavior without forward weeks is unchanged.
      expect(weekOffsets(4, 0), [0, -1, -2, -3]);
      expect(weekOffsets(1, 2), [2, 1, 0]);
      expect(weekOffsets(0, 0), isEmpty);
      expect(weekOffsets('nonsense', null), isEmpty);
    });
  });
}
