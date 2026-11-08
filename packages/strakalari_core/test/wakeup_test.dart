// Port of tests/test_wakeup_and_widget.py (pure cases).
//
// Deferred to their owners: TestTimetableViews/TestCollapsibleDays/
// TestWakeupUI (Flet views, phase 5/6), TestPhoneWiring/TestSettings (app
// wiring, phase 7/8), test_extension_wheel_* (tooling, phase 8) and the whole
// test_wake_ui.py (Flet's event-loop helper has no Flutter counterpart).
import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/planning/schedule.dart';
import 'package:strakalari_core/src/wakeup.dart';

const Map<String, Object?> on = {
  'wakeup_enabled': true,
  'wakeup_minutes_before': 60,
};
const Map<String, Object?> noHolidays = {
  'school_preset_id': 'custom',
  'user_free_days': [],
  'holidays': [],
};

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() {
    setLanguage('cs');
    wakeupPhoneBridge = null;
    resetWakeupSyncState();
  });

  group('wakeupAlarm', () {
    test('clampWakeupMinutes', () {
      expect(clampWakeupMinutes(null), 60);
      expect(clampWakeupMinutes('abc', 45), 45);
      expect(clampWakeupMinutes(0), 1);
      expect(clampWakeupMinutes(9999), 720);
      expect(clampWakeupMinutes('75,5'), 75);
    });

    test('disabledReturnsNothing', () {
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
        ],
      };
      const cfg = {'wakeup_enabled': false};
      expect(
        nextWakeupAlarm(tt, config: cfg, now: DateTime(2026, 10, 12, 6, 0)),
        isNull,
      );
      expect(
        upcomingWakeupAlarms(
          tt,
          config: cfg,
          now: DateTime(2026, 10, 12, 6, 0),
        ),
        isEmpty,
      );
    });

    test('firstLessonAlarm', () {
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika', 'room': '204'},
          {'time': '2 (8:55 - 9:40)', 'subject': 'Čeština'},
        ],
      };
      final alarm = nextWakeupAlarm(
        tt,
        config: {...on, 'wakeup_minutes_before': 45},
        now: DateTime(2026, 10, 12, 6, 30),
      )!;
      expect(
        [alarm.day, alarm.period, alarm.subject, alarm.room],
        [DateTime(2026, 10, 12), 1, 'Matematika', '204'],
      );
      expect(alarm.alarmDt, DateTime(2026, 10, 12, 7, 15));
      expect([alarm.alarmTimeLabel, alarm.lessonTimeLabel], ['07:15', '08:00']);
    });

    test('cancelledFirstLessonMovesTheAlarm', () {
      final tt = {
        '12.10.2026': [
          {
            'time': '1 (8:00 - 8:45)',
            'subject': 'Matematika',
            'status': 'cancelled',
          },
          {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika'},
        ],
      };
      final alarm = nextWakeupAlarm(
        tt,
        config: on,
        now: DateTime(2026, 10, 12, 6, 0),
      )!;
      expect([alarm.period, alarm.subject], [2, 'Fyzika']);
      expect(alarm.alarmDt, DateTime(2026, 10, 12, 7, 55));
    });

    test('pastAlarmMovesToTheNextSchoolDay', () {
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
        ],
        '13.10.2026': [
          {'time': '2 (8:55 - 9:40)', 'subject': 'Angličtina'},
        ],
      };
      final alarm = nextWakeupAlarm(
        tt,
        config: on,
        now: DateTime(2026, 10, 12, 7, 5),
      )!;
      expect(
        [alarm.day, alarm.alarmTimeLabel],
        [DateTime(2026, 10, 13), '07:55'],
      );
    });

    test('skipsFreeDaysSkippedDaysAndPlannedAbsences', () {
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Pondělí'},
        ],
        '13.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Úterý'},
        ],
        '14.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Středa 1'},
          {'time': '2 (8:55 - 9:40)', 'subject': 'Středa 2'},
        ],
      };
      final cfg = {
        ...on,
        'user_free_days': [
          {'date': '12.10.2026', 'label': 'Ředitelské volno'},
        ],
        'wakeup_skip_dates': ['2026-10-13'],
        'planned_skips': [
          {
            'start_date': '2026-10-14',
            'end_date': '2026-10-14',
            'start_period': 1,
            'end_period': 1,
          },
        ],
      };
      final alarm = nextWakeupAlarm(
        tt,
        config: cfg,
        now: DateTime(2026, 10, 12, 6, 0),
      )!;
      expect(
        [alarm.day, alarm.subject, alarm.alarmTimeLabel],
        [DateTime(2026, 10, 14), 'Středa 2', '07:55'],
      );
    });

    test('multiDayPlannedAbsenceFollowsThePlanner', () {
      final lesson = [
        {'time': '1 (8:00 - 8:45)', 'subject': 'M'},
        {'time': '2 (8:55 - 9:40)', 'subject': 'F'},
        {'time': '3 (10:00 - 10:45)', 'subject': 'C'},
      ];
      final tt = {
        for (final d in [12, 13, 14]) '$d.10.2026': lesson,
      };
      final cfg = {
        ...on,
        'planned_skips': [
          {
            'start_date': '2026-10-12',
            'end_date': '2026-10-14',
            'start_period': 2,
            'end_period': 1,
          },
        ],
      };
      final alarms = upcomingWakeupAlarms(
        tt,
        config: cfg,
        now: DateTime(2026, 10, 12, 6, 0),
        horizonDays: 2,
      );
      expect(
        [for (final a in alarms) (a.day.day, a.period)],
        [(12, 1), (14, 2)],
      );
    });

    test('stableTimetableCoversLaterWeeks', () {
      final tt = {
        '16.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Pátek'},
        ],
      };
      final baseline = {
        (0, 1): SlotBaseline(
          weekday: 0,
          period: 1,
          subject: 'Matematika',
          teacher: 'Novák',
          startMin: 480,
        ),
      };
      // Without any cached week the template's start time alone will do.
      final alarm = nextWakeupAlarm(
        {},
        config: on,
        now: DateTime(2026, 10, 16, 12, 0),
        stableBaseline: baseline,
      )!;
      expect(
        [alarm.day, alarm.alarmTimeLabel],
        [DateTime(2026, 10, 19), '07:00'],
      );
      // With one, the template day shows that period's full clock.
      final rows =
          (buildWidgetPayload(
                    tt,
                    config: {},
                    now: DateTime(2026, 10, 19, 6, 0),
                    stableBaseline: baseline,
                  )['days']
                  as List)[0]['rows']
              as List;
      expect(
        [rows[0]['time'], rows[0]['start'], rows[0]['end']],
        ['8:00 - 8:45', 480, 525],
      );
      final alarm2 = nextWakeupAlarm(
        tt,
        config: {...on, 'wakeup_minutes_before': 30},
        now: DateTime(2026, 10, 16, 12, 0),
        stableBaseline: baseline,
      )!;
      expect(
        [alarm2.day, alarm2.subject, alarm2.alarmTimeLabel],
        [DateTime(2026, 10, 19), 'Matematika', '07:30'],
      );
    });

    test('daysOffInALoadedWeekGetNoStableLessons', () {
      final lesson = [
        {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
      ];
      final tt = {'26.10.2026': lesson, '27.10.2026': lesson};
      final baseline = {
        for (var wd = 0; wd < 5; wd++)
          (wd, 1): SlotBaseline(
            weekday: wd,
            period: 1,
            subject: 'Stálá',
            teacher: 'Novák',
            startMin: 480,
          ),
      };
      final alarm = nextWakeupAlarm(
        tt,
        config: {...noHolidays, ...on},
        now: DateTime(2026, 10, 27, 12, 0),
        stableBaseline: baseline,
      )!;
      expect([alarm.day, alarm.subject], [DateTime(2026, 11, 2), 'Stálá']);
      final days = {
        for (final d
            in (buildWidgetPayload(
                  tt,
                  config: noHolidays,
                  now: DateTime(2026, 10, 28, 9, 0),
                  stableBaseline: baseline,
                  lang: 'cs',
                )['days']
                as List))
          d['iso'] as String: d as Map<String, Object?>,
      };
      expect(
        [
          for (final d in [26, 27, 28, 29, 30]) days['2026-10-$d']!['taught'],
        ],
        [1, 1, 0, 0, 0],
      );
      expect(days['2026-11-02']!['taught'], 1);
    });

    test('clockAppGetsAWeekdayOnlyBeyondADay', () {
      WakeupAlarm alarm(DateTime day) => WakeupAlarm(
        day: day,
        alarmDt: DateTime(day.year, day.month, day.day, 7),
        lessonStartDt: DateTime(2000, 1, 1),
        period: 1,
        subject: 'M',
        room: '',
        minutesBefore: 60,
      );
      final fridayEvening = DateTime(2026, 10, 30, 18, 0);
      expect(
        clockAppWeekday(alarm(DateTime(2026, 11, 2)), fridayEvening),
        0,
      ); // Monday
      expect(
        clockAppWeekday(alarm(DateTime(2026, 10, 31)), fridayEvening),
        isNull,
      );
      expect(
        clockAppWeekday(
          alarm(DateTime(2026, 10, 31)),
          DateTime(2026, 10, 30, 6, 59),
        ),
        5,
      );
    });

    test('queueSpansTwoWeeksForThePhone', () {
      final lessons = [
        {'time': '1 (8:00 - 8:45)', 'subject': 'M', 'room': 'U12'},
      ];
      String key(int i) {
        final d = DateTime(2026, 10, 12).add(Duration(days: i));
        String two(int n) => n.toString().padLeft(2, '0');
        return '${two(d.day)}.${two(d.month)}.${d.year}';
      }

      final tt = {
        for (var i = 0; i < 14; i++)
          if (DateTime(2026, 10, 12).add(Duration(days: i)).weekday < 6)
            key(i): lessons,
      };
      final alarms = upcomingWakeupAlarms(
        tt,
        config: on,
        now: DateTime(2026, 10, 12, 6, 0),
      );
      expect(alarms, hasLength(10));
      final queue = alarmQueue(alarms, lang: 'cs');
      final first = queue[0];
      expect(first['at'], DateTime(2026, 10, 12, 7, 0).millisecondsSinceEpoch);
      expect(
        first['lesson'],
        DateTime(2026, 10, 12, 8, 0).millisecondsSinceEpoch,
      );
      expect(first['title'], 'Budík · M v 08:00');
      expect(first['text'], '1. hodina · učebna U12');
      expect(
        alarmQueue(alarms.sublist(0, 1), lang: 'en')[0]['text'],
        'Period 1 · room U12',
      );
    });

    test('skipListKeepsOnlyUpcomingDays', () {
      const cfg = {
        'wakeup_skip_dates': ['2026-10-01', '2026-10-20', 'junk'],
      };
      expect(skippedDays(cfg), {DateTime(2026, 10, 1), DateTime(2026, 10, 20)});
      final today = DateTime(2026, 10, 12);
      expect(withSkippedDay(cfg, DateTime(2026, 10, 13), true, today), [
        '2026-10-13',
        '2026-10-20',
      ]);
      expect(
        withSkippedDay(cfg, DateTime(2026, 10, 20), false, today),
        isEmpty,
      );
    });

    test('skippedDaysDropOutOnceTheirAlarmHasPassed', () {
      final lesson = [
        {'time': '1 (8:00 - 8:45)', 'subject': 'M'},
      ];
      final tt = {'12.10.2026': lesson, '13.10.2026': lesson};
      final cfg = {
        ...on,
        'wakeup_skip_dates': [
          '2026-10-11',
          '2026-10-12',
          '2026-10-13',
          '2026-10-14',
        ],
      };
      List<(int, String?)> ahead(DateTime now) => [
        for (final (d, a) in upcomingSkippedDays(tt, config: cfg, now: now))
          (d.day, a?.alarmTimeLabel),
      ];
      // Wednesday has no lessons (its week is loaded): no alarm to show.
      expect(ahead(DateTime(2026, 10, 12, 6, 0)), [
        (12, '07:00'),
        (13, '07:00'),
        (14, null),
      ]);
      expect(ahead(DateTime(2026, 10, 12, 15, 0)), [(13, '07:00'), (14, null)]);
      // A day without an alarm keeps its button until it comes.
      expect(ahead(DateTime(2026, 10, 13, 23, 0)), [(14, null)]);
      expect(ahead(DateTime(2026, 10, 14, 0, 5)), isEmpty);
    });

    test('alarmReachingPastMidnightRingsTheDayBefore', () {
      final tt = {
        '13.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'M'},
        ],
      };
      final cfg = {...on, 'wakeup_minutes_before': 600};
      final alarm = nextWakeupAlarm(
        tt,
        config: cfg,
        now: DateTime(2026, 10, 12, 12, 0),
      )!;
      expect(
        [alarm.day, alarm.ringDay, alarm.alarmTimeLabel],
        [DateTime(2026, 10, 13), DateTime(2026, 10, 12), '22:00'],
      );
      expect(
        nextWakeupAlarm(tt, config: cfg, now: DateTime(2026, 10, 12, 22, 30)),
        isNull,
      );
      // Asked days ahead: a weekly Clock alarm on Monday, not on Tuesday.
      expect(clockAppWeekday(alarm, DateTime(2026, 10, 9, 12, 0)), 0);
      final skip = {
        ...cfg,
        'wakeup_skip_dates': ['2026-10-13'],
      };
      expect(
        [
          for (final (d, _) in upcomingSkippedDays(
            tt,
            config: skip,
            now: DateTime(2026, 10, 12, 21, 0),
          ))
            d,
        ],
        [DateTime(2026, 10, 13)],
      );
      expect(
        upcomingSkippedDays(
          tt,
          config: skip,
          now: DateTime(2026, 10, 12, 22, 30),
        ),
        isEmpty,
      );
    });
  });

  group('widgetPayload', () {
    test('dayRowsShowFreePeriodsAsEmptySlots', () {
      final lessons = [
        {
          'time': '2 (8:55 - 9:40)',
          'subject': 'Čeština',
          'room': '101',
          'teacher': 'Mgr. Jana Nováková',
        },
        {'time': '4 (10:55 - 11:40)', 'subject': 'Fyzika', 'room': 'F2'},
      ];
      final rows = buildWidgetDayRows(lessons, DateTime(2026, 10, 12));
      expect(
        [for (final r in rows) (r['period'], r['kind'])],
        [('1.', 'pause'), ('2.', 'lesson'), ('3.', 'pause'), ('4.', 'lesson')],
      );
      expect(rows[1]['meta'], '101 · Nováková');
      expect([rows[1]['start'], rows[1]['end']], [535, 580]);
      expect(rows[0]['subject'], isEmpty);
      expect(rows[0]['start'], -1);
    });

    test('payloadHasDatesAndClockTimesNotToday', () {
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
        ],
        '13.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Čeština'},
          {
            'time': '3 (10:00 - 10:45)',
            'subject': 'Dějepis',
            'status': 'cancelled',
          },
        ],
        '14.10.2026': [
          {'time': '3 (10:00 - 10:45)', 'subject': 'Biologie'},
        ],
      };
      final cfg = {
        'user_free_days': [
          {'date': '12.10.2026', 'label': 'Ředitelské volno'},
        ],
      };
      final payload = buildWidgetPayload(
        tt,
        config: cfg,
        now: DateTime(2026, 10, 13, 6, 30),
        lang: 'cs',
      );
      expect([payload['today'], payload['tomorrow']], ['Dnes', 'Zítra']);
      final days = {
        for (final d in payload['days'] as List)
          (d as Map)['iso'] as String: d as Map<String, Object?>,
      };
      final monday = days['2026-10-12']!;
      final tuesday = days['2026-10-13']!;
      expect(monday['label'], 'Pondělí 12. 10.');
      expect(monday['free'], isTrue);
      expect(monday['subtitle'], 'Ředitelské volno');
      expect(tuesday['taught'], 1);
      expect(tuesday['subtitle'], '1 hodina');
      expect(tuesday['end'], 8 * 60 + 45); // the cancelled lesson is out
      final rows = tuesday['rows'] as List;
      expect([for (final r in rows) r['kind']], ['lesson', 'pause', 'lesson']);
      // The pause takes the usual clock of its period from the other days.
      expect(rows[2]['status'], 'cancelled');
      expect(rows[2]['badge'], 'Odpadá');
      // A free period takes its number's usual clock from the other days.
      final wednesday = days['2026-10-14']!['rows'] as List;
      expect(
        [for (final r in wednesday) (r['kind'], r['time'])],
        [('pause', '8:00 - 8:45'), ('pause', ''), ('lesson', '10:00 - 10:45')],
      );
      // Weekends without lessons are left out; three weeks from Monday.
      expect(days, isNot(contains('2026-10-17')));
      expect(days, contains('2026-10-30'));
      expect(jsonEncode(payload), isNot(contains('focus')));
      expect(payload, isNot(contains('default_index')));
    });

    test('presetHolidayNameIsTheSubtitle', () {
      final cfg = {
        'user_free_days': [
          {'date': '29.10.2026', 'label': 'Podzimní prázdniny'},
        ],
      };
      final payload = buildWidgetPayload(
        {'29.10.2026': []},
        config: cfg,
        now: DateTime(2026, 10, 28),
        lang: 'cs',
      );
      final day = (payload['days'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((d) => d['iso'] == '2026-10-29');
      expect(day['subtitle'], 'Podzimní prázdniny');
    });

    test('emptyTextSaysWhenThereIsNoData', () {
      expect(
        buildWidgetPayload({}, config: {}, lang: 'en')['empty'],
        'No data yet — open Strakaláři',
      );
      expect(
        buildWidgetPayload({'12.10.2026': []}, config: {}, lang: 'en')['empty'],
        'No lessons',
      );
    });
  });

  group('syncAndroid', () {
    test('sendsOnlyChanges', () {
      final calls = <(String, Object?, String, String)>[];
      wakeupPhoneBridge = _FakeBridge(calls);
      final tt = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
        ],
      };
      final now = DateTime(2026, 10, 12, 6, 0);

      syncAndroid(tt, config: on, now: now);
      expect([for (final c in calls) c.$1], ['widget', 'alarms']);
      final queue = calls[1].$2 as List;
      expect((queue[0] as Map)['title'].toString().endsWith('08:00'), isTrue);
      expect(calls[1].$3, isNotEmpty);
      expect(calls[1].$4, isNotEmpty);

      calls.clear();
      syncAndroid(tt, config: on, now: now);
      expect(calls, isEmpty); // nothing changed

      syncAndroid(tt, config: {'wakeup_enabled': false}, now: now);
      expect(calls, hasLength(1));
      expect(calls[0].$1, 'alarms');
      expect(calls[0].$2, isEmpty); // the queue is cleared
    });

    test('widgetGoesAgainOnANewDay', () {
      final sent = <String>[];
      wakeupPhoneBridge = _WidgetBridge(sent);
      final tt = {
        '14.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
        ],
      };

      syncAndroid(tt, config: {}, now: DateTime(2026, 10, 14, 20, 0));
      syncAndroid(tt, config: {}, now: DateTime(2026, 10, 14, 23, 0));
      expect(sent, hasLength(1));
      // Same week, same data — handed over once more after midnight.
      syncAndroid(tt, config: {}, now: DateTime(2026, 10, 15, 0, 5));
      expect(sent, hasLength(2));
      expect(sent[0], sent[1]);
    });

    test('noOpOffAndroid', () {
      wakeupPhoneBridge = _NeverBridge();
      expect(() => syncAndroid({}, config: on), returnsNormally);
    });
  });
}

class _FakeBridge implements WakeupPhoneBridge {
  final List<(String, Object?, String, String)> calls;
  _FakeBridge(this.calls);

  @override
  bool updateTimetableWidget(String json) {
    calls.add(('widget', jsonDecode(json), '', ''));
    return true;
  }

  @override
  bool setWakeupAlarms(String queueJson, String channel, String dismiss) {
    calls.add(('alarms', jsonDecode(queueJson), channel, dismiss));
    return true;
  }
}

class _WidgetBridge implements WakeupPhoneBridge {
  final List<String> sent;
  _WidgetBridge(this.sent);

  @override
  bool updateTimetableWidget(String json) {
    sent.add(json);
    return true;
  }

  @override
  bool setWakeupAlarms(String queueJson, String channel, String dismiss) =>
      true;
}

class _NeverBridge implements WakeupPhoneBridge {
  @override
  bool updateTimetableWidget(String json) =>
      throw AssertionError('must not reach the phone bridge');

  @override
  bool setWakeupAlarms(String queueJson, String channel, String dismiss) =>
      throw AssertionError('must not reach the phone bridge');
}
