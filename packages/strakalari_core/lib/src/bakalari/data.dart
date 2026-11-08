// Bakaláři data fetching: marks, absence, sent excuses, subjects,
// substitutions, stable baseline.
//
// Port of strakalari/core/bakalari_data.py. A mixin of [BakalariClientBase];
// uses its session state.
import 'dart:convert';

import 'package:clock/clock.dart';

import '../automation/cancel.dart';
import '../models.dart';
import '../planning/schedule.dart' show
    LessonDiff,
    applySubstitutionFeed,
    backfillStableFacts,
    baselineFromStableTimetable,
    iterChanges;
import '../storage/helpers.dart';
import 'client.dart';
import 'extractors.dart';
import 'http_session.dart';

/// Komens → Odeslané (the menu's own link), its list callback control and
/// the list type the page reports for the sent folder.
const String _outboxPath = '/next/komens.aspx?l=o';
const String _outboxCallbackId =
    'ctl00\$cphmain\$message_list_content';
const String _outboxListType = 'odeslane';

/// Local [day] + [hour]:[minute] as the UTC ISO string the web's scripts send.
String utcIso(DateTime day, {int hour = 0, int minute = 0}) {
  final utc =
      DateTime(day.year, day.month, day.day, hour, minute).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}T'
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.000Z';
}

