// The phone's morning brief: on every school day at a set time, a regular
// notification with an overview of the day.
//
// It is made of the rows of the always-on notification
// (status_notification.dart: the next lesson, the lunch, open lunch orders,
// excuses to send, the wake-up alarm, the update time), picked on their own
// (``morning_brief_items``) and worked out for the moment the brief comes,
// so "next lesson" is the day's first one and "lunch" today's.
//
// Like the wake-up alarms (wakeup.dart), the briefs of the next two weeks
// are a plan the phone carries out without Dart: [syncMorningBrief] hands
// the queue to ``BriefReceiver``, which posts each brief at its time and
// arms the next one. Every refresh hands over a new queue, so a brief shows
// the data of the last refresh before it.
//
// A school day is one the school calendar doesn't free, with a lesson that
// isn't cancelled (the cached weeks; past them the stable timetable).
import 'dart:convert';

import 'package:clock/clock.dart';

import 'i18n.dart';
import 'planning/school_presets.dart';
import 'status_notification.dart';
import 'storage/helpers.dart';
import 'wakeup.dart' show indexDays, isCancelledLesson, lessonsFor;

/// Default ``morning_brief_time``.
const String defaultBriefTime = '06:30';

/// What the brief shows on a new install (``morning_brief_items``).
const List<String> defaultBriefItems = [
  'next_lesson',
  'lunch',
  'lunch_orders',
  'excuses',
];

/// Days ahead the queue covers (the phone posts them without the app).
const int briefHorizonDays = 14;

/// A brief the phone could not post on time (it was off) is dropped once
/// this much later.
const Duration briefStaleAfter = Duration(hours: 2);

final RegExp _timeRe = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*$');

