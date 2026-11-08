// Wake-up alarm before the first lesson, and the Android home-screen widget.
//
// Port of strakalari/core/wakeup.py. Everything here is pure (no Android
// runtime: tests and the desktop app run it as is) except [syncAndroid],
// which hands the results to the phone's side through [wakeupPhoneBridge]
// (implemented by the app in phase 8; Android execution lives there).
//
// Both results are plans the phone carries out while Dart isn't running:
// the alarm queue covers the next two weeks (``AlarmReceiver`` arms one
// alarm after another), and the widget data carries dates and clock times
// instead of "today" / "now", so the widget itself works out the day to show
// and the running lesson, also after midnight or between lessons.
import 'dart:convert';

import 'package:clock/clock.dart';

import 'i18n.dart';
import 'models.dart';
import 'planning/planned_skips.dart';
import 'planning/schedule.dart';
import 'planning/school_presets.dart';
import 'storage/helpers.dart';

/// Default ``wakeup_minutes_before``.
const int defaultWakeupMinutes = 60;

/// Bounds for ``wakeup_minutes_before``.
const int minWakeupMinutes = 1;
const int maxWakeupMinutes = 720;

/// Days ahead the alarm queue covers (the phone rings them without the app).
const int alarmHorizonDays = 14;

/// Days the widget can show: from this week's Monday on.
const int widgetSpanDays = 21;

/// Config keys the widget data or the alarms depend on (others need no sync).
const Set<String> phoneConfigKeys = {
  'wakeup_enabled',
  'wakeup_minutes_before',
  'wakeup_skip_dates',
  'planned_skips',
  'school_preset_id',
  'user_free_days',
  'holidays',
  'forced_school_days',
  'language',
};

/// A lesson known only by its start (the stable timetable has no end times).
const int _lessonMin = 45;
final RegExp _startRe = RegExp(r'(\d{1,2}):(\d{2})');

const Map<String, List<String>> _dayNames = {
  'cs': ['Pondělí', 'Úterý', 'Středa', 'Čtvrtek', 'Pátek', 'Sobota', 'Neděle'],
  'en': [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ],
};

/// Attendance statuses -> (widget badge key, row status the widget colors by).
const Map<String, (String, String)> _statusRows = {
  'cancelled': ('widget_cancelled', 'cancelled'),
  'absent': ('widget_absent', 'absent'),
  'excused': ('widget_excused', 'excused'),
  'late': ('widget_late', 'late'),
  'soon': ('widget_left_early', 'late'),
  'early': ('widget_left_early', 'late'),
};

Map<String, Object?> _strMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': e.value};
  }
  return {};
}

/// One wake-up alarm, [minutesBefore] ahead of the day's first lesson.
class WakeupAlarm {
  final DateTime day;
  final DateTime alarmDt;
  final DateTime lessonStartDt;
  final int? period;
  final String subject;
  final String room;
  final int minutesBefore;

  const WakeupAlarm({
    required this.day,
    required this.alarmDt,
    required this.lessonStartDt,
    required this.period,
    required this.subject,
    required this.room,
    required this.minutesBefore,
  });

  /// The day the alarm rings: [day] itself, or the day before when
  /// [minutesBefore] reaches back past midnight.
  DateTime get ringDay => DateTime(alarmDt.year, alarmDt.month, alarmDt.day);

  String _hhmm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String get alarmTimeLabel => _hhmm(alarmDt);
  String get lessonTimeLabel => _hhmm(lessonStartDt);

  @override
  bool operator ==(Object other) =>
      other is WakeupAlarm &&
      other.day == day &&
      other.alarmDt == alarmDt &&
      other.lessonStartDt == lessonStartDt &&
      other.period == period &&
      other.subject == subject &&
      other.room == room &&
      other.minutesBefore == minutesBefore;

  @override
  int get hashCode => Object.hash(
    day,
    alarmDt,
    lessonStartDt,
    period,
    subject,
    room,
    minutesBefore,
  );
}

/// ``wakeup_minutes_before`` as a whole number within ``[1, 720]``.
int clampWakeupMinutes(
  Object? value, [
  int defaultValue = defaultWakeupMinutes,
]) {
  try {
    final parsed = double.parse(
      '$value'.trim().replaceAll(',', '.'),
    ).truncate();
    return parsed.clamp(minWakeupMinutes, maxWakeupMinutes);
  } catch (_) {
    return defaultValue;
  }
}

