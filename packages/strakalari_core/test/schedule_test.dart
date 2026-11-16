import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/schedule.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

/// Two identical weeks (Mon 07.09 + Mon 14.09.2026) with optional patch.
///
/// Patch entries are (week, index, patch). Two disagreeing weeks form a
/// 1:1 tie with NO baseline — only explicit substitution/cancellation
/// notices count as changes there. Use [_threeWeeks] for majority diffs.
Map<String, List<Map<String, Object?>>> _twoWeeks(
    {List<(int, int, Map<String, String>)> patch = const []}) {
  List<Map<String, Object?>> fresh() => [
        <String, Object?>{
          'subject': 'M',
          'teacher': 'Novák',
          'room': 'U12',
          'time': '1 (8:00 - 8:45)',
        },
        <String, Object?>{
          'subject': 'F',
          'teacher': 'Dvořák',
          'room': 'F11',
          'time': '2 (8:55 - 9:40)',
        },
      ];
  final week1 = fresh();
  final week2 = fresh();
  for (final (day, idx, p) in patch) {
    (day == 0 ? week1 : week2)[idx].addAll(p);
  }
  return {'07.09.2026': week1, '14.09.2026': week2};
}

/// Three weeks (Mon 31.08 + 07.09 + 14.09.2026); two agree -> majority.
Map<String, List<Map<String, Object?>>> _threeWeeks(
    {List<(int, int, Map<String, String>)> patch = const []}) {
  List<Map<String, Object?>> fresh() => [
        <String, Object?>{
          'subject': 'M',
          'teacher': 'Novák',
          'room': 'U12',
          'time': '1 (8:00 - 8:45)',
        },
        <String, Object?>{
          'subject': 'F',
          'teacher': 'Dvořák',
          'room': 'F11',
          'time': '2 (8:55 - 9:40)',
        },
      ];
  final weeks = [fresh(), fresh(), fresh()];
  for (final (day, idx, p) in patch) {
    weeks[day][idx].addAll(p);
  }
  return {
    '31.08.2026': weeks[0],
    '07.09.2026': weeks[1],
    '14.09.2026': weeks[2],
  };
}

/// Baseline as the scraped "Stálý" view would give it: one clean week.
Map<(int, int), Object> _stableOf(
        Map<String, List<Map<String, Object?>>> tt, String dayKey) =>
    baselineFromStableTimetable({dayKey: tt[dayKey]!});

/// Stable view with a split-group slot: two lessons, one period.
Map<String, List<Map<String, Object?>>> _splitStable() => {
      '07.09.2026': [
        <String, Object?>{
          'subject': 'M',
          'teacher': 'Novák',
          'room': 'U12',
          'time': '1 (8:00 - 8:45)',
        },
        <String, Object?>{
          'subject': 'AJ',
          'teacher': 'Bílá',
          'room': 'J1',
          'time': '2 (8:55 - 9:40)',
          'group': 'sk. 1',
        },
        <String, Object?>{
          'subject': 'NJ',
          'teacher': 'Černý',
          'room': 'J2',
          'time': '2 (8:55 - 9:40)',
          'group': 'sk. 2',
        },
      ],
    };

