// Bakaláři parsing helpers shared by the client mixins.
//
// Port of strakalari/core/bakalari_common.py.
import '../models.dart';
import '../storage/helpers.dart';

/// Splits `"Zrušeno (FG, Dušek Filip)"` into (subject, teacher).
///
/// Cancelled lessons carry no teacher/subject/room keys — only this
/// human-readable string. Anything unparseable yields ("", "") and the
/// stable baseline fills the facts in later. Never raises.
(String, String) _splitRemovedInfo(Object? removedinfo) {
  try {
    final text = '${removedinfo ?? ''}';
    final start = text.indexOf('(');
    final end = text.lastIndexOf(')');
    final inner =
        (start >= 0 && start < end) ? text.substring(start + 1, end) : '';
    if (inner.contains(',')) {
      final cut = inner.indexOf(',');
      return (
        inner.substring(0, cut).trim(),
        inner.substring(cut + 1).trim()
      );
    }
    return (inner.trim(), '');
  } on Object {
    return ('', '');
  }
}

/// Raw `hourIndex` as int, or null when missing/unparseable.
int? _hourIndex(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is bool) return value ? 1 : 0;
  return int.tryParse('$value'.trim());
}

/// Converts one `data-detail` JSON blob into a lesson dict.
///
/// Returns null for rows with no usable content. `type == "removed"`
/// rows (cancelled lessons, e.g. `"Zrušeno (FG, Dušek Filip)"`) carry
/// no teacher/subject/room keys — they become `status="cancelled"`
/// lessons instead of being dropped. Bakalari change signals
/// (`changeinfo` / `infoChangeCode` / `changeBadgeChar` /
/// `hourIndex`) are carried through so classification can trust them
/// instead of guessing from the teacher notice alone.
Map<String, Object?>? parseTimetableDetail(Object? detail) {
  if (detail is! Map) return null;
  Object? at(Object? key) => detail[key];
  String strOf(Object? key1, [Object? key2, Object? key3]) =>
      '${at(key1) ?? (key2 == null ? '' : at(key2)) ?? (key3 == null ? '' : at(key3)) ?? ''}'
          .trim();

  final changeinfo = strOf('changeinfo', 'ChangeInfo');
  final infoCode = strOf('infoChangeCode', 'InfoChangeCode');
  final badge = '${at('changeBadgeChar') ?? ''}'.trim();
  final removedinfo = strOf('removedinfo', 'RemovedInfo');
  final absentinfo = strOf('absentinfo', 'AbsentInfo');
  var notice = strOf('notice', 'Notice');
  if (notice.isEmpty) notice = strOf('change', 'Change');
  if (notice.isEmpty) {
    // Room/substitution moves (badge "M") put the explanation in
    // changeinfo ("Změna místnosti: II (I)") with an empty notice.
    notice = changeinfo;
  }
  final hourIndex = _hourIndex(at('hourIndex') ?? at('HourIndex'));
  final timeText = at('time') ?? at('Time');

  if (absentinfo.isNotEmpty && '${at('teacher') ?? ''}'.isEmpty) {
    // Class absence: a school event replaces the lesson (absentinfo
    // "B", removedinfo "beseda / přednáška / workshop") and arrives
    // with no type/teacher/subject. The event name stands in for the
    // subject until backfill_stable_facts fills in the stable lesson;
    // it shows as a change, never as cancelled (see is_class_event).
    if (removedinfo.isEmpty) return null;
    return {
      'teacher': '',
      'subject': removedinfo,
      'subject_short': '',
      'room': '',
      'group': '',
      'theme': '',
      'notice': removedinfo,
      'date': at('day') ?? at('Day'),
      'time': timeText,
      'absencetext': '',
      'absenceType': '',
      'type': 'event',
      'changeinfo': changeinfo,
      'infoChangeCode': infoCode,
      'changeBadgeChar': badge,
      'hourIndex': hourIndex,
    };
  }

  if ('${at('type') ?? 'atom'}'.trim().toLowerCase() == 'removed') {
    if (removedinfo.isEmpty && notice.isEmpty) return null;
    final (subject, teacher) = _splitRemovedInfo(
        removedinfo.isNotEmpty ? removedinfo : notice);
    return {
      'teacher': teacher,
      'subject': subject,
      'subject_short': subject,
      'room': '',
      'group': '',
      'theme': '',
      'notice': removedinfo.isNotEmpty ? removedinfo : notice,
      'change': removedinfo.isNotEmpty ? removedinfo : notice,
      'date': at('day') ?? at('Day'),
      'time': timeText,
      'absencetext': '',
      'absenceType': '',
      'status': 'cancelled',
      'type': 'removed',
      'removedinfo': removedinfo,
      'changeinfo': changeinfo,
      'infoChangeCode': infoCode,
      'changeBadgeChar': badge,
      'hourIndex': hourIndex,
    };
  }

  final teacher = at('teacher');
  final subject = at('subjecttext') ?? at('SubjectName');
  if (teacher == null ||
      '$teacher'.trim().isEmpty ||
      '$teacher'.trim() == 'None') {
    return null;
  }
  if (subject == null ||
      '$subject'.trim().isEmpty ||
      '$subject'.trim() == 'None') {
    return null;
  }

  int? period;
  try {
    period = extractLessonNum(timeText);
  } on Object {
    period = null;
  }
  if (period == null && hourIndex != null) {
    // Verified against real pages: hourIndex = period + 2 on every
    // row (period 1 <-> 3, ..., period 9 <-> 11). Only periods >= 1
    // are inferred — hourIndex 2 (candidate 0) is not an observed
    // mapping and must stay unknown instead of inventing period 0.
    final candidate = hourIndex - 2;
    if (candidate >= 1 && candidate <= 15) period = candidate;
  }
  final lesson = <String, Object?>{
    'teacher': '$teacher'.trim(),
    'subject': '$subject'.trim(),
    'subject_short': strOf('subjectshort', 'SubjectShort'),
    'room': shortRoomName(
        '${at('room') ?? at('roomtext') ?? at('RoomName') ?? ''}'.trim()),
    'group': strOf('group', 'grouptext', 'GroupName'),
    'theme': strOf('theme', 'Theme'),
    'notice': notice,
    'date': at('day') ?? at('Day'),
    'time': timeText,
    'absencetext': at('absencetext'),
    'absenceType': at('absenceType'),
    'changeinfo': changeinfo,
    'infoChangeCode': infoCode,
    'changeBadgeChar': badge,
    'hourIndex': hourIndex,
  };
  if (period != null) lesson['period'] = period;
  return lesson;
}