/// Days the user switched the alarm off for (``wakeup_skip_dates``).
Set<DateTime> skippedDays(Map<String, Object?>? config) {
  final raw = (config ?? {})['wakeup_skip_dates'] ?? [];
  final out = <DateTime>{};
  if (raw is List) {
    for (final value in raw) {
      final parsed = DateTime.tryParse('$value');
      if (parsed != null) {
        out.add(DateTime(parsed.year, parsed.month, parsed.day));
      }
    }
  }
  return out;
}

/// ``wakeup_skip_dates`` with [day] added or removed; past days dropped.
List<String> withSkippedDay(
  Map<String, Object?>? config,
  DateTime day,
  bool skip, [
  DateTime? today,
]) {
  final todayDate = today ?? clock.now();
  final todayDay = DateTime(todayDate.year, todayDate.month, todayDate.day);
  final dayOnly = DateTime(day.year, day.month, day.day);
  final days = {
    for (final d in skippedDays(config))
      if (!d.isBefore(todayDay)) d,
  };
  if (skip) {
    days.add(dayOnly);
  } else {
    days.remove(dayOnly);
  }
  String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return [for (final d in days.toList()..sort()) iso(d)];
}

// -- timetable access ------------------------------------------------------
// (Private in Python; public here because status_notification.dart uses
// them too, and Dart privacy is per library. Python names in parentheses.)

/// Lesson number (the timetable view's rule: the clock text, else the row).
/// (Python: ``_period_of``.)
int? periodOf(Map<String, Object?> raw, Object? day) {
  final parsed = Lesson.fromLegacy(raw, day);
  var num = extractLessonNum(parsed.time) ?? parsed.period;
  try {
    return num != null ? int.parse('$num') : null;
  } catch (_) {
    return null;
  }
}

/// True for a cancelled lesson row. (Python: ``_cancelled``.)
bool isCancelledLesson(Map<String, Object?> raw, Object? day) =>
    Lesson.fromLegacy(raw, day).status.toLowerCase() == 'cancelled';

/// ``{date: lessons}`` from cache keys in any accepted day format.
/// (Python: ``_index_days``.)
Map<DateTime, List<Map<String, Object?>>> indexDays(
  Map<String, Object?>? timetable,
) {
  final out = <DateTime, List<Map<String, Object?>>>{};
  for (final entry in (timetable ?? {}).entries) {
    final day = parseCzDate(entry.key);
    if (day != null && entry.value is List) {
      out[DateTime(day.year, day.month, day.day)] = [
        for (final r in (entry.value as List))
          if (r is Map) _strMap(r),
      ];
    }
  }
  return out;
}

/// The day's lessons; past the cached weeks, the stable timetable's.
///
/// A day missing from a week that was loaded (other days of it cached)
/// had no lessons, e.g. a holiday or a day off the school calendar lacks:
/// it stays empty instead of getting the stable timetable.
/// (Python: ``_lessons_for``.)
List<Map<String, Object?>> lessonsFor(
  Map<DateTime, List<Map<String, Object?>>> days,
  DateTime day,
  Map<(int, int), Object?>? stableBaseline,
) {
  final dayOnly = DateTime(day.year, day.month, day.day);
  if (days.containsKey(dayOnly)) return days[dayOnly]!;
  final monday = dayOnly.subtract(Duration(days: dayOnly.weekday - 1));
  if ([
    for (var i = 0; i < 7; i++) monday.add(Duration(days: i)),
  ].any(days.containsKey)) {
    return [];
  }
  if (stableBaseline != null && dayOnly.weekday <= 5) {
    final week = stableTemplateWeek(stableBaseline, monday);
    return [for (final r in (week[dayOnly] ?? [])) _strMap(r)];
  }
  return [];
}

/// A lesson number's usual clock: minutes since midnight plus its label.
class PeriodSlot {
  final int start;
  final int end;
  final String label;

  const PeriodSlot(this.start, this.end, this.label);
}