/// Mixin of [BakalariClientBase]; uses its session state.
mixin DataMixin on BakalariClientBase {
  /// Fetches průběžná klasifikace (Klasifikace → Průběžná).
  ///
  /// Parses the `data-clasif` marks of the grades page and stores them
  /// on [grades] grouped per subject, each list sorted by date
  /// (oldest first). Returns the dict. Best-effort: failures only log +
  /// set [gradesError] (mirroring absence handling) so one changed
  /// page never breaks the whole Bakaláři run. Only raises on user cancel.
  Future<Map<String, List<Map<String, Object?>>>> getGrades() async {
    raiseIfCancelledNow();
    try {
      final html =
          await bakalariSession().getHtml('/next/prubzna.aspx');
      final found = extractGrades(html);
      grades = found;
      // Same page: each subject row also carries its quarterly mark.
      quarterlyMarks = extractQuarterlyMarks(html);
      if (found.isNotEmpty) {
        gradesError = '';
        final nMarks =
            found.values.fold<int>(0, (sum, v) => sum + v.length);
        log('Grades synced: $nMarks marks in ${found.length} subjects.');
      } else {
        log('Warning: no grades parsed — '
            'either no marks recorded or the page format changed.');
        // An empty parse of something that is not the grades page
        // (error page, changed URL) must not wipe the last good cache.
        gradesError = html.contains('prubzna.aspx')
            ? ''
            : 'grades page did not load (empty parse)';
      }
      return found;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      gradesError = truncateRunes('${e.runtimeType}: $e'.split('\n').first, 200);
      log('Could not obtain grades: $e — showing no marks, not stale data.');
      // Never serve previous marks as fresh: callers treat an empty
      // dict as a failed sync (the refresh keeps the last good cache).
      grades = {};
      quarterlyMarks = {};
      return {};
    }
  }

  /// Fetches the absence overview (Absence → Continuous).
  Future<void> obtainAbsenceInfo() async {
    raiseIfCancelledNow();
    try {
      final session = bakalariSession();
      final page = await session.getHtml('/Absence/Continuous');
      final dates = absenceDateRange(page);
      if (dates == null) {
        throw StateError(
            'absence page without its date range (format changed?)');
      }
      final rows = await session.json(
        'GET',
        '/Absence/Continuous/GetAbsenceBySubjects',
        queryParams: {
          'dateFrom': dates.$1,
          'dateTo': dates.$2,
          'lateChecked': 'false',
          'schoolChecked': 'false',
          'soonChecked': 'false',
        },
      );
      if (storeRows(rows) == null) {
        // A failed load, not "no absence": the refresh keeps the cache.
        throw StateError('absence reply without rows (format changed?)');
      }
      final (percentages, details) = absenceFromSubjects(rows);
      absencePercentages = percentages;
      absenceDetails =
          details.map((k, v) => MapEntry(k, v as Object?));
      absenceError = '';
      if (percentages.isEmpty) {
        log('Warning: no absence percentages parsed — '
            'either no absence recorded or the format changed.');
      }

      var warnPct = _toDouble(config['absence_warn_pct'] ?? 15.0) ?? 15.0;
      var critPct = _toDouble(config['absence_critical_pct'] ?? 25.0) ?? 25.0;
      if (!(warnPct > 0 && warnPct < critPct && critPct <= 100)) {
        warnPct = 15.0;
        critPct = 25.0;
      }

      for (final entry in percentages.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value >= 0.0 && value <= warnPct) {
          log('Recommendation: Skip the $key lessons! '
              'Your absence is only $value%!');
        } else if (value < critPct) {
          log('Recommendation: Watch the $key lessons, your absence '
              '($value%) is approaching the $critPct% limit!');
        } else if (value >= critPct) {
          log('Recommendation: You should probably attend the $key lessons '
              'more, your absence is $value%!');
        }
      }
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      absenceError =
          truncateRunes('${e.runtimeType}: $e'.split('\n').first, 200);
      log('Could not obtain absence info: $e — '
          'showing no data, not stale values.');
      // Never serve previous percentages as fresh: callers treat an
      // empty dict as a failed sync (the refresh keeps the last good
      // cache instead of overwriting it).
      absencePercentages = {};
      absenceDetails = {};
    }
  }

  /// Reads already-sent excuses (Komens → Odeslané → OMLUVENKA).
  ///
  /// Loads the outbox list the way the page does (its DevExpress list
  /// callback), then each excuse's detail (Od/Do dates + optional
  /// lessons), and stores the history-shaped entries on [sentExcuses].
  /// Returns them.
  ///
  /// Tri-state: a list (possibly empty) = the outbox was actually read
  /// (empty genuinely means "nothing sent"); null = the sync failed or
  /// was skipped, i.e. unknown — callers must treat it as "nothing
  /// learned", never as "nothing sent". Never raises except on user
  /// cancel. [sentExcusesError] carries the last failure.
  Future<List<Map<String, Object?>>?> fetchSentExcuses(
      {int limit = 100}) async {
    raiseIfCancelledNow();
    var capped = limit;
    try {
      if (capped < 1) capped = 1;
    } on Object {
      capped = 100;
    }
    try {
      final session = bakalariSession();
      final (page, ids) =
          await fetchOutboxIds(session, capped + 1);
      sentExcusesFrom = _outboxPeriodStart(page);
      if (ids.isEmpty) {
        log('No sent excuses (OMLUVENKA) found in Komens → Odeslané.');
        sentExcuses = [];
        sentExcusesError = '';
        return [];
      }
      var wanted = ids;
      if (ids.length > capped) {
        log('Sent excuses: ${ids.length} on the web, '
            'reading first $capped.');
        wanted = ids.sublist(0, capped);
      } else {
        log('Komens → Odeslané: ${ids.length} excuse(s) on the web.');
      }

      final parsed = <Map<String, Object?>>[];
      var read = 0;
      for (final msgId in wanted) {
        raiseIfCancelledNow();
        late final Object? detail;
        try {
          detail = await fetchOutboxDetail(session, msgId);
        } on CancelledError {
          rethrow;
        } on Object catch (e) {
          log('Warning: could not read sent excuse $msgId: $e');
          continue;
        }
        read += 1;
        for (final entry in sentExcuseEntries(detail)) {
          if (!parsed.any((p) => jsonEquals(p, entry))) {
            parsed.add(entry);
          }
        }
      }

      if (read == 0) {
        // Not one detail readable: [] must not read as "nothing
        // sent" — report unknown (null) so callers keep the last
        // known state.
        sentExcuses = null;
        sentExcusesError = 'outbox details unreadable';
        log('Warning: sent-excuse details unreadable — '
            'keeping last known state.');
        return null;
      }
      sentExcuses = parsed;
      sentExcusesError = '';
      if (parsed.length != read) {
        // One hour-based web message expands to three history
        // entries (income + soon + days and hours) for dedupe —
        // report the web message count so the log never claims more
        // sent messages than the outbox actually holds.
        log('Sent excuses synced from the web: $read message(s) '
            '(${parsed.length} history entries).');
      } else {
        log('Sent excuses synced from the web: $read message(s).');
      }
      return parsed;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      sentExcusesError =
          truncateRunes('${e.runtimeType}: $e'.split('\n').first, 200);
      log('Could not sync sent excuses: $e — will retry next time.');
      return null;
    }
  }

  /// `(pageHtml, ids)`: Komens → Odeslané and the message ids of its
  /// excuse rows, loaded the way the page does (its list callback).
  Future<(String, List<String>)> fetchOutboxIds(
      BakalariSession session, int pageSize) async {
    final page = await session.getHtml(_outboxPath);
    final listType = RegExp('id="hfListType"[^>]*?value="([^"]*)"')
        .firstMatch(page);
    if (listType == null || listType.group(1) != _outboxListType) {
      // Another folder read as the outbox would report "nothing sent".
      throw StateError(
          'Komens page is not the sent folder (format changed?)');
    }
    final param = jsonEncode({
      'showRepressed': false,
      'pageNumber': 1,
      'pageSize': pageSize,
      'reloadMessages': true,
      'sortOrder': 0,
      'onlyRating': true,
      'onlyExcuses': true,
      'onlySystemMessages': true,
      'onlyGeneralMessages': true,
      'onlyUnread': false,
    });
    final listing = await session.dxCallback(
        _outboxPath, page, _outboxCallbackId, param);
    if (!listing.contains('komens-messages-wrapper')) {
      throw StateError('outbox list did not load (format changed?)');
    }
    return (page, outboxExcuseIds(listing));
  }

  /// The detail of one sent message (`/Komens/GetMessageDataAsync`).
  static Future<Object?> fetchOutboxDetail(
      BakalariSession session, String msgId) {
    return session.json(
      'POST',
      '/Komens/GetMessageDataAsync',
      jsonBody: {'idmsg': msgId, 'komensMessageListType': _outboxListType},
    );
  }

  /// First day of the period Odeslané lists ("26.8.2026 - 25.9.2026"), or null.
  DateTime? _outboxPeriodStart(String pageHtml) {
    final label = RegExp('id="cphmain_obdobiLabel"[^>]*>([^<]*)<')
        .firstMatch(pageHtml);
    if (label == null) return null;
    final found = RegExp(r'\d{1,2}\s*\.\s*\d{1,2}\s*\.\s*\d{4}')
        .allMatches(label.group(1)!)
        .map((m) => m.group(0)!)
        .toList();
    if (found.isEmpty) return null;
    try {
      final start =
          parseCzDate(found.first.replaceAll(RegExp(r'\s+'), ''));
      if (start != null) {
        log('Komens → Odeslané lists ${label.group(1)!.trim()}.');
      }
      return start;
    } on Object {
      return null;
    }
  }

  /// Fetches the school-official subject directory (Výuka → Přehled předmětů).
  ///
  /// Only the subject names are used downstream (the canonical
  /// absence-tracked set); teachers ride along for display. Returns the
  /// dict (possibly empty). Best-effort: failures only log, mirroring
  /// the grades handling. Only raises on user cancel.
  Future<Map<String, String>> fetchSubjectDirectory() async {
    raiseIfCancelledNow();
    try {
      final rows = await bakalariSession().json(
        'POST',
        '/Teaching/Subjects',
        headers: {'X-Requested-With': 'XMLHttpRequest'},
      );
      final directory = subjectDirectoryFromRows(rows);
      subjectDirectory = directory;
      if (directory.isNotEmpty) {
        log('Subject directory synced: ${directory.length} subjects.');
      } else {
        log('Warning: no subjects parsed from the directory.');
      }
      return directory;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Could not sync subject directory: $e — continuing without it.');
      // Unknown, not stale: clear so consumers fall back to the last
      // good cache instead of treating old rows as freshly fetched.
      subjectDirectory = {};
      return {};
    }
  }

  /// Reads the personal substitution feed (Výuka → Suplování).
  ///
  /// Same range as the page shows by default: from today's week to the
  /// week 14 days ahead. Returns the parsed feed entries (possibly empty
  /// = genuinely no changes) or null when the sync failed (unknown —
  /// callers must not treat it as no changes). Only raises on user
  /// cancel. Best-effort: failures only log + set substitutions_error.
  Future<List<Map<String, Object?>>?> fetchSubstitutions() async {
    raiseIfCancelledNow();
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = addDays(today, -(today.weekday - 1));
    final endDay = addDays(today, 14);
    final end = addDays(addDays(endDay, -(endDay.weekday - 1)), 4);
    try {
      final post = formBody([
        ('dateFrom', utcIso(start)),
        ('dateTo', utcIso(end)),
      ]);
      final weeks = await bakalariSession().json(
        'POST',
        '/Timetable/substitutions/dates',
        headers: post.headers,
        body: post.body,
      );
      final entries = substitutionsFromWeeks(weeks);
      substitutions = entries;
      substitutionsError = '';
      log('Substitution feed synced: ${entries.length} entries.');
      return entries;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      substitutionsError =
          truncateRunes('${e.runtimeType}: $e'.split('\n').first, 200);
      log('Could not sync substitution feed: $e — will retry next time.');
      return null;
    }
  }

  /// Builds the stable baseline and diffs the loaded weeks against it.
  ///
  /// Port of `bakalari_data.update_stable_baseline`. The baseline comes
  /// only from the scraped "Stálý rozvrh" view ([stableTimetableData]):
  /// when that scrape failed there is no baseline at all. Stores the
  /// baseline on [stableBaseline] and the diffs on [weekChanges], logs a
  /// short summary, and returns the baseline. Never raises.
  Map<Object, Object?> updateStableBaseline() {
    Map<Object, Object?> baseline = {};
    if (stableTimetableData.isNotEmpty) {
      try {
        baseline = baselineFromStableTimetable(stableTimetableData);
      } on Object catch (e) {
        log('Warning: could not use the stable timetable: $e');
        baseline = {};
      }
    }
    final usedScraped = baseline.isNotEmpty;
    const source = 'stable timetable (Stálý rozvrh)';
    if (baseline.isEmpty) {
      log("No stable timetable this run — changes come from Bakaláři's own flags.");
    }
    stableBaseline = baseline;
    // The scraped template week is complete: an empty slot is a free
    // period, so added/missing lessons are real changes.
    stableComplete = usedScraped;
    try {
      final feed = substitutions;
      if (feed != null && feed.isNotEmpty) {
        final stamped = applySubstitutionFeed(timetableData, feed);
        if (stamped > 0) {
          log('Substitution feed stamped $stamped lesson(s).');
        }
      }
    } on Object catch (e) {
      log('Warning: could not apply substitution feed: $e');
    }
    try {
      final matched = backfillStableFacts(timetableData, baseline);
      if (matched > 0) {
        log('Stable: $matched cancelled lesson(s) matched to stable slots.');
      }
    } on Object catch (e) {
      log('Warning: could not match cancelled lessons to stable: $e');
    }
    try {
      weekChanges = iterChanges(timetableData, baseline, usedScraped);
    } on Object catch (e) {
      log('Warning: could not compare weeks against stable: $e');
      weekChanges = [];
    }
    if (baseline.isNotEmpty) {
      log('Stable timetable: ${baseline.length} slots ($source).');
    }
    if (weekChanges.isNotEmpty) {
      log('Schedule changes vs stable: ${weekChanges.length}.');
      for (final item in weekChanges.take(5)) {
        try {
          if (item is! Map) continue;
          final lesson = item['lesson'];
          final diff = item['diff'];
          final fields = diff is LessonDiff ? diff.changed.join(', ') : '';
          final subject =
              lesson is Map ? '${lesson['subject'] ?? '?'}' : '?';
          final dayKey = '${item['day_key'] ?? '?'}';
          final note = diff is LessonDiff ? diff.note : '';
          var detail = '$subject $dayKey [$fields]'.trim();
          if (note.isNotEmpty) detail += ': $note';
          log('  Change: $detail');
        } on Object {
          continue;
        }
      }
      if (weekChanges.length > 5) {
        log('  … and ${weekChanges.length - 5} more.');
      }
    } else {
      log('No schedule changes vs stable.');
    }
    return stableBaseline;
  }
}

double? _toDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value == null) return null;
  return double.tryParse('$value'.trim());
}
