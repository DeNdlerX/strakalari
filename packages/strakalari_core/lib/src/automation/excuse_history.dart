// Already-excused history: normalization, coverage checks, safe writes.
//
// Port of strakalari/core/excuse_history.py. The history file
// (`already_excused_lessons.json`) lists every excuse that was sent —
// locally or, via the Komens outbox sync, from the web.
//
// Duplicate detection is *coverage*, not equality: an absence is already
// excused when every one of its lessons falls inside some history entry.
//
// Every read-check-send-write sequence runs under [HistoryLock] (a
// re-entrant in-process guard + a lock file shared with the tray
// process), so two senders can neither excuse the same absence twice nor
// lose each other's history entries. (Python uses a thread RLock; Dart
// runs one event loop per isolate, so a plain counter is enough.)
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import '../models.dart';
import '../storage/helpers.dart';

/// Keys stored for an excuse (UI extras stripped).
const List<String> storedKeys = [
  'type',
  'starting_day',
  'ending_day',
  'starting_lesson',
  'ending_lesson'
];

/// Only absences this recent are ever excused. Komens → Odeslané lists the
/// last month of sent messages by default, so older excuses cannot be
/// checked for duplicates — older absences are history, not tasks.
const int excuseWindowDays = 30;

/// Hour-based excuse shapes (late arrival, early leave, short absence).
/// Bakaláři renders all three as the same hour-range message.
const List<String> hourTypes = ['income', 'soon', 'days and hours'];

/// Submits whose outcome the site never confirmed (the click may have gone
/// out, then the page stalled). Kept apart from the history — they may not
/// have been sent — but they block every re-send until the Komens outbox
/// settles them: a second excuse cannot be taken back.
const String unconfirmedSuffix = '.unconfirmed.json';

/// How long an unconfirmed submit must be absent from a successfully read
/// outbox before it counts as "not sent" and may be sent again.
const Duration unconfirmedMinAge = Duration(minutes: 5);