/// The most common clock of each lesson number across the cached weeks.
/// (Python: ``_period_slots``.)
Map<int, PeriodSlot> periodSlots(
  Map<DateTime, List<Map<String, Object?>>> days,
) {
  final counts = <int, Map<(int, int, String), int>>{};
  for (final entry in days.entries) {
    for (final raw in entry.value) {
      final period = periodOf(raw, entry.key);
      final clock = lessonClock(raw, entry.key);
      if (period == null || clock == null) continue;
      final label = shortTime(Lesson.fromLegacy(raw, entry.key).time);
      final key = (clock.$1, clock.$2, label);
      counts.putIfAbsent(period, () => {})[key] =
          (counts[period]![key] ?? 0) + 1;
    }
  }
  return {
    for (final entry in counts.entries)
      entry.key: (() {
        final best = entry.value.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
        return PeriodSlot(best.$1, best.$2, best.$3);
      })(),
  };
}

/// ``(start, end)`` minutes. A lesson without its own range takes its
/// number's usual one, else its start alone (``1 (8:00)`` in the stable
/// timetable). (Python: ``_clock_of``.)
(int, int)? clockOf(
  Map<String, Object?> raw,
  DateTime day,
  int? period,
  Map<int, PeriodSlot> slots,
) {
  var clock = lessonClock(raw, day);
  if (clock == null && period != null && slots.containsKey(period)) {
    final slot = slots[period]!;
    clock = (slot.start, slot.end);
  }
  if (clock == null) {
    final match = _startRe.firstMatch(Lesson.fromLegacy(raw, day).time);
    if (match != null &&
        int.parse(match.group(1)!) < 24 &&
        int.parse(match.group(2)!) < 60) {
      final start =
          int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
      clock = (start, start + _lessonMin);
    }
  }
  return clock;
}

// -- wake-up alarm -----------------------------------------------------------

/// True when a planned absence covers lesson [period] on [day].
///
/// The planner's rule: ``start_period`` limits the first day, ``end_period``
/// the last, the days between are whole; a lesson without a number counts
/// as covered. (Python: ``_planned_off``.)
bool plannedOff(DateTime day, int? period, List<Map<String, Object?>> planned) {
  final dayOnly = DateTime(day.year, day.month, day.day);
  for (final entry in planned) {
    if (entryCovers(entry, dayOnly, period)) return true;
  }
  return false;
}

/// ``(start minutes, period, lesson)`` of the day's first attended lesson.
/// (Python: ``_first_lesson``.)
({int start, int? period, Map<String, Object?> lesson})? firstLesson(
  List<Map<String, Object?>> lessons,
  DateTime day,
  List<Map<String, Object?>> planned,
  Map<int, PeriodSlot> slots,
) {
  ((int, int), int?, Map<String, Object?>)? best;
  for (final raw in lessons) {
    if (isCancelledLesson(raw, day)) continue;
    final period = periodOf(raw, day);
    if (plannedOff(day, period, planned)) continue;
    final clock = clockOf(raw, day, period, slots);
    if (clock == null) continue;
    final key = (clock.$1, period ?? 99);
    if (best == null ||
        key.$1 < best.$1.$1 ||
        (key.$1 == best.$1.$1 && key.$2 < best.$1.$2)) {
      best = (key, period, raw);
    }
  }
  if (best == null) return null;
  return (start: best.$1.$1, period: best.$2, lesson: best.$3);
}

/// Each day's alarm, from what all of them share: the minutes, the school
/// calendar, the planned absences and the timetable (read once).
class DayAlarms {
  final int minutes;
  final Set<DateTime> freeDays;
  final List<Map<String, Object?>> planned;
  final Map<DateTime, List<Map<String, Object?>>> days;
  final Map<int, PeriodSlot> slots;
  final Map<(int, int), Object?>? stableBaseline;

  DayAlarms(
    Map<String, Object?>? timetable,
    Map<String, Object?> cfg, [
    this.stableBaseline,
  ]) : minutes = clampWakeupMinutes(cfg['wakeup_minutes_before']),
       freeDays = _freeDaysOf(cfg),
       planned = loadPlannedSkips(cfg),
       days = indexDays(timetable),
       slots = periodSlots(indexDays(timetable));

  static Set<DateTime> _freeDaysOf(Map<String, Object?> cfg) {
    try {
      return effectiveCalendar(cfg, clip: false).dates;
    } catch (_) {
      // A broken calendar must not stop the alarm.
      return {};
    }
  }

