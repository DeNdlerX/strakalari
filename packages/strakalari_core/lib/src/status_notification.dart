// The phone's always-on notification as a glanceable overview.
//
// Port of strakalari/core/status_notification.py. While background running
// is on, Android keeps the background service's notification in the shade.
// Instead of only saying that the app runs, it shows what the user picked
// under Settings → Background ([items]), a row each ([StatusRow], drawn with
// an icon by the app's own notification layout):
//
// - ``next_lesson``: the next lesson still ahead (period, subject, start,
//   room and teacher, a substitution or room change marked), past today's
//   last lesson the next school day's first one;
// - ``lunch``: the lunch ordered for today until lunchtime is over (see
//   [lunchOverAt]), then the next one (the dish as Strava names it,
//   or "not ordered");
// - ``lunch_orders``: menu days still open for ordering with nothing
//   ordered, and the earliest deadline;
// - ``excuses``: how many excuses wait to be sent (also none, next to other
//   rows);
// - ``wakeup``: the next wake-up alarm (none while the alarm is off);
// - ``updated``: when the data was last refreshed (the header's small text).
//
// A row with nothing to say is left out; with no row at all the
// notification keeps its plain "running in the background" text.
//
// [buildStatus] is pure (tests and the Settings preview run it anywhere).
// [StatusNotifier] keeps the phone's notification current: it recomputes
// when the data or the settings change and when the clock moves on to a new
// minute, and hands over only what changed.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';

import 'i18n.dart';
import 'lunches/lunch_cutoff.dart';
import 'models.dart';
import 'storage/helpers.dart';
import 'planning/planned_skips.dart';
import 'planning/school_presets.dart';
import 'wakeup.dart'
    show
        buildWidgetDayRows,
        clockOf,
        indexDays,
        isCancelledLesson,
        lessonsFor,
        nextWakeupAlarm,
        periodOf,
        periodSlots,
        plannedOff;

/// Everything the notification can show, in the order it shows them.
const List<String> items = [
  'next_lesson',
  'lunch',
  'lunch_orders',
  'excuses',
  'wakeup',
  'updated',
];

/// What a new install shows (``background_notification_items``).
///
/// (storage/config.dart mirrors this as its default; it rewires to here
/// once the config re-export lands — see the phase-3 handover notes.)
const List<String> defaultItems = ['next_lesson', 'lunch', 'excuses', 'wakeup'];

/// Lunch is eaten in the first free period after this one (when lessons
/// follow it).
const int lunchAfterPeriod = 4;

/// On a day without lessons, the next lunch is shown from this time on.
const (int, int) lunchSwitch = (15, 0);

/// How far ahead the lunch, the next lesson and open orders are looked for.
const int lunchAheadDays = 7;
const int lessonAheadDays = 7;
const int orderAheadDays = 14;

/// Open order days named before "and N more".
const int orderDaysListed = 3;

const Map<String, List<String>> _dayShort = {
  'cs': ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'],
  'en': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
};

/// Weekdays as they follow a word ("Oběd v pondělí", "Lunch on Monday").
const Map<String, List<String>> _dayAfter = {
  'cs': [
    'v pondělí',
    'v úterý',
    've středu',
    've čtvrtek',
    'v pátek',
    'v sobotu',
    'v neděli',
  ],
  'en': [
    'on Monday',
    'on Tuesday',
    'on Wednesday',
    'on Thursday',
    'on Friday',
    'on Saturday',
    'on Sunday',
  ],
};