DateTime? _day(Object? value) {
  if (value == null) return null;
  if (value is String && value.trim().isEmpty) return null;
  return parseCzDate(value);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtDay(DateTime day) =>
    '${_two(day.day)}.${_two(day.month)}.${day.year}';

/// Canonicalizes excuse day strings to zero-padded `DD.MM.YYYY`.
Map<String, Object?> normalizeHistoryItem(Map<String, Object?>? item) {
  final copy = Map<String, Object?>.of(item ?? <String, Object?>{});
  for (final key in ['starting_day', 'ending_day']) {
    final parsed = _day(copy[key]);
    if (parsed != null) copy[key] = _fmtDay(parsed);
  }
  return copy;
}

/// Only the storable keys of an excuse (UI extras stripped).
Map<String, Object?> baseExcuse(Map<String, Object?>? excuse) {
  final out = <String, Object?>{};
  for (final entry in (excuse ?? <String, Object?>{}).entries) {
    if (storedKeys.contains(entry.key)) out[entry.key] = entry.value;
  }
  return out;
}

/// First day an absence may still be excused.
///
/// [outboxFrom] is the start of the range Odeslané actually showed;
/// when it is later than the default month, the narrower range wins.
DateTime excuseWindowStart(DateTime today, [DateTime? outboxFrom]) {
  final start = addDays(today, -excuseWindowDays);
  if (outboxFrom != null &&
      start.isBefore(outboxFrom) &&
      !today.isBefore(outboxFrom)) {
    return DateTime(outboxFrom.year, outboxFrom.month, outboxFrom.day);
  }
  return DateTime(start.year, start.month, start.day);
}

/// History rows recording one sent excuse.
///
/// An hour-based excuse is stored in all three shapes, locally exactly
/// as the web sync stores it, so both sides always agree.
List<Map<String, Object?>> historyEntries(
    Map<String, Object?>? excuse) {
  final entry = baseExcuse(normalizeHistoryItem(excuse));
  if (!hourTypes.contains('${entry['type'] ?? ''}'.toLowerCase())) {
    return [entry];
  }
  return [
    for (final kind in hourTypes) {...entry, 'type': kind}
  ];
}

/// Treats any map as a string-keyed JSON object (null otherwise).
Map<String, Object?>? _asStrMap(Object? item) => item is Map
    ? item.map((k, v) => MapEntry('$k', v as Object?))
    : null;

/// Deep equality for JSON-shaped values (Dart maps compare by identity).
bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Merges web-scraped sent excuses into a history list.
///
/// Both sides are normalized before comparing, so a web excuse never
/// duplicates a local entry written in another spelling. Returns
/// `(merged, addedCount)`. Pure — never raises.
(List<Object?>, int) mergeSentExcuses(
    List<Object?>? history, List<Object?>? discovered) {
  final merged = <Object?>[];
  for (final item in history ?? <Object?>[]) {
    final m = _asStrMap(item);
    merged.add(m == null ? item : baseExcuse(normalizeHistoryItem(m)));
  }
  var added = 0;
  for (final item in discovered ?? <Object?>[]) {
    final m = _asStrMap(item);
    if (m == null) continue;
    final entry = baseExcuse(normalizeHistoryItem(m));
    if (!merged.any((m) => _jsonEquals(m, entry))) {
      merged.add(entry);
      added += 1;
    }
  }
  return (merged, added);
}

int? _lesson(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is String) return int.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

/// True when one history entry covers [lesson] (null = whole day) on [day].
bool covers(Map<String, Object?> entry, DateTime day, int? lesson) {
  final start = _day(entry['starting_day']);
  final end = _day(entry['ending_day']) ?? start;
  if (start == null ||
      end == null ||
      day.isBefore(start) ||
      day.isAfter(end)) {
    return false;
  }
  if ('${entry['type'] ?? ''}'.toLowerCase() == 'pure days') return true;
  final first = _lesson(entry['starting_lesson']);
  final last = _lesson(entry['ending_lesson']);
  if (first == null || last == null) return false;
  if (start.isBefore(day) && day.isBefore(end)) {
    return true; // middle day of a multi-day hour range
  }
  if (lesson == null) {
    return false; // a partial range never covers a whole day
  }
  if (start == end) return first <= lesson && lesson <= last;
  if (day == start) return lesson >= first;
  return lesson <= last;
}

/// Every lesson/day point an excuse claims (empty = unparseable).
List<(DateTime, int?)> _excusePoints(Map<String, Object?> excuse) {
  final start = _day(excuse['starting_day']);
  final end = _day(excuse['ending_day']) ?? start;
  if (start == null || end == null || end.isBefore(start)) {
    return [];
  }
  if ('${excuse['type'] ?? ''}'.toLowerCase() == 'pure days') {
    final days = <(DateTime, int?)>[];
    var cursor = start;
    while (!cursor.isAfter(end) && days.length < 366) {
      days.add((cursor, null));
      cursor = addDays(cursor, 1);
    }
    return days;
  }
  final first = _lesson(excuse['starting_lesson']);
  final last = _lesson(excuse['ending_lesson']);
  if (first == null || last == null || start != end) return [];
  final top = first > last ? first : last;
  return [for (var l = first; l <= top; l++) (start, l)];
}

/// True when every lesson/day of [excuse] is inside the history.
///
/// Unparseable excuses are never covered (fail toward sending, the
/// caller's exact-match fallback still applies).
bool excuseCovered(
    Map<String, Object?> excuse, List<Object?>? history) {
  final entries = (history ?? <Object?>[])
      .map(_asStrMap)
      .whereType<Map<String, Object?>>()
      .toList();
  final wanted = baseExcuse(normalizeHistoryItem(excuse));
  if (entries.any((h) =>
      _jsonEquals(baseExcuse(normalizeHistoryItem(h)), wanted))) {
    return true;
  }
  final points = _excusePoints(excuse);
  if (points.isEmpty) return false;
  return points.every(
      (p) => entries.any((h) => covers(h, p.$1, p.$2)));
}

/// Sidecar file next to the history (`…lessons.unconfirmed.json`).
String unconfirmedPath(String historyPath) {
  final base = historyPath.toLowerCase().endsWith('.json')
      ? historyPath.substring(0, historyPath.length - 5)
      : historyPath;
  return '$base$unconfirmedSuffix';
}

/// Unconfirmed submits. Missing file = none; unreadable raises.
///
/// A corrupt file is quarantined and read as empty (its rows only ever
/// block sends, so losing them is the fail-open the history also has).
List<Map<String, Object?>> loadUnconfirmed(String historyPath,
    [Encoding encoding = utf8]) {
  final path = unconfirmedPath(historyPath);
  if (!File(path).existsSync()) return [];
  final data = jsonDecode(File(path).readAsStringSync(encoding: encoding));
  if (data is! List) return [];
  return data
      .map(_asStrMap)
      .whereType<Map<String, Object?>>()
      .toList();
}

/// Writes the sidecar atomically; an empty list removes the file.
void saveUnconfirmed(String historyPath, List<Object?> entries,
    [Encoding encoding = utf8]) {
  final path = unconfirmedPath(historyPath);
  if (entries.isEmpty) {
    if (File(path).existsSync()) File(path).deleteSync();
    return;
  }
  atomicWriteJson(path, entries, encoding: encoding);
}

/// One sidecar row: the storable excuse plus when it was submitted.
Map<String, Object?> unconfirmedEntry(Map<String, Object?> excuse,
    [DateTime? now]) {
  final entry = baseExcuse(normalizeHistoryItem(excuse));
  final at = now ?? clock.now();
  entry['submitted_at'] =
      '${at.year}-${_two(at.month)}-${_two(at.day)}T'
      '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}';
  return entry;
}

DateTime? _submittedAt(Map<String, Object?> entry) =>
    DateTime.tryParse('${entry['submitted_at']}');

/// True when [excuse] overlaps any unconfirmed submit.
///
/// Overlap, not coverage: re-sending even part of a maybe-sent excuse
/// would duplicate that part. Unparseable excuses fall back to equality.
bool unconfirmedBlocks(
    Map<String, Object?> excuse, List<Object?>? unconfirmed) {
  final entries = (unconfirmed ?? <Object?>[])
      .map(_asStrMap)
      .whereType<Map<String, Object?>>()
      .map(baseExcuse)
      .toList();
  if (entries.isEmpty) return false;
  if (entries.any((e) => _jsonEquals(
      e, baseExcuse(normalizeHistoryItem(excuse))))) {
    return true;
  }
  return _excusePoints(excuse).any(
      (p) => entries.any((e) => covers(e, p.$1, p.$2)));
}

/// Settles unconfirmed submits against a *successfully read* outbox.
///
/// Call only after the outbox was actually read (the web sync merged it
/// into [history]). Returns `(stillOpen, confirmed, notSent)`:
/// confirmed = the history now covers it (it was sent); notSent = older
/// than [unconfirmedMinAge], submitted inside the range the outbox showed,
/// and still absent (it never arrived); stillOpen = everything else.
(
  List<Map<String, Object?>>,
  List<Map<String, Object?>>,
  List<Map<String, Object?>>
) resolveUnconfirmed(
    List<Object?>? unconfirmed, List<Object?>? history,
    DateTime? outboxFrom, [DateTime? now]) {
  final at = now ?? clock.now();
  final stillOpen = <Map<String, Object?>>[];
  final confirmed = <Map<String, Object?>>[];
  final notSent = <Map<String, Object?>>[];
  for (final raw in unconfirmed ?? <Object?>[]) {
    final item = _asStrMap(raw);
    if (item == null) continue;
    if (excuseCovered(item, history)) {
      confirmed.add(item);
      continue;
    }
    final submitted = _submittedAt(item);
    final submittedDay = submitted == null
        ? null
        : DateTime(submitted.year, submitted.month, submitted.day);
    final inRange = submitted != null &&
        (outboxFrom == null ||
            (submittedDay != null && !submittedDay.isBefore(DateTime(
                outboxFrom.year, outboxFrom.month, outboxFrom.day))));
    if (submitted != null &&
        inRange &&
        at.difference(submitted) >= unconfirmedMinAge) {
      notSent.add(item);
    } else {
      stillOpen.add(item);
    }
  }
  return (stillOpen, confirmed, notSent);
}

/// True when a single lesson task (day + period) is already excused.
bool taskCovered(DateTime day, int? period, List<Object?>? history) {
  return (history ?? <Object?>[])
      .map(_asStrMap)
      .whereType<Map<String, Object?>>()
      .where((h) =>
          period != null ||
          '${h['type'] ?? ''}'.toLowerCase() == 'pure days')
      .any((h) => covers(h, day, period));
}

/// Serializes history read-check-send-write sequences.
///
/// Yields (returns) true when the lock is held, false when another
/// process kept it for [timeoutS] (callers must then not send). Stale
/// lock files from killed processes are reclaimed after 15 minutes.
class HistoryLock {
  static final Map<String, int> _depths = {};

  final String historyPath;
  String? _token;
  bool _outer = false;

  HistoryLock(this.historyPath);

  /// True once held; false when still busy after [timeoutS].
  bool acquire({double timeoutS = 600.0}) {
    if ((_depths[historyPath] ?? 0) > 0) {
      // Re-entrant within one isolate: the outer holder has the file.
      _depths[historyPath] = _depths[historyPath]! + 1;
      return true;
    }
    final deadline = DateTime.now()
        .add(Duration(microseconds: (timeoutS * 1e6).round()));
    String? token;
    while (true) {
      token =
          tryFileLock('$historyPath.lock', staleAfterS: 900.0);
      if (token != null || !DateTime.now().isBefore(deadline)) break;
      sleep(const Duration(milliseconds: 500));
    }
    if (token != null) {
      _depths[historyPath] = 1;
      _token = token;
      _outer = true;
      return true;
    }
    return false;
  }

  /// Releases a lock acquired with [acquire].
  void release() {
    if (!_outer && (_depths[historyPath] ?? 0) > 0) {
      _depths[historyPath] = _depths[historyPath]! - 1;
      return;
    }
    _depths[historyPath] = 0;
    _outer = false;
    releaseFileLock(_token);
    _token = null;
  }
}