  /// [day]'s alarm whether or not it is skipped or past; null on a
  /// free day or a day without an attended lesson.
  WakeupAlarm? alarm(DateTime day) {
    final dayOnly = DateTime(day.year, day.month, day.day);
    if (freeDays.contains(dayOnly)) return null;
    final first = firstLesson(
      lessonsFor(days, dayOnly, stableBaseline),
      dayOnly,
      planned,
      slots,
    );
    if (first == null) return null;
    final lessonDt = DateTime(
      dayOnly.year,
      dayOnly.month,
      dayOnly.day,
      first.start ~/ 60,
      first.start % 60,
    );
    final parsed = Lesson.fromLegacy(first.lesson, dayOnly);
    return WakeupAlarm(
      day: dayOnly,
      alarmDt: lessonDt.subtract(Duration(minutes: minutes)),
      lessonStartDt: lessonDt,
      period: first.period,
      subject: parsed.subject.isNotEmpty ? parsed.subject : '?',
      room: parsed.room,
      minutesBefore: minutes,
    );
  }
}

/// The wake-up alarms from [now] up to [horizonDays] ahead, earliest first.
///
/// One per school day, ``wakeup_minutes_before`` ahead of the first lesson
/// actually attended: cancelled lessons and planned absences don't count,
/// free days (school calendar) and ``wakeup_skip_dates`` get none. Past
/// the cached weeks the stable timetable stands in. Alarms already past
/// are left out; empty while the alarm is off.
List<WakeupAlarm> upcomingWakeupAlarms(
  Map<String, Object?>? timetable, {
  Map<String, Object?>? config,
  DateTime? now,
  Map<(int, int), Object?>? stableBaseline,
  int horizonDays = alarmHorizonDays,
}) {
  final cfg = config ?? {};
  if (!_truthy(cfg['wakeup_enabled'])) return [];
  now = now ?? clock.now();
  final skipped = skippedDays(cfg);
  final planner = DayAlarms(timetable, cfg, stableBaseline);
  final alarms = <WakeupAlarm>[];
  final today = DateTime(now.year, now.month, now.day);
  for (var ahead = 0; ahead <= (horizonDays < 0 ? 0 : horizonDays); ahead++) {
    final day = today.add(Duration(days: ahead));
    if (skipped.contains(day)) continue;
    final alarm = planner.alarm(day);
    if (alarm != null && alarm.alarmDt.isAfter(now)) {
      alarms.add(alarm);
    }
  }
  return alarms;
}

/// The skipped days a "wake me" button can still give an alarm back to,
/// earliest first, each with that alarm (null when the day has none now).
///
/// A day drops out once its alarm would have rung (no button lingering
/// through the afternoon), a day without an alarm once it has come.
List<(DateTime, WakeupAlarm?)> upcomingSkippedDays(
  Map<String, Object?>? timetable, {
  Map<String, Object?>? config,
  DateTime? now,
  Map<(int, int), Object?>? stableBaseline,
}) {
  final cfg = config ?? {};
  now = now ?? clock.now();
  final planner = DayAlarms(timetable, cfg, stableBaseline);
  final today = DateTime(now.year, now.month, now.day);
  final out = <(DateTime, WakeupAlarm?)>[];
  final skipped = skippedDays(cfg).toList()..sort();
  for (final day in skipped) {
    if (day.isBefore(today)) continue;
    final alarm = planner.alarm(day);
    final stillAhead = alarm != null
        ? alarm.alarmDt.isAfter(now)
        : day.isAfter(today);
    if (stillAhead) out.add((day, alarm));
  }
  return out;
}

/// The next wake-up alarm, or null (see [upcomingWakeupAlarms]).
WakeupAlarm? nextWakeupAlarm(
  Map<String, Object?>? timetable, {
  Map<String, Object?>? config,
  DateTime? now,
  Map<(int, int), Object?>? stableBaseline,
}) {
  final alarms = upcomingWakeupAlarms(
    timetable,
    config: config,
    now: now,
    stableBaseline: stableBaseline,
  );
  return alarms.isEmpty ? null : alarms.first;
}

