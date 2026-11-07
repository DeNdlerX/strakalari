import 'package:test/test.dart';

import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

void main() {
  group('periodParsing', () {
    test('periodDerivedFromTimeString', () {
      final lesson = Lesson.fromLegacy({
        'subject': 'M',
        'teacher': 'T',
        'time': '3 (10:05 - 10:50)',
      });
      expect(lesson.period, 3);
    });

    test('sameSubjectKeysAreUniquePerPeriod', () {
      final timetable = {
        '07.09.2026': [
          {
            'subject': 'Matematika',
            'teacher': 'T',
            'time': '1 (8:00-8:45)',
            'absenceType': 'Absent',
            'absencetext': 'Absence',
          },
          {
            'subject': 'Matematika',
            'teacher': 'T',
            'time': '2 (8:55-9:40)',
            'absenceType': 'Absent',
            'absencetext': 'Absence',
          },
        ]
      };
      final tasks = excuseTasksFromLessons(lessonsFromTimetable(timetable));
      expect(tasks, hasLength(2));
      expect(tasks[0].key, isNot(tasks[1].key));
    });
  });

  Map<String, Object?> absentLesson(
          {String time = '1 (8:00-8:45)',
          String absType = 'Absent',
          String absText = 'Absence'}) =>
      {
        'teacher': 'T',
        'subject': 'M',
        'time': time,
        'absenceType': absType,
        'absencetext': absText,
        'notice': '',
      };

  group('excusedMarker', () {
    test('negationsAreNotExcused', () {
      expect(isExcusedMarker('Absent Neomluveno'), isFalse);
      expect(isExcusedMarker('Absent Neomluvená'), isFalse);
      expect(isExcusedMarker('Unexcused Absence'), isFalse);
      expect(isExcusedMarker(''), isFalse);
    });

    test('positiveMarkersStillMatch', () {
      expect(isExcusedMarker('Omluveno'), isTrue);
      expect(isExcusedMarker('Excused'), isTrue);
      expect(isExcusedMarker('Omluvená absence'), isTrue);
    });

    test('neomluvenoLessonIsAbsent', () {
      final lesson = Lesson.fromLegacy(absentLesson(absText: 'Neomluveno'));
      expect(lesson.status, 'absent');
      expect(lesson.excused, isFalse);
    });

    test('unexcusedTypeIsAbsent', () {
      final lesson = Lesson.fromLegacy(absentLesson(absType: 'Unexcused'));
      expect(lesson.status, 'absent');
      expect(lesson.excused, isFalse);
    });

    test('omluvenoStaysExcused', () {
      final lesson = Lesson.fromLegacy(
          absentLesson(absType: 'Excused', absText: 'Omluveno'));
      expect(lesson.status, 'excused');
      expect(lesson.excused, isTrue);
    });
  });

  test('noabsentTextIsPresent', () {
    (String, String, bool) status(Map<String, Object?> raw) =>
        lessonStatusFromLegacy(raw);
    expect(status({'absencetext': 'NoAbsent'}).$1, isNot('absent'));
    expect(status({'absencetext': 'no absence'}).$1, isNot('absent'));
    expect(status({'absencetext': 'Neomluveno'}).$1, 'absent');
    expect(status({'absencetext': 'Unexcused'}).$1, 'absent');
    expect(status({'absenceType': 'NoAbsent'}).$1, isNot('absent'));
    expect(status({'absenceType': 'Absent'}).$1, 'absent');
  });

  test('lessonKeepsPeriodZero', () {
    expect(Lesson.fromLegacy({'subject': 'M', 'period': 0}).period, 0);
  });

  test('excuseTaskLabelKeepsPeriodZero', () {
    final tasks = excuseTasksFromLessons(
        [Lesson(subject: 'M', period: 0, status: 'absent')]);
    expect(tasks, isNotEmpty);
    expect(tasks[0].label, contains('0. hodina'));
  });

  group('cancelNegation', () {
    String statusOf(Map<String, Object?> raw) =>
        lessonStatusFromLegacy(raw).$1;

    test('plainCancelStillCancelled', () {
      expect(statusOf({'notice': 'Odpadá'}), 'cancelled');
      expect(statusOf({'notice': 'Zrušeno'}), 'cancelled');
      expect(
          statusOf({
            'type': 'removed',
            'removedinfo': 'Zrušeno (FG, Novák)',
          }),
          'cancelled');
    });

    test('negatedNoticeIsNotCancelled', () {
      expect(statusOf({'notice': 'Neodpadá - beze změny'}), isNot('cancelled'));
      expect(statusOf({'notice': 'Nezrušeno'}), isNot('cancelled'));
      expect(statusOf({'notice': 'Hodina beze změny'}), isNot('cancelled'));
    });

    test('authoritativeRemovedRowWinsOverNotice', () {
      // Bakalari's own verdict (type=removed) is a real cancellation
      // even if the notice text looks negated.
      expect(
          statusOf({
            'type': 'removed',
            'removedinfo': 'Zrušeno (FG, Novák)',
            'notice': 'Neodpadá',
          }),
          'cancelled');
    });
  });

  test('earlyTaskKindIsEarly', () {
    final lessons = [
      Lesson(subject: 'M', status: 'early', excused: false),
      Lesson(subject: 'F', status: 'absentearly', excused: false),
      Lesson(subject: 'C', status: 'late', excused: false),
      Lesson(subject: 'A', status: 'absent', excused: false),
    ];
    final tasks = excuseTasksFromLessons(lessons);
    expect(tasks.map((t) => t.kind).toList()..sort(),
        ['early', 'early', 'late', 'short']);
  });

  test('parseCzDate', () {
    expect(parseCzDate('25.12.2026'), DateTime(2026, 12, 25));
    expect(parseCzDate('2026-12-25'), DateTime(2026, 12, 25));
    expect(parseCzDate('nonsense'), isNull);
    expect(parseCzDate(''), isNull);
  });

  test('parseCzDateAcceptsCzechSlashes', () {
    expect(parseCzDate('07/09/2026'), DateTime(2026, 9, 7));
  });

  test('lessonsFromTimetable', () {
    final raw = {
      '25.12.2026': [
        {
          'subject': 'Matematika',
          'time': '1. 8:00 - 8:45',
          'room': 'U12',
          'status': 'absent',
        }
      ]
    };
    final lessons = lessonsFromTimetable(raw);
    expect(lessons, hasLength(1));
    expect(lessons[0].subject, 'Matematika');
    expect(lessons[0].day, DateTime(2026, 12, 25));
  });

  test('excuseTasksOnlyUnexcused', () {
    final lessons = [
      Lesson(subject: 'M', status: 'absent', excused: false),
      Lesson(subject: 'F', status: 'absent', excused: true),
      Lesson(subject: 'C', status: 'present', excused: false),
      Lesson(subject: 'A', status: 'late', excused: false),
    ];
    final tasks = excuseTasksFromLessons(lessons);
    expect(tasks, hasLength(2));
    expect(tasks.every((t) => t.label.isNotEmpty), isTrue);
    final kinds = tasks.map((t) => t.kind).toList()..sort();
    expect(kinds, ['late', 'short']);
  });
}