/// Weekdays standing alone ("order by Monday 12:00"); Czech keeps the "v".
const Map<String, List<String>> _dayPlain = {
  'cs': [
    'v pondělí',
    'v úterý',
    've středu',
    've čtvrtek',
    'v pátek',
    'v sobotu',
    'v neděli',
  ],
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

/// Trailing allergen list: "(1,3,7,9)", "(01, 07 )" (as on the Lunches screen).
final RegExp _allergensRe = RegExp(
  r'\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$',
);

/// The items the user picked, in display order (unknown ids dropped).
List<String> selectedItems(Map<String, Object?>? config) {
  final raw = (config ?? {})['background_notification_items'] ?? defaultItems;
  if (raw is! List) return List.of(defaultItems);
  final picked = {for (final item in raw) '$item'};
  return [
    for (final item in items)
      if (picked.contains(item)) item,
  ];
}

/// ``background_notification_items`` with [item] switched on or off.
List<String> withItem(Map<String, Object?>? config, String item, bool on) {
  final picked = selectedItems(config).toSet();
  if (on) {
    picked.add(item);
  } else {
    picked.remove(item);
  }
  return [
    for (final i in items)
      if (picked.contains(i)) i,
  ];
}

/// What the overview is made of (a snapshot of the app's data).
class StatusInputs {
  final Map<String, Object?> timetable;

  /// ``{DD.MM.YYYY: {meal id: name}}`` (the Strava menu).
  final Map<String, Object?> food;

  /// ``{DD.MM.YYYY: meal id}``: what Strava reported as ordered.
  final Map<String, Object?> webOrders;
  final Map<String, Object?> config;
  final Map<(int, int), Object?>? stableBaseline;
  final bool stableComplete;
  final int pendingExcuses;
  final DateTime? lastUpdated;

  /// The school calendar's days off (null: worked out from [config],
  /// which reads the school presets from disk).
  final Set<DateTime>? freeDays;

  StatusInputs({
    Map<String, Object?>? timetable,
    Map<String, Object?>? food,
    Map<String, Object?>? webOrders,
    Map<String, Object?>? config,
    this.stableBaseline,
    this.stableComplete = false,
    int? pendingExcuses,
    this.lastUpdated,
    this.freeDays,
  }) : timetable = timetable ?? {},
       food = food ?? {},
       webOrders = webOrders ?? {},
       config = config ?? {},
       pendingExcuses = pendingExcuses ?? 0;
}

/// One row of the overview: what it is about (an [items] id, its icon), a
/// label and a value ("Další hodina", "1. Matematika · 8:00 · 214");
/// [short]: the value in the collapsed notification, where rows show
/// without labels and the short ones (a count, a time) share a line with
/// the lunch (the value itself when empty).
class StatusRow {
  final String kind;
  final String label;
  final String value;
  final String short;

  const StatusRow(this.kind, this.label, this.value, [this.short = '']);

  String get line => '$label: $value';

  @override
  bool operator ==(Object other) =>
      other is StatusRow &&
      other.kind == kind &&
      other.label == label &&
      other.value == value &&
      other.short == short;

  @override
  int get hashCode => Object.hash(kind, label, value, short);
}

/// The notification: its rows, the header's small text, and the same as a
/// plain title and text (the first row's label; its value and the other
/// rows' lines) for wherever the rows aren't drawn.
class StatusContent {
  final String title;
  final String text;
  final String sub;
  final List<StatusRow> rows;

  const StatusContent(
    this.title, [
    this.text = '',
    this.sub = '',
    this.rows = const [],
  ]);

  /// The rows for the phone's notification layout ("" without rows).
  String rowsJson() {
    if (rows.isEmpty) return '';
    return jsonEncode([
      for (final r in rows)
        {
          'kind': r.kind,
          'label': r.label,
          'value': r.value,
          'short': r.short.isNotEmpty ? r.short : r.value,
        },
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (other is! StatusContent) return false;
    if (other.title != title || other.text != text || other.sub != sub) {
      return false;
    }
    if (other.rows.length != rows.length) return false;
    for (var i = 0; i < rows.length; i++) {
      if (other.rows[i] != rows[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(title, text, sub, rows.length);
}

String _lang(String? lang) => (lang ?? getLanguage()) == 'en' ? 'en' : 'cs';

/// ``9. 11.``, never broken across two lines.
String _date(DateTime day) => '${day.day}.\u00a0${day.month}.';

DateTime _dayOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

/// When [day] is: "dnes" / "zítra" / "v pondělí" ("today" / "tomorrow" /
/// "on Monday").
String _dayPhrase(
  DateTime day,
  DateTime today,
  String lang, {
  bool plain = false,
}) {
  day = _dayOnly(day);
  today = _dayOnly(today);
  if (day == today) return t('status_today', lang: lang);
  if (day == addDays(today, 1)) {
    return t('status_tomorrow', lang: lang);
  }
  final names = plain ? _dayPlain : _dayAfter;
  var text = names[lang]![day.weekday - 1];
  if (!day.isBefore(addDays(today, 7))) {
    text += ' ${_date(day)}';
  }
  return text;
}

String _shortDay(DateTime day, String lang) =>
    '${_dayShort[lang]![day.weekday - 1]} ${_date(day)}';

String _clock(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

/// A Strava meal name for one line: spacing tidied, allergens dropped.
///
/// ``"oběd 1 - Polévka,Řízek(01, 07 )"`` -> ``"Oběd 1 - Polévka, Řízek"``.
String mealText(Object? name) {
  // Python `str(name or "")`: every falsy value (None, 0, "", False)
  // renders as the empty string, not "None"/"0"/"False".
  final raw = name == null ||
          name == false ||
          (name is num && name == 0) ||
          (name is String && name.isEmpty) ||
          (name is Iterable && name.isEmpty) ||
          (name is Map && name.isEmpty)
      ? ''
      : '$name';
  var text = raw.replaceAllMapped(
    RegExp(r',(\S)'),
    (m) => ', ${m.group(1)}',
  );
  text = text
      .replaceAll(RegExp(r'\s+\)'), ')')
      .replaceAllMapped(RegExp(r'(\S)\('), (m) => '${m.group(1)} (');
  text = _allergensRe.firstMatch(text.trim()) != null
      ? text.trim().replaceAll(_allergensRe, '')
      : text.trim();
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  while (text.endsWith(',') || text.endsWith(';')) {
    text = text.substring(0, text.length - 1).trim();
  }
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}

/// A day's menu without the "no lunch" control (``…&-1&…``).
Map<String, String> _realMeals(Object? meals) {
  if (meals is! Map) return {};
  return {
    for (final entry in meals.entries)
      if (!'${entry.key}'.contains('&-1&')) '${entry.key}': '${entry.value}',
  };
}

String _orderedMeal(Map<String, Object?> webOrders, String key) {
  final meal = '${webOrders[key] ?? ''}';
  return meal.contains('&-1&') ? '' : meal;
}

Set<DateTime> _freeDays(StatusInputs inputs) {
  if (inputs.freeDays != null) return inputs.freeDays!;
  try {
    return effectiveCalendar(inputs.config, clip: false).dates;
  } catch (_) {
    // A broken calendar must not hide the lines.
    return {};
  }
}

/// ``{day: cache key}`` for days with a menu or an order.
Map<DateTime, String> _menuDays(StatusInputs inputs) {
  final out = <DateTime, String>{};
  for (final key in [...inputs.food.keys, ...inputs.webOrders.keys]) {
    final day = parseCzDate(key);
    if (day == null) continue;
    final canon = canonicalDayKey(key);
    if (_realMeals(inputs.food[canon]).isNotEmpty ||
        _orderedMeal(inputs.webOrders, canon).isNotEmpty) {
      out[_dayOnly(day)] = canon;
    }
  }
  return out;
}

/// Minute of [day] from which its lunch is over, null without lessons.
///
/// Lunch is eaten in the first free period after the 4th lesson that has
/// lessons after it, so it is over when that period ends (its usual clock,
/// else when the next lesson starts). Without such a gap it is over when
/// the classes end. A cancelled lesson leaves its period free.
int? lunchOverAt(StatusInputs inputs, DateTime day) {
  day = _dayOnly(day);
  final days = indexDays(inputs.timetable);
  final lessons = [
    for (final raw in lessonsFor(days, day, inputs.stableBaseline))
      if (!isCancelledLesson(raw, day)) raw,
  ];
  if (lessons.isEmpty) return null;
  final slots = periodSlots(days);
  final taught = <int, (int, int)?>{};
  final ends = <int>[];
  for (final raw in lessons) {
    final period = periodOf(raw, day);
    final clock = clockOf(raw, day, period, slots);
    if (clock != null) ends.add(clock.$2);
    if (period != null && !(taught.containsKey(period))) {
      taught[period] = clock;
    }
  }
  final maxTaught = taught.isEmpty
      ? 0
      : taught.keys.reduce((a, b) => a > b ? a : b);
  final gaps = [
    for (var p = lunchAfterPeriod + 1; p < maxTaught; p++)
      if (!taught.containsKey(p)) p,
  ];
  if (gaps.isNotEmpty) {
    final gap = gaps.first;
    if (slots.containsKey(gap)) return slots[gap]!.end;
    final afterPeriods = [
      for (final p in taught.keys)
        if (p > gap) p,
    ]..sort();
    final after = taught[afterPeriods.first];
    if (after != null) return after.$1;
  }
  return ends.isEmpty ? null : ends.reduce((a, b) => a > b ? a : b);
}

// -- the lines ---------------------------------------------------------------

/// When [day] is, for the collapsed notification: "" today, "zítra", "Po".
String _shortWhen(DateTime day, DateTime today, String lang) {
  day = _dayOnly(day);
  today = _dayOnly(today);
  if (day == today) return '';
  if (day == addDays(today, 1)) {
    return t('status_tomorrow', lang: lang);
  }
  return _dayShort[lang]![day.weekday - 1];
}

/// [value], for another day than today led by when ("zítra: …", "Po: …").
String _unlessToday(DateTime day, DateTime today, String lang, String value) {
  final when = _shortWhen(day, today, lang);
  return when.isNotEmpty ? '$when: $value' : value;
}

/// "Oběd dnes" / "Oběd 1 - Polévka, Řízek": the day and the dish.
StatusRow? buildLunchRow(StatusInputs inputs, DateTime now, String lang) {
  final today = _dayOnly(now);
  final over =
      lunchOverAt(inputs, today) ?? lunchSwitch.$1 * 60 + lunchSwitch.$2;
  final first = now.hour * 60 + now.minute < over
      ? today
      : addDays(today, 1);
  final days = _menuDays(inputs);
  final upcoming = [
    for (final day in days.keys)
      if (!day.isBefore(first) &&
          !day.isAfter(addDays(today, lunchAheadDays)))
        day,
  ]..sort();
  if (upcoming.isEmpty) return null;
  final day = upcoming.first;
  final key = days[day]!;
  final meal = _orderedMeal(inputs.webOrders, key);
  final menu = inputs.food[key];
  final name = (meal.isNotEmpty && menu is Map) ? menu[meal] : null;
  final String value;
  if (meal.isEmpty) {
    value = t('status_lunch_none', lang: lang);
  } else {
    value = name != null
        ? mealText(name)
        : t('status_lunch_ordered', lang: lang);
  }
  return StatusRow(
    'lunch',
    t('status_lunch', lang: lang, args: {'when': _dayPhrase(day, today, lang)}),
    value,
    _unlessToday(day, today, lang, value),
  );
}

StatusRow? _nextLessonRow(StatusInputs inputs, DateTime now, String lang) {
  final days = indexDays(inputs.timetable);
  if (days.isEmpty) return null;
  final freeDays = _freeDays(inputs);
  final planned = loadPlannedSkips(inputs.config);
  final slots = periodSlots(days);
  final today = _dayOnly(now);
  final nowMin = now.hour * 60 + now.minute;
  for (var ahead = 0; ahead <= lessonAheadDays; ahead++) {
    final day = addDays(today, ahead);
    if (freeDays.contains(day)) continue;
    final lessons = lessonsFor(days, day, inputs.stableBaseline);
    if (lessons.isEmpty) continue;
    final rows = buildWidgetDayRows(
      lessons,
      day,
      slots: slots,
      stableBaseline: inputs.stableBaseline,
      stableComplete: inputs.stableComplete,
      lang: lang,
    );
    for (final row in rows) {
      if (row['kind'] != 'lesson' || row['status'] == 'cancelled') continue;
      final period = ('${row['period']}'.replaceAll(RegExp(r'\.+$'), ''));
      if (plannedOff(day, int.tryParse(period), planned)) continue;
      if (ahead == 0 && !((row['start'] as int) > nowMin)) {
        continue; // already running or over (or no clock to tell)
      }
      final parts = ['${row['period']} ${row['subject']}'.trim()];
      if ((row['start'] as int) >= 0) parts.add(_clock(row['start'] as int));
      parts.addAll([
        for (final p in [row['meta'], row['badge']])
          if ('$p'.isNotEmpty) '$p',
      ]);
      final lesson = parts.join(' · ');
      final label = ahead == 0
          ? t('status_lesson', lang: lang)
          : t(
              'status_lesson_on',
              lang: lang,
              args: {'when': _dayPhrase(day, today, lang)},
            );
      return StatusRow(
        'next_lesson',
        label,
        lesson,
        _unlessToday(day, today, lang, lesson),
      );
    }
  }
  return null;
}

/// Menu days still open for ordering with nothing ordered (planned days
/// off whose lunch the planner cancels don't count).
StatusRow? buildLunchOrdersRow(StatusInputs inputs, DateTime now, String lang) {
  final today = _dayOnly(now);
  final cutoff = resolveLunchCutoff(inputs.config);
  final freeDays = _freeDays(inputs);
  final skipped = plannedLunchDays(inputs.config);
  final openDays = <(DateTime, DateTime)>[];
  for (final entry in inputs.food.entries) {
    final day = parseCzDate(entry.key);
    final canon = canonicalDayKey(entry.key);
    if (day == null ||
        _dayOnly(day).isBefore(today) ||
        _dayOnly(
          day,
        ).isAfter(addDays(today, orderAheadDays)) ||
        _realMeals(entry.value).isEmpty ||
        _orderedMeal(inputs.webOrders, canon).isNotEmpty ||
        skipped.contains(canon)) {
      continue;
    }
    if (isLunchOrderOpen(
      _dayOnly(day),
      now: now,
      cutoffTime: cutoff,
      freeDays: freeDays,
    )) {
      openDays.add((
        _dayOnly(day),
        lunchOrderDeadline(_dayOnly(day), cutoff, freeDays),
      ));
    }
  }
  if (openDays.isEmpty) return null;
  openDays.sort((a, b) => a.$1.compareTo(b.$1));
  var names = openDays
      .take(orderDaysListed)
      .map((e) => _shortDay(e.$1, lang))
      .join(', ');
  if (openDays.length > orderDaysListed) {
    names = t(
      'status_orders_more',
      lang: lang,
      args: {'days': names, 'n': openDays.length - orderDaysListed},
    );
  }
  final deadline = openDays
      .map((e) => e.$2)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  String two(int n) => n.toString().padLeft(2, '0');
  final by =
      '${_dayPhrase(deadline, today, lang, plain: true)} ${two(deadline.hour)}:${two(deadline.minute)}';
  return StatusRow(
    'lunch_orders',
    t('status_orders', lang: lang),
    t('status_orders_value', lang: lang, args: {'days': names, 'deadline': by}),
    '${openDays.length}',
  );
}

StatusRow _excusesRow(StatusInputs inputs, DateTime now, String lang) {
  final n = (inputs.pendingExcuses < 0 ? 0 : inputs.pendingExcuses);
  return StatusRow('excuses', t('status_excuses', lang: lang), '$n');
}

StatusRow? _wakeupRow(StatusInputs inputs, DateTime now, String lang) {
  final alarm = nextWakeupAlarm(
    inputs.timetable,
    config: inputs.config,
    now: now,
    stableBaseline: inputs.stableBaseline,
  );
  if (alarm == null) return null;
  final time = _clock(alarm.alarmDt.hour * 60 + alarm.alarmDt.minute);
  return StatusRow(
    'wakeup',
    t('status_wakeup', lang: lang),
    t(
      'status_wakeup_value',
      lang: lang,
      args: {
        'when': _dayPhrase(alarm.day, _dayOnly(now), lang, plain: true),
        'time': time,
      },
    ),
    '${_shortWhen(alarm.day, _dayOnly(now), lang)} $time'.trim(),
  );
}

String _updatedText(StatusInputs inputs, DateTime now, String lang) {
  final stamp = inputs.lastUpdated;
  if (stamp == null) return '';
  var when = _clock(stamp.hour * 60 + stamp.minute);
  if (_dayOnly(stamp) != _dayOnly(now)) {
    when = '${_date(_dayOnly(stamp))} $when';
  }
  return t('status_updated', lang: lang, args: {'time': when});
}

/// Row builders consulted by [buildStatus], in no fixed order.
///
/// Top-level variables (rather than direct calls) so tests can replace one
/// with a throwing stub — the port of ``monkeypatch.setattr(sn,
/// "_orders_row", _boom)`` proving one broken line leaves the others.
typedef StatusRowBuilder =
    StatusRow? Function(StatusInputs inputs, DateTime now, String lang);

StatusRowBuilder lunchRowBuilder = buildLunchRow;
StatusRowBuilder nextLessonRowBuilder = _nextLessonRow;
StatusRowBuilder lunchOrdersRowBuilder = buildLunchOrdersRow;

StatusRow? _excusesRowBuilder(StatusInputs inputs, DateTime now, String lang) =>
    _excusesRow(inputs, now, lang);
StatusRow? _wakeupRowBuilder(StatusInputs inputs, DateTime now, String lang) =>
    _wakeupRow(inputs, now, lang);

/// The notification for [now]: a row per picked item with something
/// to say; without any, [fallback] (title, text). Never raises for a
/// broken item: that row is left out.
StatusContent buildStatus(
  StatusInputs inputs, {
  DateTime? now,
  (String, String) fallback = ('Strakaláři', ''),
  String? lang,
}) {
  now = now ?? clock.now();
  lang = _lang(lang);
  final picked = selectedItems(inputs.config);
  final strava = _truthy(inputs.config['use_strava'] ?? true);
  final builders = <String, StatusRowBuilder>{
    'next_lesson': nextLessonRowBuilder,
    'lunch': (i, n, l) => strava ? lunchRowBuilder(i, n, l) : null,
    'lunch_orders': (i, n, l) => strava ? lunchOrdersRowBuilder(i, n, l) : null,
    'excuses': _excusesRowBuilder,
    'wakeup': _wakeupRowBuilder,
  };
  final rows = <StatusRow>[];
  for (final item in picked) {
    final build = builders[item];
    if (build == null) continue;
    try {
      final row = build(inputs, now, lang);
      if (row != null && row.value.isNotEmpty) rows.add(row);
    } catch (e) {
      // One broken row must not blank the rest.
      // ignore: avoid_print
      print('Warning: notification line $item failed (${e.runtimeType}: $e)');
    }
  }
  if (rows.isNotEmpty &&
      rows.every((row) => row.kind == 'excuses' && row.value == '0')) {
    rows.clear(); // "none to send" alone says nothing: the plain text instead
  }
  final sub = picked.contains('updated') ? _updatedText(inputs, now, lang) : '';
  if (rows.isEmpty) {
    return StatusContent(fallback.$1, fallback.$2, sub);
  }
  final text = [
    rows.first.value,
    for (final row in rows.skip(1)) row.line,
  ].join('\n');
  return StatusContent(rows.first.label, text, sub, rows);
}

bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

// -- keeping the phone's notification current ----------------------------------

/// Recomputes the notification and hands over changes.
///
/// [gather] returns a fresh [StatusInputs], or null while the notification
/// isn't shown (background running off): nothing is posted then. It runs
/// again after [poke] (data or settings changed), on a new day and every
/// [maxAgeS] as a safety net; in between, a new minute recomputes from the
/// inputs it has (the next lesson moves on, the lunch switches to
/// tomorrow's). [post] delivers; false means it didn't, and it is tried
/// again a minute later.
///
/// The loop wakes every [tickS] seconds when [start]ed (a [Timer], not a
/// thread: a phone asleep in Doze runs no thread, and a short tick catches
/// up within seconds of waking). [settleS] is kept for API parity; the app
/// debounces bursts of [poke] calls itself before this port's loop sees
/// them.
class StatusNotifier {
  final StatusInputs? Function() gather;
  final bool Function(StatusContent) post;
  final (String, String) Function() fallback;
  final double tickS;
  final double settleS;
  final double maxAgeS;

  bool _dirty = true;
  StatusInputs? _inputs;
  DateTime? _gatheredAt;
  (DateTime, int, int)? _minute;
  StatusContent? _last;
  Timer? _timer;

  StatusNotifier(
    this.gather,
    this.post, [
    (String, String) Function()? fallback,
    this.tickS = 5.0,
    this.settleS = 1.0,
    this.maxAgeS = 600.0,
  ]) : fallback = fallback ?? (() => ('Strakaláři', ''));

  /// The data or the settings changed: recompute soon.
  void poke() => _dirty = true;

  /// Recomputes now and returns the content (counted as delivered: for
  /// the caller that hands it over itself, e.g. when starting the service).
  /// Null while [gather] says the notification isn't shown.
  StatusContent? current([DateTime? now]) {
    final content = _compute(now ?? clock.now(), force: true);
    if (content != null) _last = content;
    return content;
  }

  /// Recomputes when due and posts a change. True when something was posted.
  bool tick([DateTime? now]) {
    now = now ?? clock.now();
    final minute = (_dayOnly(now), now.hour, now.minute);
    if (!_dirty && _minute == minute && _inputs != null) return false;
    final content = _compute(now);
    if (content == null || content == _last) return false;
    if (!post(content)) return false;
    _last = content;
    return true;
  }

  StatusContent? _compute(DateTime now, {bool force = false}) {
    final stale =
        _gatheredAt == null ||
        _dayOnly(_gatheredAt!) != _dayOnly(now) ||
        now.difference(_gatheredAt!).abs().inSeconds >= maxAgeS;
    if (force || _dirty || stale || _inputs == null) {
      _dirty = false; // a poke while gathering marks it dirty again
      try {
        _inputs = gather();
      } catch (_) {
        _dirty = true; // try again on the next tick
        rethrow;
      }
      _gatheredAt = now;
    }
    _minute = (_dayOnly(now), now.hour, now.minute);
    if (_inputs == null) {
      _last = null; // shown again later: post it afresh
      return null;
    }
    return buildStatus(_inputs!, now: now, fallback: fallback());
  }

  /// Whether the periodic loop runs.
  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(Duration(milliseconds: (tickS * 1000).round()), (
      _,
    ) {
      try {
        tick();
      } catch (e) {
        // Never let the loop die.
        // ignore: avoid_print
        print(
          'Warning: background notification update failed '
          '(${e.runtimeType}: $e)',
        );
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
