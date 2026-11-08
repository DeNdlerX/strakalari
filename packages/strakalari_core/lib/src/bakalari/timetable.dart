// Bakaláři timetable: weekly views and the stable ("Stálý") timetable.
//
// Port of strakalari/core/bakalari_timetable.py. A mixin of
// [BakalariClient]; it uses the client's session state.
import 'dart:convert';

import 'package:clock/clock.dart';

import '../storage/helpers.dart';
import '../automation/cancel.dart';
import 'client.dart';
import 'common.dart';
import 'extractors.dart';

/// A permanent-view atom's IdentCode has a blank date part
/// ("1       003T2RD…"); an actual week's carries the date ("12026092103T2RD…").
final _permIdentRe = RegExp(r'^\S {4}');

/// True when timetable [details] are the permanent ("Stálý") view.
///
/// Every lesson with an IdentCode must have the blank date part; one
/// dated IdentCode means an actual week came back instead.
bool isPermView(Object? details) {
  var perm = 0;
  if (details is! List) return false;
  for (final detail in details) {
    final code = detail is Map ? '${detail['IdentCode'] ?? ''}' : '';
    if (code.isEmpty) continue;
    if (!_permIdentRe.hasMatch(code)) return false;
    perm += 1;
  }
  return perm > 0;
}

String _day(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.${day.year}';

String _dayMonth(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.';

String _isoDay(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Mixin of [BakalariClientBase]; uses its session state.
mixin TimetableMixin on BakalariClientBase {
  /// Lesson details of one timetable view (`cal` = the week of [day],
  /// `perm` = the stable timetable), as the timetable page loads them.
  Future<List<Map<String, Object?>>> timetableView(
      String term, DateTime day) async {
    final content = await bakalariSession().json(
      'POST',
      '/Timetable/GetContentData',
      headers: {'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode({
        'term': term,
        'date': _isoDay(day),
        'selectedClassId': '',
      })),
    );
    return timetableDetails(content);
  }

  /// Loads the regular week window plus the history weeks into
  /// [timetableSources] (one detail list per loaded week).
  Future<void> fetchTimetableWeeks() async {
    await login();
    final today = clock.now();
    final currentWeek = DateTime(today.year, today.month, today.day);
    final offsets = weekOffsets(goBackWeeks, goForwardWeeks);
    // Timetable history: older school-year weeks the cache still lacks
    // (all of them on the first run, none afterwards). Fetched after
    // the regular window so a slow backfill never delays fresh data.
    final thisMonday = currentWeek
        .subtract(Duration(days: currentWeek.weekday - 1));
    final extra = historyWeeks.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final monday in extra) {
      final off =
          monday.difference(thisMonday).inDays ~/ 7;
      if (off < 0 && !offsets.contains(off)) offsets.add(off);
    }
    timetableLoadedWeeks = {};
    if (offsets.isEmpty) {
      log('Warning: no timetable weeks to fetch '
          '(go_back_weeks=0, go_forward_weeks=0).');
    }
    for (final off in offsets) {
      raiseIfCancelledNow();
      final weekDate =
          currentWeek.add(Duration(days: off * 7));
      final monday = weekDate
          .subtract(Duration(days: weekDate.weekday - 1));
      final details = await timetableView('cal', monday);
      final shown = detailDays(details);
      final targetDays = {
        for (var i = 0; i < 7; i++)
          monday.add(Duration(days: i))
      };
      if (shown.isNotEmpty &&
          shown.intersection(targetDays).isEmpty) {
        // Another week came back: storing it would silently skip
        // this week. The cache merge keeps its previously known days.
        final days = shown.toList()..sort();
        log('Warning: week of ${_day(monday)} did not load (got '
            '${_dayMonth(days.first)}–${_dayMonth(days.last)}), '
            'skipping it this run.');
        continue;
      }
      timetableSources.add(details);
      timetableLoadedWeeks.add(monday);
    }
  }

  /// Merges timetable details into [timetableData] (or [target] —
  /// the stable view parses into its own dict), grouped per day.
  void addTimetableDetails(
    List<Object?>? details, {
    Map<String, Object?>? target,
    int dropped = 0,
  }) {
    final results = <Map<String, Object?>>[];
    var droppedIncomplete = 0;
    for (final detail in details ?? <Object?>[]) {
      final hourToAdd = parseTimetableDetail(detail);
      if (hourToAdd == null) {
        droppedIncomplete += 1;
        continue;
      }
      if (!results.any((r) => jsonEquals(r, hourToAdd))) {
        results.add(hourToAdd);
      }
    }

    final unsorted = <String, List<Map<String, Object?>>>{};
    for (final result in results) {
      final dateKey = result['date'];
      if (dateKey == null || '$dateKey'.isEmpty) {
        droppedIncomplete += 1;
        continue;
      }
      unsorted.putIfAbsent('$dateKey', () => []).add(result);
    }
    if (dropped > 0 || droppedIncomplete > 0) {
      log('Warning: timetable parse dropped $dropped malformed + '
          '$droppedIncomplete dateless/incomplete rows '
          '(format may have changed).');
    }

    final dest = target ?? timetableData;
    for (final entry in unsorted.entries) {
      final day = entry.key;
      final lessons = entry.value;
      dest.putIfAbsent(day, () => []);
      final dayLessons = (dest[day] as List).cast<Map<String, Object?>>();
      for (final lesson in _sortedLessons(lessons)) {
        if (!dayLessons.any((l) => jsonEquals(l, lesson))) {
          dayLessons.add(lesson);
        }
      }
    }
  }

  /// Loads the 'Stálý rozvrh' view into [stableTimetableData].
  ///
  /// Returns true when the stable view came back with lessons; false
  /// when it failed or another view came back (the run then has no
  /// stable baseline). Never raises except on user cancel.
  Future<bool> extractStableTimetable() async {
    raiseIfCancelledNow();
    stableTimetableData = {};
    late final List<Map<String, Object?>> details;
    try {
      final now = clock.now();
      details = await timetableView(
          'perm', DateTime(now.year, now.month, now.day));
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Warning: stable timetable request failed ($e) — '
          'no stable timetable this run.');
      return false;
    }
    // The perm view still carries this week's dates — only IdentCode
    // tells it apart from an actual week (blank date part).
    if (!isPermView(details)) {
      log('Warning: stable timetable view did not load — '
          'no stable timetable this run.');
      return false;
    }
    addTimetableDetails(details, target: stableTimetableData);
    final nLessons = stableTimetableData.values
        .fold<int>(0, (sum, lessons) => sum + (lessons as List).length);
    if (nLessons == 0) {
      log('Warning: no stable lessons parsed — '
          'no stable timetable this run.');
      return false;
    }
    log('Stable timetable loaded: $nLessons lessons '
        'in ${stableTimetableData.length} days.');
    return true;
  }
}

List<Map<String, Object?>> _sortedLessons(
    List<Map<String, Object?>> lessons) {
  int sortKey(Map<String, Object?> item) {
    int? num;
    try {
      num = extractLessonNum('${item['time'] ?? ''}');
    } on Object {
      num = null;
    }
    num ??= _coercePeriod(item['period']);
    return num ?? 999;
  }

  return lessons.toList()..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
}

int? _coercePeriod(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is bool) return value ? 1 : 0;
  return int.tryParse('$value'.trim());
}
