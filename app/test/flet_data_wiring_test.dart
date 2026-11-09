import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_flet_data_wiring.py`.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_wiring_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('parseCzDateAcceptsWeekdaySuffix', () {
    expect(parseCzDate('10.9.2026 (čtvrtek)'), DateTime(2026, 9, 10));
    expect(parseCzDate('7.9.2026 (pondělí)'), DateTime(2026, 9, 7));
    expect(parseCzDate('07.09.2026'), DateTime(2026, 9, 7));
    expect(parseCzDate('nonsense'), isNull);
  });

  test('canonicalDayKeyUnifiesFormats', () {
    expect(canonicalDayKey('7.9.2026 (pondělí)'), '07.09.2026');
    expect(canonicalDayKey('07.09.2026'), '07.09.2026');
    expect(canonicalDayKey(DateTime(2026, 9, 7)), '07.09.2026');
  });

  test('lessonFromRealCacheRow', () {
    final raw = <String, Object?>{
      'subject': 'Matematika',
      'time': '3 (10:05 - 10:50)',
      'room': 'III - (P06)',
      'teacher': 'Mgr. Jana Tláskalová',
      'date': '10.9.2026 (čtvrtek)',
      'absenceType': 'NoAbsent',
      'absencetext': '',
      'notice': '',
    };
    final lesson = Lesson.fromLegacy(raw, '10.9.2026 (čtvrtek)');
    expect(lesson.day, DateTime(2026, 9, 10));
    expect(lesson.status, '');
    expect(lesson.excused, isFalse);
  });

  test('lessonStatusMapping', () {
    final base = <String, Object?>{
      'subject': 'M',
      'time': '1 (8:00 - 8:45)',
      'date': '7.9.2026 (pondělí)',
    };
    expect(
      Lesson.fromLegacy(
          {...base, 'absenceType': 'Absent', 'absencetext': 'Absence'}).status,
      'absent',
    );
    expect(
      Lesson.fromLegacy({
        ...base,
        'absenceType': 'AbsentLate',
        'absencetext': 'Pozdní příchod'
      }).status,
      'late',
    );
    expect(
      Lesson.fromLegacy({
        ...base,
        'absenceType': 'NoAbsent',
        'absencetext': '',
        'notice': 'Suplování (Král)'
      }).change,
      'Suplování (Král)',
    );
    expect(
      Lesson.fromLegacy({
        ...base,
        'absenceType': 'NoAbsent',
        'absencetext': '',
        'notice': 'Odpadá'
      }).status,
      'cancelled',
    );
    final excused = Lesson.fromLegacy(
        {...base, 'absenceType': 'Omluveno', 'absencetext': 'Omluveno'});
    expect(excused.status, 'excused');
    expect(excused.excused, isTrue);
    final demo = Lesson.fromLegacy(
      {
        'subject': 'F',
        'time': '1. 8:00 - 8:45',
        'status': 'late',
        'change': 'X'
      },
      '07.09.2026',
    );
    expect((demo.status, demo.change), ('late', 'X'));
  });

  test('excuseTasksFromRealAbsences', () {
    final lessons = [
      Lesson(subject: 'M', day: DateTime(2026, 9, 10), period: 3, status: 'absent'),
      Lesson(subject: 'F', day: DateTime(2026, 9, 10), period: 4, status: 'late'),
      Lesson(subject: 'C', day: DateTime(2026, 9, 10), period: 5, status: ''),
      Lesson(
          subject: 'E',
          day: DateTime(2026, 9, 10),
          period: 6,
          status: 'excused',
          excused: true),
    ];
    final tasks = excuseTasksFromLessons(lessons);
    expect([for (final t in tasks) t.kind]..sort(), ['late', 'short']);
  });

  test('lessonsFromRealTimetableKeys', () {
    final raw = <String, Object?>{
      '10.9.2026 (čtvrtek)': [
        {
          'subject': 'Matematika',
          'time': '3 (10:05 - 10:50)',
          'absenceType': 'NoAbsent',
          'absencetext': '',
        },
      ],
    };
    final lessons = lessonsFromTimetable(raw);
    expect(lessons, hasLength(1));
    expect(lessons.single.day, DateTime(2026, 9, 10));
  });

  test('stateUsesRealCache', () {
    final cache = {
      'absence': {'Matematika': 5.0},
      'last_updated': '07.09.2026 13:34:13',
      'strava_meals': {
        '07.09.2026': {'a&1&0': 'Guláš'}
      },
      'strava_ordered': <String, Object?>{},
      'timetable': {
        '7.9.2026 (pondělí)': [
          {
            'subject': 'Matematika',
            'time': '1 (8:00 - 8:45)',
            'absenceType': 'NoAbsent',
            'absencetext': '',
          },
        ],
      },
    };
    File('${dir.path}/data_cache.json').writeAsStringSync(jsonEncode(cache));
    final state = AppState();
    expect(state.demoMode, isFalse);
    expect(state.timetable().containsKey('07.09.2026'), isTrue);
    expect(state.food().containsKey('07.09.2026'), isTrue);
  });

  test('reloadPrefersWebTruthButKeepsPending', () {
    final backing = {
      'strava_ordered': {
        '07.09.2026': 'web&1&0',
        '08.09.2026': 'web&2&0',
        '09.09.2026': 'web&1&0',
      },
    };
    File('${dir.path}/data_cache.json').writeAsStringSync(jsonEncode(backing));
    final state = AppState();
    state.orders
      ..clear()
      ..addAll({'07.09.2026': 'stale&9&0', '08.09.2026': 'mine&3&0'});
    state.pendingOrders
      ..clear()
      ..add('08.09.2026');
    state.cancelledLunches = {'09.09.2026'};
    state.reloadCache();
    expect(state.orders['07.09.2026'], 'web&1&0');
    expect(state.orders['08.09.2026'], 'mine&3&0');
    expect(state.orders.containsKey('09.09.2026'), isFalse);
    expect(state.webOrders['07.09.2026'], 'web&1&0');
  });

  test('orderLunchMarksPendingUntilCleared', () {
    final state = AppState(data: {});
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      expect(state.orderLunch('07.09.2026', 'x&1&0'), isTrue);
      expect(state.pendingOrders, {'07.09.2026'});
      state.cancelLunchOrder('07.09.2026');
      expect(state.pendingOrders, isEmpty);
    });
  });
}