void main() {
  group('parseTimeRange', () {
    test('parsesFormats', () {
      expect(parseTimeRange('3 (10:05 - 10:50)'), (10, 5, 10, 50));
      expect(parseTimeRange('1. 8:00 - 8:45'), (8, 0, 8, 45));
      expect(parseTimeRange('8:00 - 8:45'), (8, 0, 8, 45));
      expect(parseTimeRange('nonsense'), isNull);
      expect(parseTimeRange(''), isNull);
    });
  });

  group('changeVsNote', () {
    test('descriptionOnlyIsNoteNotChange', () {
      final tt = _twoWeeks(
          patch: const [(1, 1, {'notice': 'Písemka z minulé látky'})]);
      final baseline = baselineFromStableTimetable(tt);
      final diff = classifyLesson(
          tt['14.09.2026']![1], '14.09.2026', baseline);
      expect(diff.isChange, isFalse);
      expect(diff.note, 'Písemka z minulé látky');
      expect(iterChanges(tt, baseline), isEmpty);
      expect(iterNotes(tt, baseline), hasLength(1));
    });

    test('substituteTeacherIsChange', () {
      // 1:1 tie -> no baseline; the explicit substitution notice still counts.
      final tt = _twoWeeks(
          patch: const [
            (1, 1, {'teacher': 'Král', 'notice': 'Suplování (Král)'})
          ]);
      final changes = iterChanges(tt);
      expect(changes, hasLength(1));
      expect(changes[0]['day_key'], '14.09.2026');
      // The note is still preserved on the change.
      expect((changes[0]['diff'] as LessonDiff).note, 'Suplování (Král)');
    });

    test('stableBaselineGivesFieldDiffs', () {
      final tt = _threeWeeks(
          patch: const [
            (2, 1, {'teacher': 'Král', 'notice': 'Suplování'})
          ]);
      final baseline = _stableOf(tt, '31.08.2026');
      expect((baseline[(0, 2)] as SlotBaseline).teacher, 'Dvořák');
      final changes = iterChanges(tt, baseline);
      expect(changes, hasLength(1));
      expect(changes[0]['day_key'], '14.09.2026');
      expect((changes[0]['diff'] as LessonDiff).changed, contains('teacher'));
    });

    test('roomMoveAndCancelledAreChanges', () {
      final tt = _threeWeeks(
          patch: const [
            (2, 0, {'room': 'U99'})
          ]);
      final baseline = _stableOf(tt, '31.08.2026');
      final changes = iterChanges(tt, baseline);
      expect(changes, hasLength(1));
      expect((changes[0]['diff'] as LessonDiff).changed, contains('room'));

      final diff = classifyLesson(
          <String, Object?>{
            'subject': 'M',
            'teacher': 'Novák',
            'room': 'U12',
            'time': '1 (8:00 - 8:45)',
            'status': 'cancelled',
          },
          '07.09.2026',
          baseline);
      expect(diff.isChange, isTrue);
    });

    test('absentStatusIsNotAScheduleChange', () {
      final tt = _twoWeeks();
      final baseline = baselineFromStableTimetable(tt);
      final diff = classifyLesson(
          <String, Object?>{
            'subject': 'M',
            'teacher': 'Novák',
            'room': 'U12',
            'time': '1 (8:00 - 8:45)',
            'status': 'absent',
          },
          '07.09.2026',
          baseline);
      expect(diff.isChange, isFalse);
    });

    test('withoutBaselineKeywordsDecide', () {
      // No stable view: the annotated lesson counts via its substitution
      // keyword, the plain one stays quiet — nothing is learned from weeks.
      final tt = <String, List<Map<String, Object?>>>{
        '08.09.2026': [
          <String, Object?>{
            'subject': 'F',
            'teacher': 'Dvořák',
            'room': 'F11',
            'time': '2 (8:55 - 9:40)',
          },
        ],
        '15.09.2026': [
          <String, Object?>{
            'subject': 'F',
            'teacher': 'Král',
            'room': 'F11',
            'time': '2 (8:55 - 9:40)',
            'notice': 'Suplování (Král)',
          },
        ],
      };
      final changes = iterChanges(tt);
      expect(changes, hasLength(1));
      expect(changes[0]['day_key'], '15.09.2026');
    });

    test('tieWithoutKeywordsIsQuiet', () {
      // A silent difference with no majority is NOT a change — with only
      // two disagreeing weeks nobody can tell which side is stable (e.g.
      // homeroom periods in the first school week).
      final tt = <String, List<Map<String, Object?>>>{
        '08.09.2026': [
          <String, Object?>{
            'subject': 'Třídnická hodina',
            'teacher': 'Picka',
            'room': 'VIII',
            'time': '1 (8:00 - 8:45)',
          },
        ],
        '15.09.2026': [
          <String, Object?>{
            'subject': 'M',
            'teacher': 'Novák',
            'room': 'U12',
            'time': '1 (8:00 - 8:45)',
            'notice': 'Povolená absence 30%',
          },
        ],
      };
      expect(iterChanges(tt), isEmpty);
      expect(iterNotes(tt), hasLength(1));
    });
  });

  group('lessonClock', () {
    test('resolveDayLessonsPhases', () {
      final day = <Map<String, Object?>>[
        <String, Object?>{'subject': 'M', 'time': '1. 8:00 - 8:45'},
        <String, Object?>{'subject': 'F', 'time': '2. 8:55 - 9:40'},
      ];
      expect(resolveDayLessons(day, DateTime(2026, 9, 8, 7, 30))['phase'],
          'before');
      final running = resolveDayLessons(day, DateTime(2026, 9, 8, 8, 10));
      expect(running['phase'], 'running');
      expect((running['current'] as Map)['subject'], 'M');
      final between = resolveDayLessons(day, DateTime(2026, 9, 8, 8, 50));
      expect(between['phase'], 'between');
      expect((between['upcoming'] as Map)['subject'], 'F');
      expect(resolveDayLessons(day, DateTime(2026, 9, 8, 20, 0))['phase'],
          'done');
      expect(
          resolveDayLessons([], DateTime(2026, 9, 8, 8, 0))['phase'], 'empty');
    });

    test('futureLessonsDropsStarted', () {
      final day = <Map<String, Object?>>[
        <String, Object?>{'subject': 'M', 'time': '1. 8:00 - 8:45'},
        <String, Object?>{'subject': 'F', 'time': '2. 8:55 - 9:40'},
        <String, Object?>{'subject': 'X'}, // no clock -> kept
      ];
      var future = futureLessons(day, DateTime(2026, 9, 8, 8, 50));
      expect([for (final l in future) l['subject']], ['F', 'X']);
      // During/after F only the clock-less row is still "plannable".
      future = futureLessons(day, DateTime(2026, 9, 8, 9, 0));
      expect([for (final l in future) l['subject']], ['X']);
    });
  });

  group('baseline', () {
    test('stableWeeklyHoursCountsBaselineSlots', () {
      final tt = _threeWeeks();
      final baseline = baselineFromStableTimetable(tt);
      expect(stableWeeklyHours(baseline), {'M': 1, 'F': 1});
      expect(stableWeeklyHours({}), isEmpty);
      expect(stableWeeklyHours(null), isEmpty);
    });

    test('baselineSerializationRoundtrip', () {
      final tt = _threeWeeks();
      final baseline = baselineFromStableTimetable(tt);
      final data = baselineToDict(baseline);
      expect(data.keys.toSet(), {'0|1', '0|2'});
      final restored = baselineFromDict(data);
      expect(stableWeeklyHours(restored), {'M': 1, 'F': 1});
      expect((restored[(0, 2)] as SlotBaseline).teacher, 'Dvořák');
      // Corrupt input never raises.
      expect(baselineFromDict(null), isEmpty);
      expect(
          baselineFromDict({
            'bogus': {'subject': 'X'}
          }),
          isEmpty);
    });

    test('stableHoursIgnoreClocklessExtraRow', () {
      // Raw weeks contain a one-off extra Physics (substitution week) that
      // must not double its weekly hours in the forecast. The extra row has
      // no period clock, so the baseline ignores it while raw counting sees
      // it. (The forecast_all half of this case lands with forecast.dart.)
      Map<String, List<Map<String, Object?>>> week(String extra) => {
            '31.08.2026': [
              <String, Object?>{'subject': 'M', 'time': '1 (8:00 - 8:45)'},
              <String, Object?>{'subject': 'F', 'time': '2 (8:55 - 9:40)'},
            ],
            '07.09.2026': [
              <String, Object?>{'subject': 'M', 'time': '1 (8:00 - 8:45)'},
              <String, Object?>{'subject': 'F', 'time': '2 (8:55 - 9:40)'},
            ],
            '14.09.2026': [
              <String, Object?>{'subject': 'M', 'time': '1 (8:00 - 8:45)'},
              <String, Object?>{'subject': 'F', 'time': '2 (8:55 - 9:40)'},
              if (extra.isNotEmpty)
                <String, Object?>{'subject': extra},
            ],
          };
      final baseline = baselineFromStableTimetable(week('F'));
      expect(stableWeeklyHours(baseline), {'M': 1, 'F': 1});
    });

    test('baselineFromStableTimetableDateAndNameKeys', () {
      final stable = <String, List<Map<String, Object?>>>{
        // Scraped stable view may label days with dates ...
        '07.09.2026': [
          <String, Object?>{
            'subject': 'M',
            'teacher': 'Novák',
            'room': 'U12',
            'time': '1 (8:00 - 8:45)',
          },
        ],
        // ... or with weekday names.
        'Úterý': [
          <String, Object?>{
            'subject': 'F',
            'teacher': 'Dvořák',
            'room': 'F11',
            'time': '2 (8:55 - 9:40)',
          },
        ],
        'nonsense': [
          <String, Object?>{'subject': 'X', 'time': '1 (8:00 - 8:45)'},
        ],
      };
      final baseline = baselineFromStableTimetable(stable);
      expect(baseline.keys.toSet(), {(0, 1), (1, 2)});
      expect((baseline[(0, 1)] as SlotBaseline).subject, 'M');
      expect((baseline[(1, 2)] as SlotBaseline).teacher, 'Dvořák');
      expect(baselineFromStableTimetable({}), isEmpty);
    });

    test('splitSlotKeepsEveryVariant', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      // Single stays unwrapped ...
      expect((baseline[(0, 1)] as SlotBaseline).subject, 'M');
      final variants = baseline[(0, 2)];
      expect(variants, isA<List<SlotBaseline>>());
      expect((variants as List<SlotBaseline>), hasLength(2));
      expect({for (final v in variants) v.subject}, {'AJ', 'NJ'});
    });

    test('splitSlotGroupLessonsAreNotChanges', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      for (final (subject, teacher) in [('AJ', 'Bílá'), ('NJ', 'Černý')]) {
        final diff = classifyLesson(
            <String, Object?>{
              'subject': subject,
              'teacher': teacher,
              'room': subject == 'AJ' ? 'J1' : 'J2',
              'time': '2 (8:55 - 9:40)',
            },
            '07.09.2026',
            baseline);
        expect(diff.isChange, isFalse);
      }
      // A stranger in the same slot IS a change, diffed vs closest variant.
      final diff = classifyLesson(
          <String, Object?>{
            'subject': 'AJ',
            'teacher': 'Král',
            'room': 'J1',
            'time': '2 (8:55 - 9:40)',
            'notice': 'Suplování',
          },
          '07.09.2026',
          baseline);
      expect(diff.isChange, isTrue);
      expect(diff.changed, ['teacher']);
      expect(
          iterChanges(
              <String, List<Map<String, Object?>>>{
                '07.09.2026': [
                  <String, Object?>{
                    'subject': 'AJ',
                    'teacher': 'Bílá',
                    'room': 'J1',
                    'time': '2 (8:55 - 9:40)',
                  },
                  <String, Object?>{
                    'subject': 'NJ',
                    'teacher': 'Černý',
                    'room': 'J2',
                    'time': '2 (8:55 - 9:40)',
                  },
                ],
              },
              baseline),
          isEmpty);
    });

    test('splitSlotHoursCountDistinctSubjects', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      expect(stableWeeklyHours(baseline), {'M': 1, 'AJ': 1, 'NJ': 1});
      // Same subject in both halves (split class, one teacher each) counts once.
      final sameSubject = baselineFromStableTimetable(
          <String, List<Map<String, Object?>>>{
            '07.09.2026': [
              <String, Object?>{
                'subject': 'TV',
                'teacher': 'Malý',
                'room': 'T1',
                'time': '3 (10:00 - 10:45)',
              },
              <String, Object?>{
                'subject': 'TV',
                'teacher': 'Velká',
                'room': 'T2',
                'time': '3 (10:00 - 10:45)',
              },
            ],
          });
      expect(stableWeeklyHours(sameSubject), {'TV': 1});
    });

    test('variantSerializationRoundtripAndClosest', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      final data = baselineToDict(baseline);
      expect(data['0|2'], isA<List<Object?>>());
      expect((data['0|2'] as List), hasLength(2));
      expect(data['0|1'], isA<Map<Object?, Object?>>());
      final restored = baselineFromDict(data);
      expect(
          {for (final v in restored[(0, 2)] as List<SlotBaseline>) v.subject},
          {'AJ', 'NJ'});
      final nearest = closestVariant(
          restored[(0, 2)],
          <String, Object?>{
            'subject': 'NJ',
            'teacher': 'Černý',
            'room': 'J2',
            'time': '2 (8:55 - 9:40)',
          },
          '07.09.2026');
      expect(nearest, isNotNull);
      expect(nearest!.subject, 'NJ');
      expect(closestVariant(null, {}, '07.09.2026'), isNull);
    });

    test('stableTemplateWeekRendersSlots', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      // Any date in the week works as anchor — output starts on Monday.
      final week = stableTemplateWeek(baseline, DateTime(2026, 9, 9));
      expect(week.keys.toList(), [DateTime(2026, 9, 7)]);
      final lessons = week[DateTime(2026, 9, 7)]!;
      expect(
          [for (final r in lessons) extractLessonNum(r['time'])], [1, 2, 2]);
      expect(lessons[0]['subject'], 'M');
      expect(lessons[0]['teacher'], 'Novák');
      expect(lessons[0]['time'] as String, contains('8:00'));
      expect({for (final r in lessons.skip(1)) r['subject']}, {'AJ', 'NJ'});
      expect(stableTemplateWeek(null), isEmpty);
      expect(
          stableTemplateWeek({
            (9, 1): null
          }),
          isEmpty);
    });

    test('stableTemplateWeekDefaultsToCurrentWeek', () {
      final baseline = baselineFromStableTimetable(_splitStable());
      final week = withClock(Clock.fixed(DateTime(2026, 9, 9, 12, 0)), () {
        return stableTemplateWeek(baseline);
      });
      expect(week.keys.toList(), [DateTime(2026, 9, 7)]);
    });
  });

  group('periodOf', () {
    test('periodOfZero', () {
      expect(periodOf({'subject': 'M', 'period': 0}, null), 0);
      expect(periodOf({'subject': 'M', 'period': 1}, null), 1);
      expect(periodOf({'subject': 'M'}, null), isNull);
    });

    test('periodZeroSortsFirstNotLast', () {
      const periods = [10, 0, 1, 5];
      final raws = [
        for (final p in periods) <String, Object?>{'subject': 'M', 'period': p}
      ];
      raws.sort((a, b) =>
          (periodOf(a) ?? 999).compareTo(periodOf(b) ?? 999));
      expect([for (final r in raws) r['period']], [0, 1, 5, 10]);
    });
  });

  group('negationGuard', () {
    test('negatedNoticeIsNoChangeWithoutBaseline', () {
      final raw = <String, Object?>{
        'subject': 'M',
        'teacher': 'T',
        'time': '1 (8:00 - 8:45)',
        'notice': 'Neodpadá - beze změny',
      };
      expect(
          classifyLesson(raw, '07.09.2026', null).isChange, isFalse);
    });

    test('plainCancelNoticeIsChangeWithoutBaseline', () {
      final raw = <String, Object?>{
        'subject': 'M',
        'teacher': 'T',
        'time': '1 (8:00 - 8:45)',
        'notice': 'Odpadá',
      };
      expect(classifyLesson(raw, '07.09.2026', null).isChange, isTrue);
    });

    test('realSubstitutionStillDetected', () {
      final raw = <String, Object?>{
        'subject': 'M',
        'teacher': 'T',
        'time': '1 (8:00 - 8:45)',
        'notice': 'Suplování (Král)',
      };
      expect(classifyLesson(raw, '07.09.2026', null).isChange, isTrue);
    });
  });

  group('substitutionFeed', () {
    test('feedDoesNotCreateDays', () {
      final timetable = <String, List<Map<String, Object?>>>{
        '22.09.2026': [
          <String, Object?>{
            'subject': 'M',
            'teacher': 'X',
            'time': '1 (8:00 - 8:45)',
          },
        ],
      };
      final feed = <Map<String, Object?>>[
        <String, Object?>{
          'day': '1.10.2026',
          'period': 3,
          'badge': 'O',
          'time': '10:00 - 10:45',
          'subject_short': 'Ch',
          'description': 'Odpadá',
        },
      ];
      expect(applySubstitutionFeed(timetable, feed), 0);
      expect(timetable.keys.toList(), ['22.09.2026']);
    });
  });

  group('identicalRoomChangeSuppressed', () {
    test('roomChangedWithSameOldAndNewRoomIsNotAChangeOrNote', () {
      final baseline = <Object?, Object?>{
        (4, 5): SlotBaseline(
          weekday: 4,
          period: 5,
          subject: 'Český jazyk',
          teacher: 'Mgr. Petr Dvořák',
          room: 'I',
          startMin: 710,
        ),
      };
      final sameRoom = <String, Object?>{
        'subject': 'Český jazyk',
        'teacher': 'Mgr. Petr Dvořák',
        'room': 'I',
        'time': '5 (11:50 - 12:35)',
        'period': 5,
        'infoChangeCode': 'RoomChanged',
        'changeinfo': 'Změna místnosti: I (I)',
        'notice': 'Změna místnosti: I (I)',
      };
      final diffWithBase = classifyLesson(sameRoom, '18.09.2026', baseline);
      expect(diffWithBase.isChange, isFalse);
      expect(diffWithBase.note, isEmpty);

      final diffNoBase = classifyLesson(sameRoom, '18.09.2026', null);
      expect(diffNoBase.isChange, isFalse);
      expect(diffNoBase.note, isEmpty);

      final realMove = <String, Object?>{
        ...sameRoom,
        'room': 'III',
        'changeinfo': 'Změna místnosti: III (I)',
        'notice': 'Změna místnosti: III (I)',
      };
      final diffReal = classifyLesson(realMove, '18.09.2026', baseline);
      expect(diffReal.isChange, isTrue);
      expect(diffReal.changed, contains('room'));
    });
  });
}