/// The weekday (Monday = 0) to hand the phone's Clock app, null for a plain
/// alarm.
///
/// The Clock app takes a time but no date: a plain alarm rings at the next
/// HH:MM, within a day. An alarm further ahead (Monday's, asked on Friday)
/// only lands on its day as a weekly alarm on the weekday it rings (the
/// evening before the lesson when the minutes reach back past midnight).
int? clockAppWeekday(WakeupAlarm alarm, [DateTime? now]) {
  now = now ?? clock.now();
  return alarm.alarmDt.difference(now) >= const Duration(days: 1)
      ? alarm.ringDay.weekday - 1
      : null;
}

/// What ``AlarmReceiver`` rings: epoch ms (alarm, lesson start) and texts.
List<Map<String, Object?>> alarmQueue(
  List<WakeupAlarm> alarms, {
  String? lang,
}) {
  final queue = <Map<String, Object?>>[];
  for (final alarm in alarms) {
    final bits = [
      if (alarm.period != null)
        t('wakeup_alarm_period', lang: lang, args: {'n': alarm.period})
      else
        t('wakeup_alarm_first', lang: lang),
    ];
    if (alarm.room.isNotEmpty) {
      bits.add(t('wakeup_alarm_room', lang: lang, args: {'room': alarm.room}));
    }
    queue.add({
      'at': alarm.alarmDt.millisecondsSinceEpoch,
      'lesson': alarm.lessonStartDt.millisecondsSinceEpoch,
      'title': t(
        'wakeup_alarm_title',
        lang: lang,
        args: {'subject': alarm.subject, 'time': alarm.lessonTimeLabel},
      ),
      'text': bits.join(' · '),
    });
  }
  return queue;
}

// -- home-screen widget ------------------------------------------------------

List<String> _unique(Iterable<Object?> values) {
  final out = <String>[];
  for (final value in values) {
    final text = '$value'.trim();
    if (text.isNotEmpty && !out.contains(text)) out.add(text);
  }
  return out;
}

String _lessonsLabel(int count, String lang) {
  final String key;
  if (count == 1) {
    key = 'widget_lessons_one';
  } else if (count >= 2 && count <= 4) {
    key = 'widget_lessons_few';
  } else {
    key = 'widget_lessons_many';
  }
  return t(key, lang: lang, args: {'n': count});
}

/// One widget row; split-group lessons sharing a period are joined.
Map<String, Object?> _lessonRow(
  List<Map<String, Object?>> raws,
  DateTime day,
  int? period,
  Map<int, PeriodSlot> slots,
  Map<(int, int), Object?>? stableBaseline,
  bool stableComplete,
  String lang,
) {
  final active = [
    for (final r in raws)
      if (!isCancelledLesson(r, day)) r,
  ];
  final shown = active.isEmpty ? raws : active;
  final parsedAll = [for (final r in shown) Lesson.fromLegacy(r, day)];
  final parsed = parsedAll.first;
  final status = parsed.status.toLowerCase();
  final String badge;
  final String rowStatus;
  if (_statusRows.containsKey(status)) {
    badge = t(_statusRows[status]!.$1, lang: lang);
    rowStatus = _statusRows[status]!.$2;
  } else {
    Set<String> changed;
    try {
      final diff = classifyLesson(
        shown.first,
        day,
        stableBaseline ?? {},
        stableComplete,
      );
      changed = diff.isChange ? diff.changed.toSet() : {};
    } catch (_) {
      // An unclassifiable lesson is shown plain.
      changed = {};
    }
    if (changed.isEmpty) {
      badge = '';
      rowStatus = 'normal';
    } else {
      final String badgeKey;
      if (changed.contains('added')) {
        badgeKey = 'widget_added';
      } else if (changed.contains('teacher')) {
        badgeKey = 'widget_substitution';
      } else if (changed.contains('room') &&
          changed.difference({'room', 'notice'}).isEmpty) {
        badgeKey = 'widget_room_change';
      } else {
        badgeKey = 'widget_change';
      }
      badge = t(badgeKey, lang: lang);
      rowStatus = 'change';
    }
  }
  final clock = clockOf(shown.first, day, period, slots);
  var timeLabel = shortTime(parsed.time);
  if (period != null &&
      slots.containsKey(period) &&
      (timeLabel.isEmpty || lessonClock(shown.first, day) == null)) {
    timeLabel = slots[period]!.label; // the full range, not just "8:00"
  }
  final rooms = _unique([for (final p in parsedAll) p.room]).join(', ');
  final teachers = _unique([
    for (final p in parsedAll) teacherSurname(p.teacher),
  ]).join(', ');
  return {
    'kind': 'lesson',
    'period': period != null ? '$period.' : '',
    'time': timeLabel,
    'subject': _unique([
      for (final p in parsedAll) p.subject,
    ]).join(' / ').ifEmpty('?'),
    'meta': [
      for (final part in [rooms, teachers])
        if (part.isNotEmpty) part,
    ].join(' · '),
    'badge': badge,
    'status': rowStatus,
    'start': clock != null ? clock.$1 : -1,
    'end': clock != null ? clock.$2 : -1,
  };
}