/// [raw] ("6:30", "06:30") as (hour, minute); null when it isn't a time of
/// day.
(int, int)? parseBriefTime(Object? raw) {
  final m = _timeRe.firstMatch('${raw ?? ''}');
  if (m == null) return null;
  final hour = int.parse(m.group(1)!);
  final minute = int.parse(m.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return (hour, minute);
}

/// ``morning_brief_time`` as stored: "06:30".
String formatBriefTime(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

/// The brief's time of day (the default when the stored one is unusable).
(int, int) briefTimeOf(Map<String, Object?>? config) =>
    parseBriefTime((config ?? {})['morning_brief_time']) ??
    parseBriefTime(defaultBriefTime)!;

/// Whether the morning brief is on.
bool briefEnabled(Map<String, Object?>? config) =>
    (config ?? {})['morning_brief_enabled'] == true;

/// The items the brief shows, in display order (unknown ids dropped).
List<String> selectedBriefItems(Map<String, Object?>? config) {
  final raw = (config ?? {})['morning_brief_items'] ?? defaultBriefItems;
  if (raw is! List) return List.of(defaultBriefItems);
  final picked = {for (final item in raw) '$item'};
  return [
    for (final item in items)
      if (picked.contains(item)) item,
  ];
}

/// ``morning_brief_items`` with [item] switched on or off.
List<String> withBriefItem(
  Map<String, Object?>? config,
  String item,
  bool on,
) {
  final picked = selectedBriefItems(config).toSet();
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

/// One brief: when it comes and what it says.
class MorningBrief {
  final DateTime at;
  final StatusContent content;

  const MorningBrief(this.at, this.content);
}

/// The brief for [at]: the picked rows worked out for that moment, the
/// brief's name in the header (with the update time and the account when
/// shown). Null when no row has anything to say.
StatusContent? buildBrief(StatusInputs inputs, DateTime at, {String? lang}) {
  lang = (lang ?? getLanguage()) == 'en' ? 'en' : 'cs';
  final status = buildStatus(
    inputs,
    now: at,
    lang: lang,
    picked: selectedBriefItems(inputs.config),
  );
  if (status.rows.isEmpty) return null;
  final title = t('brief_title', lang: lang);
  return StatusContent(
    title,
    [for (final row in status.rows) row.line].join('\n'),
    [title, status.sub].where((s) => s.isNotEmpty).join(' · '),
    status.rows,
  );
}

/// The briefs after [since] (default: now) up to [horizonDays] ahead,
/// earliest first: one per school day at ``morning_brief_time``, unless it
/// has nothing to say. Empty while the brief is off.
List<MorningBrief> upcomingMorningBriefs(
  StatusInputs inputs, {
  DateTime? since,
  String? lang,
  int horizonDays = briefHorizonDays,
}) {
  if (!briefEnabled(inputs.config)) return [];
  since = since ?? clock.now();
  final (hour, minute) = briefTimeOf(inputs.config);
  final freeDays = _freeDays(inputs);
  final days = indexDays(inputs.timetable);
  final today = DateTime(since.year, since.month, since.day);
  final out = <MorningBrief>[];
  for (var ahead = 0; ahead <= horizonDays; ahead++) {
    final day = addDays(today, ahead);
    final at = DateTime(day.year, day.month, day.day, hour, minute);
    if (!at.isAfter(since) || freeDays.contains(day)) continue;
    final lessons = lessonsFor(days, day, inputs.stableBaseline);
    if (!lessons.any((raw) => !isCancelledLesson(raw, day))) continue;
    try {
      final content = buildBrief(inputs, at, lang: lang);
      if (content != null) out.add(MorningBrief(at, content));
    } catch (e) {
      // One broken day must not drop the others.
      // ignore: avoid_print
      print('Warning: morning brief for $day failed (${e.runtimeType}: $e)');
    }
  }
  return out;
}

Set<DateTime> _freeDays(StatusInputs inputs) {
  if (inputs.freeDays != null) return inputs.freeDays!;
  try {
    return effectiveCalendar(inputs.config, clip: false).dates;
  } catch (_) {
    // A broken calendar must not stop the brief.
    return {};
  }
}

/// What ``BriefReceiver`` posts: epoch ms (when, dropped after) and the
/// texts and rows of the notification.
List<Map<String, Object?>> briefQueue(List<MorningBrief> briefs) => [
  for (final brief in briefs)
    {
      'at': brief.at.millisecondsSinceEpoch,
      'until': brief.at.add(briefStaleAfter).millisecondsSinceEpoch,
      'title': brief.content.title,
      'text': brief.content.text,
      'sub': brief.content.sub,
      'rows': brief.content.rowsJson(),
    },
];

// -- hand-over to the phone --------------------------------------------------

/// Phone-side handler for the brief queue (the app's platform channel;
/// null elsewhere).
abstract interface class MorningBriefPhoneBridge {
  bool setMorningBriefs(String queueJson, String channelName);
}

/// The bridge the app registered at startup (null off the phone).
MorningBriefPhoneBridge? morningBriefPhoneBridge;

/// What the phone was last given (only changes are sent again).
String? _sent;

/// Test hook: forget what the phone was last given.
void resetMorningBriefSyncState() => _sent = null;

/// Hands the brief queue to the phone; a no-op elsewhere. [inputs]: the
/// data the always-on notification shows its overview from, null while the
/// brief is off (an empty queue: nothing more is posted).
///
/// The queue keeps a brief whose time has just passed (until
/// [briefStaleAfter]): a brief the phone delivers late must not drop out
/// when a refresh hands over a new queue meanwhile. The phone posts each
/// brief once and never arms one that was due before it got it.
void syncMorningBrief(StatusInputs? inputs, {DateTime? now}) {
  final bridge = morningBriefPhoneBridge;
  if (bridge == null) return;
  now = now ?? clock.now();
  final lang = getLanguage() == 'en' ? 'en' : 'cs';
  try {
    final briefs = inputs == null
        ? <MorningBrief>[]
        : upcomingMorningBriefs(
            inputs,
            since: now.subtract(briefStaleAfter),
            lang: lang,
          );
    final queue = jsonEncode(briefQueue(briefs));
    if (_sent != lang + queue &&
        bridge.setMorningBriefs(queue, t('brief_title', lang: lang))) {
      _sent = lang + queue;
    }
  } catch (e) {
    // ignore: avoid_print
    print('Warning: morning brief sync failed (${e.runtimeType}: $e)');
  }
}
