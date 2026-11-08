import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/wakeup.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

WakeupAlarm alarmOf(Map<String, Object?> m) => WakeupAlarm(
      day: m['day'] as DateTime,
      alarmDt: m['alarmDt'] as DateTime,
      lessonStartDt: m['lessonStartDt'] as DateTime,
      period: m['period'] as int?,
      subject: m['subject'] as String? ?? '',
      room: m['room'] as String? ?? '',
      minutesBefore: (m['minutesBefore'] as num?)?.toInt() ?? 0,
    );

Map<String, Object?> alarmJson(WakeupAlarm a) => {
      'day': a.day,
      'alarmDt': a.alarmDt,
      'lessonStartDt': a.lessonStartDt,
      'period': a.period,
      'subject': a.subject,
      'room': a.room,
      'minutesBefore': a.minutesBefore,
    };

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));
  test('parityWithPython', () {
    for (final c in loadParityCases('wakeup')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'clampWakeupMinutes':
          result = clampWakeupMinutes(args[0]);
        case 'skippedDays':
          result = skippedDays(
                  args[0] == null ? null : strMap(args[0]))
              .map(iso)
              .toList()
            ..sort();
        case 'withSkippedDay':
          result = withSkippedDay(
            args[0] == null ? null : strMap(args[0]),
            args[1] as DateTime,
            args[2] as bool,
            args.length > 3 ? args[3] as DateTime? : null,
          );
        case 'periodOf':
          result = periodOf(strMap(args[0]), args[1]);
        case 'isCancelledLesson':
          result = isCancelledLesson(strMap(args[0]), args[1]);
        case 'indexDays':
          final days = indexDays(
              args[0] == null ? null : strMap(args[0]));
          result = {for (final e in days.entries) iso(e.key): e.value};
        case 'plannedOff':
          result = plannedOff(
            args[0] as DateTime,
            args[1] as int?,
            (args[2] as List).map((e) => strMap(e)).toList(),
          );
        case 'clockAppWeekday':
          result = clockAppWeekday(alarmOf(strMap(args[0])),
              args.length > 1 ? args[1] as DateTime? : null);
        case 'alarmQueue':
          result = alarmQueue(
            [(args[0] as List).map((e) => alarmOf(strMap(e)))]
                .expand((l) => l)
                .toList(),
            lang: args.length > 1 ? args[1] as String? : null,
          );
        case 'upcomingWakeupAlarms':
          final m = strMap(args[0]);
          result = [
            for (final a in upcomingWakeupAlarms(
              strMap(m['timetable']),
              config: m['config'] == null
                  ? null
                  : strMap(m['config']),
              now: m['now'] as DateTime?,
            ))
              alarmJson(a),
          ];
        case 'upcomingSkippedDays':
          final m = strMap(args[0]);
          result = [
            for (final e in upcomingSkippedDays(
              strMap(m['timetable']),
              config: m['config'] == null
                  ? null
                  : strMap(m['config']),
              now: m['now'] as DateTime?,
            ))
              [iso(e.$1), e.$2 == null ? null : alarmJson(e.$2!)],
          ];
        case 'nextWakeupAlarm':
          final m = strMap(args[0]);
          final a = nextWakeupAlarm(
            strMap(m['timetable']),
            config:
                m['config'] == null ? null : strMap(m['config']),
            now: m['now'] as DateTime?,
          );
          result = a == null ? null : alarmJson(a);
        case 'buildWidgetDayRows':
          final opts = strMap(args[2]);
          result = buildWidgetDayRows(
            (args[0] as List).cast<Object?>(),
            args[1] as DateTime,
            lang: opts['lang'] as String?,
          );
        case 'buildWidgetPayload':
          final m = strMap(args[0]);
          final opts = strMap(args[1]);
          result = buildWidgetPayload(
            strMap(m['timetable']),
            config:
                m['config'] == null ? null : strMap(m['config']),
            now: m['now'] as DateTime?,
            lang: opts['lang'] as String?,
          );
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