/// The day's widget rows: lessons in period order with the free periods
/// between them (from period 1, or 0 when the day has one) as empty
/// ``"pause"`` rows; lessons without a number come last.
List<Map<String, Object?>> buildWidgetDayRows(
  List<Object?> lessons,
  DateTime day, {
  Map<int, PeriodSlot>? slots,
  Map<(int, int), Object?>? stableBaseline,
  bool stableComplete = false,
  String? lang,
}) {
  lang = (lang ?? getLanguage()) == 'en' ? 'en' : 'cs';
  final clean = [
    for (final r in lessons)
      if (r is Map) _strMap(r),
  ];
  slots = slots ?? periodSlots({day: clean});
  final byPeriod = <int, List<Map<String, Object?>>>{};
  final unnumbered = <Map<String, Object?>>[];
  for (final raw in clean) {
    final period = periodOf(raw, day);
    if (period == null) {
      unnumbered.add(raw);
    } else {
      byPeriod.putIfAbsent(period, () => []).add(raw);
    }
  }
  final rows = <Map<String, Object?>>[];
  if (byPeriod.isNotEmpty) {
    final keys = byPeriod.keys.toList()..sort();
    final minPeriod = keys.first < 1 ? keys.first : 1;
    for (var period = minPeriod; period <= keys.last; period++) {
      if (byPeriod.containsKey(period)) {
        rows.add(
          _lessonRow(
            byPeriod[period]!,
            day,
            period,
            slots,
            stableBaseline,
            stableComplete,
            lang,
          ),
        );
        continue;
      }
      final slot = slots[period];
      rows.add({
        'kind': 'pause',
        'period': '$period.',
        'time': slot != null ? slot.label : '',
        'subject': '',
        'meta': '',
        'badge': '',
        'status': 'pause',
        'start': -1,
        'end': -1,
      });
    }
  }
  for (final raw in unnumbered) {
    rows.add(
      _lessonRow([raw], day, null, slots, stableBaseline, stableComplete, lang),
    );
  }
  return rows;
}

