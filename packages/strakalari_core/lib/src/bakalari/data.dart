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
    baselineFromDict,
    baselineFromStableTimetable,
    baselineToDict,
    iterChanges;
import '../storage/helpers.dart';
import 'client.dart';
import 'extractors.dart';
import 'timetable.dart';
import 'http_session.dart';

/// Komens → Odeslané (the menu's own link), its list callback control and
/// the list type the page reports for the sent folder.
const String _outboxPath = '/next/komens.aspx?l=o';
const String _outboxYearPath = '/next/komens.aspx?s=rok&l=o';
const String _outboxCallbackId =
    'ctl00\$cphmain\$message_list_content';
const String _outboxListType = 'odeslane';
const int defaultOutboxPageSize = 100;
const int maxOutboxPages = 50;

/// Local [day] + [hour]:[minute] as the UTC ISO string the web's scripts send.
String utcIso(DateTime day, {int hour = 0, int minute = 0}) {
  final utc =
      DateTime(day.year, day.month, day.day, hour, minute).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}T'
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.000Z';
}

/// Mixin of [BakalariClientBase]; uses its session state.
mixin DataMixin on BakalariClientBase, TimetableMixin {
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

  /// Fetches the lightweight recent-marks dashboard widget (`GET /Marks/Widget`,
  /// ~2 KB) used as the 5-minute marks change signal (F6 §5.1).
  ///
  /// Tri-state: non-null list (possibly empty) on valid parse, `null` on HTTP
  /// error or changed markup (logged loudly). Only raises on user cancel.
  Future<List<Map<String, Object?>>?> fetchMarksWidget() async {
    raiseIfCancelledNow();
    try {
      final html = await bakalariSession().getHtml('/Marks/Widget');
      final parsed = extractMarksWidget(html);
      if (parsed == null) {
        log('Warning: /Marks/Widget reply missing bk-widget-marks '
            '(format changed?).');
      }
      marksWidget = parsed;
      return parsed;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Warning: /Marks/Widget failed ($e).');
      marksWidget = null;
      return null;
    }
  }

  /// Fetches the absence overview (Absence → Continuous).
  ///
  /// Computes the school-year date range locally (`1 September -> today`,
  /// F6 §4.2) and calls `GetAbsenceBySubjects` directly without loading the
  /// 58 KB HTML page, falling back loudly to `/Absence/Continuous` once if
  /// the direct call fails, returns invalid rows, or returns zero subjects
  /// while [cachedHasSubjects] is true.
  Future<void> obtainAbsenceInfo({
    bool allowPageFallback = true,
    bool cachedHasSubjects = false,
    bool quiet = false,
  }) async {
    raiseIfCancelledNow();
    absenceDirectFailed = false;
    try {
      final session = bakalariSession();
      final now = clock.now();
      final today = DateTime(now.year, now.month, now.day);
      final startYear = today.month >= 9 ? today.year : today.year - 1;
      String two(int n) => n.toString().padLeft(2, '0');
      final dateFrom = '$startYear-09-01';
      final dateTo = '${today.year}-${two(today.month)}-${two(today.day)}';

      Object? rows;
      try {
        rows = await session.json(
          'GET',
          '/Absence/Continuous/GetAbsenceBySubjects',
          queryParams: {
            'dateFrom': dateFrom,
            'dateTo': dateTo,
            'lateChecked': 'false',
            'schoolChecked': 'false',
            'soonChecked': 'false',
          },
        );
        if (storeRows(rows) == null) {
          throw StateError('absence reply without rows (format changed?)');
        }
        if (cachedHasSubjects) {
          final (pcts, _) = absenceFromSubjects(rows);
          if (pcts.isEmpty) {
            throw StateError(
                'direct absence reply had no subjects while cache had some');
          }
        }
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        absenceDirectFailed = true;
        if (!allowPageFallback) rethrow;
        log('Warning: direct GetAbsenceBySubjects failed ($e); '
            'falling back to /Absence/Continuous');
        final page = await session.getHtml('/Absence/Continuous');
        final dates = absenceDateRange(page);
        if (dates == null) {
          throw StateError(
              'absence page without its date range (format changed?)');
        }
        rows = await session.json(
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

      if (!quiet) {
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
  /// Loads the whole school-year period (`?s=rok&l=o`) and walks every page
  /// of its DevExpress list callback, then reads each newly seen excuse's
  /// detail (reusing [knownOutboxDetails] for already cached keys) and stores
  /// the history-shaped entries on [sentExcuses]. Any page or detail failure
  /// aborts the read (never partial success). When [limit] > 0 is exceeded,
  /// reads only the newest [limit] excuses and narrows [sentExcusesFrom] to
  /// the sent date of the oldest among them, or to the day after the newest
  /// excuse left out if that is later (a cut inside a day leaves that day
  /// partly unread). Fails closed when either row has no `data-sortdate` or
  /// that start would be after today; 0 = unlimited.
  ///
  /// Tri-state: a list (possibly empty) = the outbox was actually read
  /// (empty genuinely means "nothing sent"); null = the sync failed or
  /// was skipped, i.e. unknown — callers must treat it as "nothing
  /// learned", never as "nothing sent". Never raises except on user
  /// cancel. [sentExcusesError] carries the last failure.
  Future<List<Map<String, Object?>>?> fetchSentExcuses({
    int limit = 0,
    bool useCachedForm = false,
  }) async {
    raiseIfCancelledNow();
    outboxDetailsUpdated = false;
    outboxFormUpdated = false;
    sentExcusesFrom = null;
    final capped = limit < 0 ? 0 : limit;
    try {
      final session = bakalariSession();
      final listing = await _fetchAllOutboxIdsInternal(
        session,
        useCachedForm: useCachedForm,
      );
      final ids = listing.ids;
      final cacheKeys = listing.cacheKeys;
      final periodStart = listing.periodStart;
      if (ids.isEmpty) {
        log('No sent excuses (OMLUVENKA) found in Komens → Odeslané.');
        sentExcusesFrom = periodStart;
        knownOutboxDetails = {};
        outboxDetailsUpdated = true;
        if (listing.freshForm != null) {
          knownOutboxForm = listing.freshForm;
          outboxFormUpdated = true;
        }
        sentExcuses = [];
        sentExcusesError = '';
        return [];
      }
      var effectiveFrom = periodStart;
      var idsToRead = ids;
      if (capped > 0 && ids.length > capped) {
        idsToRead = ids.sublist(0, capped);
        DateTime? sentDay(String id) {
          final key = cacheKeys[id] ?? id;
          final sep = key.indexOf('|');
          return sep >= 0 ? parseOutboxSortDate(key.substring(sep + 1)) : null;
        }

        final oldestDay = sentDay(idsToRead.last);
        // The newest excuse left out: its day may hold more unread
        // excuses, so only the days after it are read completely.
        final unreadDay = sentDay(ids[capped]);
        if (oldestDay == null || unreadDay == null) {
          sentExcuses = null;
          sentExcusesError =
              'outbox has ${ids.length} excuses (limit $capped)';
          log('Warning: Komens → Odeslané has ${ids.length} excuses, '
              'exceeding sent_excuses_limit ($capped), and the $capped-th '
              'or ${capped + 1}-th excuse has no sent date — treating read '
              'as incomplete (set sent_excuses_limit to 0 for no limit).');
          return null;
        }
        final afterUnread =
            DateTime(unreadDay.year, unreadDay.month, unreadDay.day + 1);
        final bound = afterUnread.isAfter(oldestDay) ? afterUnread : oldestDay;
        final now = clock.now();
        if (bound.isAfter(DateTime(now.year, now.month, now.day))) {
          sentExcuses = null;
          sentExcusesError =
              'outbox has ${ids.length} excuses (limit $capped)';
          log('Warning: Komens → Odeslané has ${ids.length} excuses, '
              'exceeding sent_excuses_limit ($capped), and the cut falls on '
              'today — treating read as incomplete (set sent_excuses_limit '
              'to 0 for no limit).');
          return null;
        }
        if (effectiveFrom == null || bound.isAfter(effectiveFrom)) {
          effectiveFrom = bound;
        }
        String two(int n) => n.toString().padLeft(2, '0');
        final boundStr =
            '${two(effectiveFrom.day)}.${two(effectiveFrom.month)}.${effectiveFrom.year}';
        log('Komens → Odeslané has ${ids.length} excuse(s), reading the '
            'newest $capped (excuse window starts $boundStr; set '
            'sent_excuses_limit to 0 for no limit).');
      } else {
        log('Komens → Odeslané: ${ids.length} excuse(s) on the web.');
      }

      final parsed = <Map<String, Object?>>[];
      final nextCache = <String, List<Map<String, Object?>>>{};
      var reused = 0;
      var fetched = 0;
      for (final msgId in idsToRead) {
        raiseIfCancelledNow();
        final key = cacheKeys[msgId] ?? msgId;
        final cached = knownOutboxDetails[key];
        late final List<Map<String, Object?>> entries;
        if (cached != null && cached.isNotEmpty) {
          entries = [for (final e in cached) Map<String, Object?>.of(e)];
          reused += 1;
        } else {
          final detail = await fetchOutboxDetail(session, msgId);
          entries = sentExcuseEntries(detail);
          fetched += 1;
        }
        if (entries.isNotEmpty) {
          nextCache[key] = [
            for (final e in entries) Map<String, Object?>.of(e),
          ];
        }
        for (final entry in entries) {
          if (!parsed.any((p) => jsonEquals(p, entry))) {
            parsed.add(entry);
          }
        }
      }

      sentExcusesFrom = effectiveFrom;
      knownOutboxDetails = nextCache;
      outboxDetailsUpdated = true;
      if (listing.freshForm != null) {
        knownOutboxForm = listing.freshForm;
        outboxFormUpdated = true;
      }
      sentExcuses = parsed;
      sentExcusesError = '';
      final cacheNote = reused > 0 ? ', $reused cached' : '';
      if (parsed.length != idsToRead.length) {
        // One hour-based web message expands to three history
        // entries (income + soon + days and hours) for dedupe —
        // report the web message count so the log never claims more
        // sent messages than the outbox actually holds.
        log('Sent excuses synced from the web: ${idsToRead.length} message(s) '
            '(${parsed.length} history entries; $fetched read$cacheNote).');
      } else {
        log('Sent excuses synced from the web: ${idsToRead.length} message(s) '
            '($fetched read$cacheNote).');
      }
      return parsed;
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      sentExcuses = null;
      sentExcusesFrom = null;
      sentExcusesError =
          truncateRunes('${e.runtimeType}: $e'.split('\n').first, 200);
      log('Could not sync sent excuses: $e — will retry next time.');
      return null;
    }
  }

  /// `(pageHtml, ids)`: Komens → Odeslané and the message ids of its
  /// excuse rows, loaded the way the page does (its list callback).
  Future<(String, List<String>)> fetchOutboxIds(
      BakalariSession session, int pageSize,
      {String path = _outboxPath}) async {
    final page = await session.getHtml(path);
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
        path, page, _outboxCallbackId, param);
    if (!listing.contains('komens-messages-wrapper')) {
      throw StateError('outbox list did not load (format changed?)');
    }
    final ids = outboxExcuseIds(listing);
    final bounds = _outboxPeriodBounds(page);
    if (outboxMessageIds(listing).isNotEmpty &&
        ids.isEmpty &&
        _hasKnownInPeriodExcuse(bounds?.$1, bounds?.$2)) {
      throw StateError(
          'outbox returned message rows but 0 excuses while cached '
          'in-period excuses exist (format changed?)');
    }
    return (page, ids);
  }

  /// `(pageHtml, excuseIds, cacheKeys)`: Komens → Odeslané and every
  /// excuse message id across all cumulative callback pages of [path].
  ///
  /// When [useCachedForm] is true and [knownOutboxForm] holds a valid,
  /// in-period, < 7-day-old 3-field snapshot, skips the 207 KB page load
  /// and runs the completeness check against [knownOutboxDetails] (F6 §4.4,
  /// R8a M1). Any page-1 error or missing known excuse reloads the full page.
  Future<(String, List<String>, Map<String, String>)> fetchAllOutboxIds(
    BakalariSession session, {
    String path = _outboxYearPath,
    int? pageSize,
    int maxPages = maxOutboxPages,
    bool useCachedForm = false,
  }) async {
    final res = await _fetchAllOutboxIdsInternal(
      session,
      path: path,
      pageSize: pageSize,
      maxPages: maxPages,
      useCachedForm: useCachedForm,
    );
    return (res.pageHtml ?? '', res.ids, res.cacheKeys);
  }

  Future<
      ({
        String? pageHtml,
        List<String> ids,
        Map<String, String> cacheKeys,
        DateTime? periodStart,
        Map<String, Object?>? freshForm,
      })> _fetchAllOutboxIdsInternal(
    BakalariSession session, {
    String path = _outboxYearPath,
    int? pageSize,
    int maxPages = maxOutboxPages,
    bool useCachedForm = false,
  }) async {
    final requestedSize = pageSize ?? outboxPageSize;
    final size = requestedSize < 1 ? defaultOutboxPageSize : requestedSize;

    Future<(List<String>, Map<String, String>, int)> pageWith(
      Future<String> Function(String param, int pageNumber) runCallback, {
      required void Function(int pageNumber) onPageStart,
    }) async {
      final seenAllIds = <String>{};
      final excuseIds = <String>[];
      final cacheKeys = <String, String>{};

      for (var pageNumber = 1;; pageNumber++) {
        raiseIfCancelledNow();
        onPageStart(pageNumber);
        final param = jsonEncode({
          'showRepressed': false,
          'pageNumber': pageNumber,
          'pageSize': size,
          'reloadMessages': pageNumber == 1,
          'sortOrder': 0,
          'onlyRating': true,
          'onlyExcuses': true,
          'onlySystemMessages': true,
          'onlyGeneralMessages': true,
          'onlyUnread': false,
        });
        final listing = await runCallback(param, pageNumber);
        if (!listing.contains('komens-messages-wrapper')) {
          throw StateError('outbox list did not load (format changed?)');
        }
        final allIds = outboxMessageIds(listing);
        if (pageNumber > 1) {
          final pageIdSet = allIds.toSet();
          if (!pageIdSet.containsAll(seenAllIds)) {
            throw StateError(
                'outbox page $pageNumber is not cumulative (missing previous ids)');
          }
        }
        var newCount = 0;
        for (final id in allIds) {
          if (seenAllIds.add(id)) newCount += 1;
        }
        if (pageNumber > 1 && newCount == 0) {
          if (_outboxReplyMarksEnd(listing)) break;
          throw StateError(
              'outbox paging made no progress at page $pageNumber');
        }
        for (final id in outboxExcuseIds(listing)) {
          if (!excuseIds.contains(id)) excuseIds.add(id);
        }
        for (final entry in outboxExcuseCacheKeys(listing).entries) {
          cacheKeys.putIfAbsent(entry.key, () => entry.value);
        }
        if (allIds.length < pageNumber * size) {
          break;
        }
        if (pageNumber >= maxPages) {
          throw StateError(
              'outbox exceeded $maxPages pages without reaching the end');
        }
      }
      return (excuseIds, cacheKeys, seenAllIds.length);
    }

    // Attempt cached 3-field callback when allowed and valid (F6 §4.4, R8a M1/S6).
    final cached = useCachedForm ? _usableCachedOutboxForm(path) : null;
    if (cached != null) {
      var currentPage = 0;
      String? rejectReason;
      List<String>? cachedIds;
      Map<String, String>? cachedKeys;
      try {
        final (ids, keys, totalRows) = await pageWith(
          (param, _) => session.dxCallbackFields(
            path,
            cached.fields,
            _outboxCallbackId,
            param,
          ),
          onPageStart: (p) => currentPage = p,
        );
        final missing = _checkCachedOutboxCompleteness(
          ids,
          cached.periodStart,
          cached.periodEnd,
        );
        if (missing != null) {
          rejectReason = missing;
        } else if (totalRows > 0 &&
            ids.isEmpty &&
            _hasKnownInPeriodExcuse(cached.periodStart, cached.periodEnd)) {
          rejectReason =
              'cached reply listed $totalRows message(s) but 0 excuses';
        } else {
          cachedIds = ids;
          cachedKeys = keys;
        }
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        if (currentPage <= 1) {
          rejectReason = '$e';
        } else {
          // Page 2+ failure aborts the entire read (no partial success).
          rethrow;
        }
      }
      if (cachedIds != null && cachedKeys != null) {
        return (
          pageHtml: null,
          ids: cachedIds,
          cacheKeys: cachedKeys,
          periodStart: cached.periodStart,
          freshForm: null,
        );
      }
      log('Komens cached form fields rejected ($rejectReason); '
          'reloading outbox page');
      knownOutboxForm = null;
    }

    // Full-page path (F2).
    final page = await session.getHtml(path);
    final listType = RegExp('id="hfListType"[^>]*?value="([^"]*)"')
        .firstMatch(page);
    if (listType == null || listType.group(1) != _outboxListType) {
      // Another folder read as the outbox would report "nothing sent".
      throw StateError(
          'Komens page is not the sent folder (format changed?)');
    }
    final (ids, cacheKeys, totalRows) = await pageWith(
      (param, _) => session.dxCallback(path, page, _outboxCallbackId, param),
      onPageStart: (_) {},
    );
    final bounds = _outboxPeriodBounds(page);
    if (totalRows > 0 &&
        ids.isEmpty &&
        _hasKnownInPeriodExcuse(bounds?.$1, bounds?.$2)) {
      throw StateError(
          'outbox listed $totalRows message(s) but 0 excuses while cached '
          'in-period excuses exist (format changed?)');
    }
    final freshForm = _extractOutboxFormFields(
      page,
      path,
      bounds?.$1,
      bounds?.$2,
    );
    return (
      pageHtml: page,
      ids: ids,
      cacheKeys: cacheKeys,
      periodStart: bounds?.$1,
      freshForm: freshForm,
    );
  }

  /// Validates [knownOutboxForm] against F6 §4.4 & R8a S6 rules.
  ({
    List<(String, String)> fields,
    DateTime periodStart,
    DateTime periodEnd,
  })? _usableCachedOutboxForm(String path) {
    final form = knownOutboxForm;
    if (form == null) return null;
    if ('${form['path'] ?? ''}' != path) return null;
    final vs = '${form['viewstate'] ?? ''}'.trim();
    final vsg = '${form['viewstate_generator'] ?? ''}'.trim();
    final ev = '${form['event_validation'] ?? ''}'.trim();
    if (vs.isEmpty || vsg.isEmpty || ev.isEmpty) return null;

    final start = _parseStrictIsoDay('${form['period_start'] ?? ''}');
    final end = _parseStrictIsoDay('${form['period_end'] ?? ''}');
    if (start == null || end == null || end.isBefore(start)) return null;

    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    if (today.isBefore(start) || today.isAfter(end)) return null;

    final fetchedAt = DateTime.tryParse('${form['fetched_at'] ?? ''}'.trim());
    if (fetchedAt == null) return null;
    final age = now.difference(fetchedAt);
    if (age.isNegative || age >= const Duration(days: 7)) return null;

    return (
      fields: [
        ('__VIEWSTATE', vs),
        ('__VIEWSTATEGENERATOR', vsg),
        ('__EVENTVALIDATION', ev),
      ],
      periodStart: start,
      periodEnd: end,
    );
  }

  /// R8a M1 completeness check: every excuse already known in
  /// [knownOutboxDetails] whose `data-sortdate` falls inside
  /// `[periodStart, periodEnd]` must be present in [returnedExcuseIds].
  String? _checkCachedOutboxCompleteness(
    List<String> returnedExcuseIds,
    DateTime periodStart,
    DateTime periodEnd,
  ) {
    if (knownOutboxDetails.isEmpty) return null;
    final returned = returnedExcuseIds.toSet();
    for (final key in knownOutboxDetails.keys) {
      final sep = key.indexOf('|');
      if (sep <= 0) continue;
      final id = key.substring(0, sep);
      final sortStr = key.substring(sep + 1);
      final sortDay = parseOutboxSortDate(sortStr);
      if (sortDay == null) continue;
      if (!sortDay.isBefore(periodStart) && !sortDay.isAfter(periodEnd)) {
        if (!returned.contains(id)) {
          return 'known excuse $id ($sortStr) missing from cached reply';
        }
      }
    }
    return null;
  }

  /// True when [knownOutboxDetails] holds at least one cached excuse whose
  /// sent date (or absence start date when no sort date was cached) falls
  /// inside `[periodStart, periodEnd]`.
  bool _hasKnownInPeriodExcuse(DateTime? periodStart, DateTime? periodEnd) {
    if (knownOutboxDetails.isEmpty || periodStart == null) return false;
    bool inPeriod(DateTime day) =>
        !day.isBefore(periodStart) &&
        (periodEnd == null || !day.isAfter(periodEnd));
    for (final entry in knownOutboxDetails.entries) {
      final sep = entry.key.indexOf('|');
      if (sep > 0) {
        final sortDay = parseOutboxSortDate(entry.key.substring(sep + 1));
        if (sortDay != null) {
          if (inPeriod(sortDay)) return true;
          continue;
        }
      }
      for (final item in entry.value) {
        final day = parseCzDate('${item['starting_day'] ?? ''}');
        if (day != null && inPeriod(day)) return true;
      }
    }
    return false;
  }

  Map<String, Object?>? _extractOutboxFormFields(
    String pageHtml,
    String path,
    DateTime? periodStart,
    DateTime? periodEnd,
  ) {
    if (periodStart == null || periodEnd == null) return null;
    var vs = '';
    var vsg = '';
    var ev = '';
    for (final (name, value) in formFields(pageHtml)) {
      if (name == '__VIEWSTATE') vs = value;
      if (name == '__VIEWSTATEGENERATOR') vsg = value;
      if (name == '__EVENTVALIDATION') ev = value;
    }
    if (vs.isEmpty || vsg.isEmpty || ev.isEmpty) return null;
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    return {
      'path': path,
      'viewstate': vs,
      'viewstate_generator': vsg,
      'event_validation': ev,
      'period_start': iso(periodStart),
      'period_end': iso(periodEnd),
      'fetched_at': clock.now().toIso8601String(),
    };
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

  /// Period bounds `(start, end?)` of Odeslané's label ("20.8.2026 - 31.8.2027").
  (DateTime, DateTime?)? _outboxPeriodBounds(String pageHtml) {
    final label = RegExp('id="cphmain_obdobiLabel"[^>]*>([^<]*)<')
        .firstMatch(pageHtml);
    if (label == null) return null;
    final found = RegExp(r'\d{1,2}\s*\.\s*\d{1,2}\s*\.\s*\d{4}')
        .allMatches(label.group(1)!)
        .map((m) => m.group(0)!)
        .toList();
    if (found.isEmpty) return null;
    try {
      final start = parseCzDate(found.first.replaceAll(RegExp(r'\s+'), ''));
      if (start == null) return null;
      final end = found.length >= 2
          ? parseCzDate(found.last.replaceAll(RegExp(r'\s+'), ''))
          : null;
      log('Komens → Odeslané lists ${label.group(1)!.trim()}.');
      return (start, end);
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

  /// Full Bakaláři read: resets the per-run state, logs in, then loads
  /// absence → substitution feed → weeks → details → stable view → baseline →
  /// (optional marks widget) → grades → subject directory (F6 §4.3 fetch order).
  ///
  /// Optional flags allow scheduled full runs to skip already-fresh daily parts
  /// (permanent timetable, subject directory, past weeks) while keeping direct
  /// callers and existing tests identical by default.
  Future<Map<String, Object?>> fetchData({
    List<int>? weekOffsetsOverride,
    List<int>? Function(Map<String, Object?> freshAbsenceDetails, bool absenceOk)?
        resolveWeekOffsets,
    bool fetchStable = true,
    Map<String, Object?>? cachedStableBaseline,
    bool fetchSubjects = true,
    bool fetchMarks = true,
    bool fetchMarksWidget = false,
    bool cachedAbsenceHasSubjects = false,
  }) async {
    timetableSources = [];
    timetableData = {};
    absencePercentages = {};
    // Elapsed hours per subject from the same absence data.
    absenceDetails = {};
    // School-official subject set; empty until fetched.
    subjectDirectory = {};
    absenceError = '';
    grades = {};
    quarterlyMarks = {};
    gradesError = '';
    marksWidget = null;
    // sentExcuses is deliberately NOT reset: the outbox sync never runs
    // inside fetchData(), so clearing would report "nothing sent" for
    // state that is simply unknown.
    stableBaseline = {};
    stableComplete = false;
    weekChanges = [];
    stableTimetableData = {};
    // Tri-state like sentExcuses: null = unknown until the feed sync
    // below actually reads it (never [] = "no changes" by default).
    substitutions = null;
    substitutionsError = '';

    raiseIfCancelledNow();
    await login();
    // 1. Absence first (R8a S1): lets scheduled full runs decide whether a
    //    grown Count requires pulling past regular weeks in the same run.
    await obtainAbsenceInfo(cachedHasSubjects: cachedAbsenceHasSubjects);
    // 2. Substitution feed before weeks (R8a S4): ensures stored per-week
    //    hashes never describe a change the loaded week does not yet hold.
    try {
      await fetchSubstitutions();
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Warning: substitution feed failed ($e), continuing without it.');
      substitutions = null;
      final first = '$e'.split('\n').first;
      substitutionsError = '$e'.isEmpty
          ? 'failed'
          : (first.length > 200 ? first.substring(0, 200) : first);
    }
    // 3. Timetable weeks.
    final resolvedOffsets = resolveWeekOffsets != null
        ? resolveWeekOffsets(absenceDetails, absenceError.isEmpty)
        : weekOffsetsOverride;
    await fetchTimetableWeeks(weekOffsetsOverride: resolvedOffsets);
    for (final details in timetableSources) {
      if (details is List) {
        addTimetableDetails(details.cast<Object?>());
      }
    }
    // 4. Permanent timetable (`perm`, optional when already fetched today).
    if (fetchStable) {
      try {
        await extractStableTimetable();
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        log('Warning: stable timetable failed to load ($e), '
            'no stable timetable this run.');
      }
    }
    updateStableBaseline(
      cachedBaseline: !fetchStable ? cachedStableBaseline : null,
    );
    // 5. Marks widget BEFORE prubzna.aspx (R8a S3) so a mark given between the
    //    two requests can never be hidden until the next full run.
    if (fetchMarksWidget) {
      await this.fetchMarksWidget();
    }
    // 6. Průběžná klasifikace rides along; a changed grades page must never
    //    fail the run.
    if (fetchMarks) {
      try {
        await getGrades();
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        log('Warning: grades failed to load ($e), '
            'continuing without fresh grades.');
      }
    }
    // 7. Subject directory: an empty one just disables the tracked-subject
    //    filter downstream.
    if (fetchSubjects) {
      try {
        await fetchSubjectDirectory();
      } on CancelledError {
        rethrow;
      } on Object catch (e) {
        log('Warning: subject directory failed ($e), continuing without it.');
      }
    }
    final out = <String, Object?>{
      'timetable': timetableData,
      'absence': absencePercentages,
      if (fetchMarks) 'grades': grades,
      if (fetchMarks) 'quarterly_marks': quarterlyMarks,
      'changes': weekChanges,
      'substitutions': substitutions,
      'absence_details': absenceDetails,
      if (fetchSubjects) 'subject_directory': subjectDirectory,
    };
    if (fetchStable) {
      Map<String, Object?> serializableBaseline;
      try {
        serializableBaseline = baselineToDict(stableBaseline);
      } on Object {
        serializableBaseline = {};
      }
      out['stable_baseline'] = serializableBaseline;
      out['stable_baseline_source'] =
          serializableBaseline.isNotEmpty ? 'scraped' : '';
    }
    return out;
  }

  /// Builds the stable baseline and diffs the loaded weeks against it.
  ///
  /// Uses the freshly scraped "Stálý rozvrh" view ([stableTimetableData]) when
  /// present; when `perm` was skipped on purpose (F6 §4.3, R8a S5), uses
  /// [cachedBaseline] (previously scraped) with `stableComplete = true` so
  /// saved days match a full run identically. When `perm` was attempted and
  /// failed, [cachedBaseline] is null and there is no baseline this run.
  Map<Object, Object?> updateStableBaseline({
    Map<String, Object?>? cachedBaseline,
  }) {
    Map<Object, Object?> baseline = {};
    if (stableTimetableData.isNotEmpty) {
      try {
        baseline = baselineFromStableTimetable(stableTimetableData);
      } on Object catch (e) {
        log('Warning: could not use the stable timetable: $e');
        baseline = {};
      }
    } else if (cachedBaseline != null && cachedBaseline.isNotEmpty) {
      try {
        baseline = baselineFromDict(cachedBaseline);
      } on Object catch (e) {
        log('Warning: could not restore cached stable baseline: $e');
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

DateTime? _parseStrictIsoDay(String value) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final dt = DateTime(y, mo, d);
  if (dt.year != y || dt.month != mo || dt.day != d) return null;
  return dt;
}

String? _hiddenInputValue(String html, String id) {
  final tagRe = RegExp('<input\\b([^>]*)>', caseSensitive: false);
  final idRe = RegExp('\\bid=["\']([^"\']*)["\']', caseSensitive: false);
  final valRe = RegExp('\\bvalue=["\']([^"\']*)["\']', caseSensitive: false);
  for (final match in tagRe.allMatches(html)) {
    final attrs = match.group(1)!;
    final tagId = idRe.firstMatch(attrs)?.group(1);
    if (tagId == id || (tagId != null && tagId.endsWith('_$id'))) {
      return valRe.firstMatch(attrs)?.group(1) ?? '';
    }
  }
  return null;
}

bool _outboxReplyMarksEnd(String listing) {
  final allLoaded = _hiddenInputValue(listing, 'hfAllMessagesLoaded');
  if (allLoaded != null && allLoaded.trim().toLowerCase() == 'all') {
    return true;
  }
  final loadedCount = _hiddenInputValue(listing, 'hfLoadedMessagesCount');
  if (loadedCount != null && loadedCount.trim() == '0') {
    return true;
  }
  return false;
}