/// Dates of every lesson in a list of timetable details. Never raises.
Set<DateTime> detailDays(Object? details) {
  final days = <DateTime>{};
  if (details is! List) return days;
  for (final detail in details) {
    try {
      if (detail is! Map) continue;
      final day =
          parseCzDate(detail['day'] ?? detail['Day']);
      if (day != null) days.add(day);
    } on Object {
      continue;
    }
  }
  return days;
}

/// Newest-first week offsets for the timetable fetch loop.
///
/// `goBackWeeks` counts the current week (`0`) plus past weeks,
/// `goForwardWeeks` adds future weeks on top. E.g. back=4, forward=1
/// yields `[+1, 0, -1, -2, -3]` — next week first, then today backwards.
/// Total weeks fetched = back + forward.
List<int> weekOffsets(Object? goBackWeeks, Object? goForwardWeeks) {
  int back;
  try {
    back = _coerceInt(goBackWeeks);
  } on Object {
    back = 0;
  }
  int forward;
  try {
    forward = _coerceInt(goForwardWeeks);
  } on Object {
    forward = 0;
  }
  if (back < 0) back = 0;
  if (forward < 0) forward = 0;
  return [for (var i = forward; i > -back; i--) i];
}

int _coerceInt(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) throw const FormatException();
    return value.truncate();
  }
  if (value is bool) return value ? 1 : 0;
  final parsed = int.tryParse('${value ?? ''}'.trim());
  if (parsed == null) throw const FormatException();
  return parsed;
}