/// The home-screen widget's data (JSON-serializable).
///
/// Days run from this week's Monday for three weeks (weekends only with
/// lessons). Nothing in it says "today" or "now": each day carries its ISO
/// date and each lesson its clock minutes, and the widget picks the day to
/// show and highlights the running / next lesson itself.
Map<String, Object?> buildWidgetPayload(
  Map<String, Object?>? timetable, {
  Map<String, Object?>? config,
  DateTime? now,
  Map<(int, int), Object?>? stableBaseline,
  bool stableComplete = false,
  String? lang,
}) {
  now = now ?? clock.now();
  lang = (lang ?? getLanguage()) == 'en' ? 'en' : 'cs';
  Set<DateTime> freeDays;
  Map<DateTime, String> freeLabels;
  try {
    final calendar = effectiveCalendar(config ?? {}, clip: false);
    freeDays = calendar.dates;
    freeLabels = calendar.labels;
  } catch (_) {
    // A broken calendar must not hide the timetable.
    freeDays = {};
    freeLabels = {};
  }
  final days = indexDays(timetable);
  final slots = periodSlots(days);
  final names = _dayNames[lang]!;
  final today = DateTime(now.year, now.month, now.day);
  final monday = today.subtract(Duration(days: today.weekday - 1));

  final out = <Map<String, Object?>>[];
  for (var offset = 0; offset < widgetSpanDays; offset++) {
    final day = monday.add(Duration(days: offset));
    final lessons = lessonsFor(days, day, stableBaseline);
    if (day.weekday >= 6 && lessons.isEmpty) continue;
    final rows = buildWidgetDayRows(
      lessons,
      day,
      slots: slots,
      stableBaseline: stableBaseline,
      stableComplete: stableComplete,
      lang: lang,
    );
    final taught = [
      for (final r in rows)
        if (r['kind'] == 'lesson' && r['status'] != 'cancelled') r,
    ];
    final free = freeDays.contains(day);
    final String subtitle;
    if (free) {
      subtitle = freeLabels[day] ?? t('widget_day_off', lang: lang);
    } else if (taught.isNotEmpty) {
      subtitle = _lessonsLabel(taught.length, lang);
    } else {
      subtitle = t('widget_no_lessons', lang: lang);
    }
    final ends = [
      for (final r in taught)
        if ((r['end'] as int) >= 0) r['end'] as int,
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    out.add({
      'iso':
          '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}',
      'label': '${names[day.weekday - 1]} ${day.day}. ${day.month}.',
      'subtitle': subtitle,
      'free': free,
      'taught': taught.length,
      'end': ends.isEmpty ? -1 : ends.reduce((a, b) => a > b ? a : b),
      'rows': rows,
    });
  }
  return {
    'today': t('widget_today', lang: lang),
    'tomorrow': t('widget_tomorrow', lang: lang),
    'empty': t(
      days.isEmpty ? 'widget_no_data' : 'widget_no_lessons',
      lang: lang,
    ),
    'days': out,
  };
}

// -- hand-over to the phone --------------------------------------------------

/// Phone-side handlers for the widget data and the alarm queue.
///
/// Implemented by the app's platform channel in phase 8; null elsewhere.
abstract interface class WakeupPhoneBridge {
  bool updateTimetableWidget(String widgetJson);
  bool setWakeupAlarms(String queueJson, String channel, String dismiss);
}

/// The bridge the app registered at startup (null off the phone).
WakeupPhoneBridge? wakeupPhoneBridge;

/// What the phone was last given (only changes are sent again).
final Map<String, String> _sent = {};

/// Test hook: forget what the phone was last given.
void resetWakeupSyncState() => _sent.clear();

/// Hands the widget data and the alarm queue to the phone; a no-op
/// elsewhere.
///
/// Runs on every config save, cache reload and background run, so only
/// changes are sent; the widget data also goes once more on a new day,
/// which redraws a widget whose own midnight refresh never came.
void syncAndroid(
  Map<String, Object?>? timetable, {
  Map<String, Object?>? config,
  Map<(int, int), Object?>? stableBaseline,
  bool stableComplete = false,
  DateTime? now,
}) {
  final bridge = wakeupPhoneBridge;
  if (bridge == null) return;
  now = now ?? clock.now();
  final lang = getLanguage() == 'en' ? 'en' : 'cs';
  String isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  try {
    final widget = jsonEncode(
      buildWidgetPayload(
        timetable,
        config: config,
        now: now,
        stableBaseline: stableBaseline,
        stableComplete: stableComplete,
        lang: lang,
      ),
    );
    final key = '${isoDay(DateTime(now.year, now.month, now.day))}$widget';
    if (_sent['widget'] != key && bridge.updateTimetableWidget(widget)) {
      _sent['widget'] = key;
    }
  } catch (e) {
    // The widget is best effort.
    // ignore: avoid_print
    print('Warning: widget sync failed (${e.runtimeType}: $e)');
  }
  try {
    final alarms = upcomingWakeupAlarms(
      timetable,
      config: config,
      now: now,
      stableBaseline: stableBaseline,
    );
    final queue = jsonEncode(alarmQueue(alarms, lang: lang));
    if (_sent['alarms'] != lang + queue &&
        bridge.setWakeupAlarms(
          queue,
          t('wakeup_channel', lang: lang),
          t('wakeup_dismiss', lang: lang),
        )) {
      _sent['alarms'] = lang + queue;
    }
  } catch (e) {
    // ignore: avoid_print
    print('Warning: wake-up alarm sync failed (${e.runtimeType}: $e)');
  }
}

bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
