// School calendar, absence forecast and planned skips.
//
// Port of strakalari/flet_ui/state_planner.py (`PlannerMixin`). Pure
// calendar/planning logic delegates to core (`forecast`, `planner`,
// `planned_skips`, `schedule`, `school_presets`); persistence rolls
// memory back on failure exactly like the original.
part of 'app_state.dart';

/// Planner logic. Port of `PlannerMixin`.
extension PlannerLogic on AppState {
  /// `(free-day dates, labels, info)` from preset + user deltas.
  ({Set<DateTime> dates, Map<DateTime, String> labels, Map<String, Object?> info})
      calendarData() {
    try {
      return effectiveCalendar(config.data);
    } catch (_) {
      return (
        dates: <DateTime>{},
        labels: <DateTime, String>{},
        info: <String, Object?>{
          'preset_id': '',
          'preset_days': 0,
          'user_added': 0,
          'forced_school': 0,
        },
      );
    }
  }

  List<String> effectiveHolidays() {
    final data = calendarData();
    final days = data.dates.toList()..sort();
    return [for (final d in days) fmtDay(d)];
  }

  /// Resolved absence-closure date (user value, else preset, else '').
  String semClose(String which) {
    try {
      return resolveClose(which, config.data);
    } catch (_) {
      return '${get(which == 'sem1' ? 'sem1_close' : 'sem2_close', '')}';
    }
  }

  /// `(preset_n, added_n, forced_n, sem1, sem2)` for summary lines.
  (int, int, int, String, String) calendarSummary() {
    final info = calendarData().info;
    return (
      (info['preset_days'] as num?)?.toInt() ?? 0,
      (info['user_added'] as num?)?.toInt() ?? 0,
      (info['forced_school'] as num?)?.toInt() ?? 0,
      semClose('sem1'),
      semClose('sem2'),
    );
  }

  /// Global planning reserve in percentage points (>= 0).
  double planReserve() {
    try {
      final v = double.tryParse('${get('absence_plan_reserve_pct', 10.0)}');
      return (v ?? 10.0) < 0 ? 0.0 : (v ?? 10.0);
    } catch (_) {
      return 10.0;
    }
  }

  (List<SubjectState>, List<DateTime>) subjectStates() {
    // No timetable, no planner: without lessons there is nothing to
    // budget. Callers show a "refresh first" hint instead.
    if (timetable().isEmpty) return (<SubjectState>[], <DateTime>[]);
    var defaultLimit = 25.0;
    try {
      defaultLimit =
          double.parse('${get('absence_critical_pct', 25.0)}');
    } catch (_) {
      // Seed stands.
    }
    double? warnPct;
    try {
      // Default 15.0 matches the settings field and the Bakaláři client
      // default — a missing key must not silently mean "disabled" while
      // the UI shows 15.0.
      final raw = double.tryParse('${get('absence_warn_pct', 15.0) ?? ''}');
      warnPct = (raw == null || raw == 0) ? null : raw;
    } catch (_) {
      warnPct = null;
    }
    Map<dynamic, dynamic>? baseline;
    try {
      baseline = stableBaseline().cast<dynamic, dynamic>();
    } catch (_) {
      baseline = null;
    }
    final tt = <String, List<Map<String, Object?>>>{};
    for (final e in timetable().entries) {
      tt[e.key] = [
        for (final l in e.value) Map<String, Object?>.of(l),
      ];
    }
    return forecastAll(
      absence: absence().map((k, v) => MapEntry(k, v as Object?)),
      timetable: tt,
      subjectLimits:
          (get('subject_limits', {}) as Map?)?.cast<String, Object?>(),
      holidays: effectiveHolidays(),
      defaultLimit: defaultLimit,
      schoolYearEnd: get('school_year_end', ''),
      sem1Close: semClose('sem1'),
      sem2Close: semClose('sem2'),
      warnPct: warnPct,
      stableBaseline: baseline,
      reservePct: planReserve(),
      trackedSubjects: trackedSubjects(),
      absenceDetails: absenceDetails().cast<dynamic, dynamic>(),
    );
  }

  /// Accepts a suggestion: records the skip and cancels lunch.
  /// Port of `plan_skip()`.
  bool planSkip(String dayIso, String template, [bool cancelLunch = true]) =>
      planCustomSkip(dayIso, dayIso, null, null, template,
          cancelLunch: cancelLunch);

  /// Plans a custom range (single partial day … multi-day). Port of
  /// `plan_custom_skip()`.
  bool planCustomSkip(String startIso, String endIso, int? startPeriod,
      int? endPeriod, String template,
      {bool cancelLunch = true}) {
    final entry = normalizePlannedEntry({
      'start_date': startIso,
      'end_date': endIso,
      'start_period': startPeriod,
      'end_period': endPeriod,
      'template': template,
      'cancel_lunch': cancelLunch,
    });
    if (entry == null || entryDays(entry).length > 31) return false;
    if (plannedSkips.any((e) => _entriesEqual(e, entry))) return true;
    final prevSkips = List<Map<String, Object?>>.of(plannedSkips);
    final prevCancelled = Set<String>.of(cancelledLunches);
    final prevOrders = Map<String, String>.of(orders);
    final prevPending = Set<String>.of(pendingOrders);
    plannedSkips.add(entry);
    final stagedCancelDays = (cancelLunch && stravaEnabled())
        ? stageLunchCancel(entry)
        : const <String>[];
    try {
      config.set('planned_skips', List<Map<String, Object?>>.of(plannedSkips));
      config.save();
    } catch (_) {
      plannedSkips = prevSkips;
      cancelledLunches = prevCancelled;
      orders
        ..clear()
        ..addAll(prevOrders);
      pendingOrders
        ..clear()
        ..addAll(prevPending);
      _emit();
      return false;
    }
    if (stagedCancelDays.isNotEmpty) {
      clearCancelHandledDays(stagedCancelDays);
    }
    syncAndroidState(); // the phone's alarm skips the planned lessons
    tutorialEvent('day_planned');
    _emit();
    return true;
  }

  /// Queues the lunch cancellation for every still-open day of [entry].
  /// Returns the canonical day keys staged. Port of `_stage_lunch_cancel()`.
  List<String> stageLunchCancel(Map<String, Object?> entry) {
    final staged = <String>[];
    for (final day in entryDays(entry)) {
      final dayLabel = fmtDay(day);
      bool open;
      try {
        // Explicit `this.`: the core top-level `isLunchOrderOpen`
        // (DateTime) shadows the AppState lunch logic for unqualified
        // calls from another extension.
        open = this.isLunchOrderOpen(dayLabel);
      } catch (_) {
        open = true;
      }
      if (!open) {
        // Past the order/cancel cutoff: the web would reject the change,
        // so leave this day out of the local cancel set.
        continue;
      }
      cancelledLunches.add(dayLabel);
      staged.add(dayLabel);
      // Queue the cancellation so Send transmits it: stage the menu's
      // deorder id as the local pick (pending). Without a known menu
      // just drop the local pick; submit derives the deorder at send.
      String? deorder;
      try {
        final meals = food()[dayLabel] ?? {};
        for (final mid in meals.keys) {
          if (mid.contains('&-1&')) {
            deorder = mid;
            break;
          }
        }
      } catch (_) {
        deorder = null;
      }
      if (deorder != null) {
        orders[dayLabel] = deorder;
        pendingOrders.add(dayLabel);
      } else {
        orders.remove(dayLabel);
        pendingOrders.remove(dayLabel);
      }
    }
    return staged;
  }

  /// Plans several whole days at once (one save, one repaint).
  int planDays(List<String> dayIsos, String template,
      [bool cancelLunch = true]) {
    return planEntries([
      for (final iso in dayIsos)
        {
          'start_date': iso,
          'end_date': iso,
          'template': template,
          'cancel_lunch': cancelLunch,
        },
    ]);
  }

  /// Plans several entries at once (one save, one repaint). Port of
  /// `plan_entries()`.
  int planEntries(List<Map<String, Object?>> rawEntries) {
    final entries = <Map<String, Object?>>[];
    for (final raw in rawEntries) {
      final entry = normalizePlannedEntry(raw);
      if (entry != null &&
          entryDays(entry).length <= 31 &&
          !plannedSkips.any((e) => _entriesEqual(e, entry)) &&
          !entries.any((e) => _entriesEqual(e, entry))) {
        entries.add(entry);
      }
    }
    if (entries.isEmpty) return 0;
    final prevSkips = List<Map<String, Object?>>.of(plannedSkips);
    final prevCancelled = Set<String>.of(cancelledLunches);
    final prevOrders = Map<String, String>.of(orders);
    final prevPending = Set<String>.of(pendingOrders);
    final stravaOn = stravaEnabled();
    final stagedCancelDays = <String>[];
    for (final entry in entries) {
      plannedSkips.add(entry);
      if (stravaOn && cancelsLunch(entry)) {
        stagedCancelDays.addAll(stageLunchCancel(entry));
      }
    }
    try {
      config.set('planned_skips', List<Map<String, Object?>>.of(plannedSkips));
      config.save();
    } catch (_) {
      plannedSkips = prevSkips;
      cancelledLunches = prevCancelled;
      orders
        ..clear()
        ..addAll(prevOrders);
      pendingOrders
        ..clear()
        ..addAll(prevPending);
      _emit();
      return 0;
    }
    if (stagedCancelDays.isNotEmpty) {
      clearCancelHandledDays(stagedCancelDays);
    }
    syncAndroidState();
    tutorialEvent('day_planned');
    _emit();
    return entries.length;
  }

  static bool _entriesEqual(
      Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || '${b[k]}' != '${a[k]}') return false;
    }
    return true;
  }

  // -- year planner --------------------------------------------------------
  /// Today while any of today's lessons is still ahead, else tomorrow.
  /// Port of `first_plannable_day()`.
  DateTime firstPlannableDay([DateTime? now]) {
    now ??= clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final key = fmtDay(today);
    try {
      final rows = [
        for (final r in (timetable()[key] ?? []))
          if (r is Map) Map<Object?, Object?>.of(r),
      ];
      if (rows.isNotEmpty && futureLessons(rows, now, key).isNotEmpty) {
        return today;
      }
    } catch (_) {
      // Fall through to tomorrow.
    }
    return addDays(today, 1);
  }

  /// Whole days off per term the plan aims for (0 = as many as fit).
  int plannerTargetDays() {
    try {
      final v = int.tryParse('${get('planner_target_days', 0) ?? 0}');
      return (v ?? 0) < 0 ? 0 : (v ?? 0);
    } catch (_) {
      return 0;
    }
  }

  bool setPlannerTarget(int days) {
    try {
      days = days.clamp(0, 200);
    } catch (_) {
      days = 0;
    }
    return save({'planner_target_days': days});
  }

  /// Semester the planner shows (session memory; null = running one).
  String? plannerTermKey() => plannerTerm;

  void selectPlannerTerm(String? key) {
    plannerTerm = key;
    _emit();
  }

  void togglePlannerShowAllPicks() {
    plannerShowAllPicks = !plannerShowAllPicks;
    _emit();
  }

  /// The whole-year plan (budgets, candidate days, balanced picks),
  /// cached per input snapshot. Port of `year_plan()`.
  YearPlan yearPlan([DateTime? now]) {
    now ??= clock.now();
    final today = DateTime(now.year, now.month, now.day);
    if (timetable().isEmpty) {
      return buildYearPlan(const [], today: today, firstDay: today);
    }
    final first = firstPlannableDay(now);
    Set<DateTime> dates;
    Map<DateTime, String> labels;
    try {
      final cal = calendarData();
      dates = cal.dates;
      labels = cal.labels;
    } catch (_) {
      dates = {};
      labels = {};
    }
    final key = (
      dataRev,
      '${data['last_updated'] ?? ''}',
      plannedSkips.toString(),
      today,
      first,
      planReserve(),
      plannerTargetDays(),
      '${get('subject_limits', {})}',
      '${get('absence_critical_pct', 25.0)}',
      (dates.map(fmtDay).toList()..sort()).join(','),
      semClose('sem1'),
      semClose('sem2'),
    );
    if (yearPlanCacheKey == key && yearPlanCache is YearPlan) {
      return yearPlanCache as YearPlan;
    }
    final (states, _) = subjectStates();
    Map<dynamic, dynamic>? baseline;
    try {
      baseline = stableBaseline().cast<dynamic, dynamic>();
    } catch (_) {
      baseline = null;
    }
    final plan = buildYearPlan(
      states,
      timetable: timetable(),
      stableBaseline: baseline,
      holidays: dates,
      planned: plannedSkips,
      today: today,
      firstDay: first,
      sem1Close: semClose('sem1'),
      sem2Close: semClose('sem2'),
      schoolYearEnd: get('school_year_end', ''),
      reservePct: planReserve(),
      targetDays: plannerTargetDays(),
      freeLabels: labels,
    );
    yearPlanCacheKey = key;
    yearPlanCache = plan;
    return plan;
  }

  /// Read-only lesson slots of [rawDay] for the custom planner calendar,
  /// using the same timetable source priority as [yearPlan] (concrete week,
  /// then stable template, then inferred weekly union). Port of `_pick_day`.
  ///
  /// Returns an empty list on weekends, free days, days after the school
  /// year's closure, or when no timetable is cached.
  List<PickerSlot> pickerSlotsFor(DateTime rawDay, [DateTime? now]) {
    final day = DateTime(rawDay.year, rawDay.month, rawDay.day);
    if (day.weekday >= DateTime.saturday) return const [];
    final tt = timetable();
    if (tt.isEmpty) return const [];

    final current = now ?? clock.now();
    final today = DateTime(current.year, current.month, current.day);
    final terms = schoolYearTerms(
      today,
      sem1Close: semClose('sem1'),
      sem2Close: semClose('sem2'),
      schoolYearEnd: get('school_year_end', ''),
    );
    if (terms.isNotEmpty && day.isAfter(terms.last.$3)) return const [];

    final plan = yearPlan(current);
    if (plan.holidays.contains(day)) return const [];

    Map<dynamic, dynamic> baseline;
    try {
      baseline = stableBaseline().cast<dynamic, dynamic>();
    } catch (_) {
      baseline = const {};
    }
    final complete = stableComplete();

    final key = fmtDay(day);
    List<Map<String, Object?>> rows;
    String source;
    if (tt.containsKey(key)) {
      rows = tt[key]!;
      source = 'week';
    } else if (baseline.isNotEmpty) {
      try {
        rows = stableTemplateWeek(baseline, day)[day] ?? const [];
      } catch (_) {
        rows = const [];
      }
      source = 'stable';
    } else {
      final guessed = plan.source?.lessons(day) ?? const <Lesson>[];
      rows = [
        for (final l in guessed)
          {
            'subject': l.subject,
            'period': l.period,
            'time': l.time,
            'teacher': l.teacher,
            'room': l.room,
          },
      ];
      source = rows.isNotEmpty ? 'guess' : '';
    }
    if (rows.isEmpty) return const [];

    Set<Object>? ahead;
    if (day == today) {
      ahead = Set<Object>.identity()
        ..addAll(futureLessons(rows, current, key));
    }

    final groups = <int?, List<(Map<String, Object?>, Lesson)>>{};
    for (final raw in rows) {
      final lesson = Lesson.fromLegacy(raw, key);
      groups.putIfAbsent(lesson.period, () => []).add((raw, lesson));
    }
    final periods = groups.keys.toList()
      ..sort((a, b) {
        if (a == null && b == null) return 0;
        if (a == null) return 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });

    final slots = <PickerSlot>[];
    for (final period in periods) {
      final members = groups[period]!;
      final taught = [
        for (final pair in members)
          if (!isClassEvent(pair.$1) &&
              pair.$2.status != 'cancelled' &&
              pair.$2.subject.trim().isNotEmpty &&
              pair.$2.subject.trim() != '?')
            pair,
      ];
      final shown = taught.isNotEmpty ? taught : members;
      final lesson = shown.first.$2;
      final subjects = <String>[];
      for (final pair in shown) {
        final name = pair.$2.subject;
        if (name.isNotEmpty && !subjects.contains(name)) subjects.add(name);
      }
      var clockStr = shortTime(lesson.time);
      if (!clockStr.contains(':')) clockStr = '';
      final surname = teacherSurname(lesson.teacher);
      final detail = [
        if (clockStr.isNotEmpty) clockStr,
        if (surname.isNotEmpty) surname,
        if (lesson.room.isNotEmpty) lesson.room,
      ].join(' · ');

      var changed = false;
      if (source == 'week') {
        if (taught.isEmpty) {
          changed = true;
        } else {
          for (final pair in taught) {
            try {
              final diff = classifyLesson(pair.$1, day, baseline, complete);
              if (diff.isChange) {
                changed = true;
                break;
              }
            } catch (_) {
              continue;
            }
          }
        }
      }

      var past = false;
      var planned = false;
      if (taught.isNotEmpty) {
        if (day.isBefore(today)) {
          past = true;
        } else if (ahead != null) {
          past = !taught.any((pair) => ahead!.contains(pair.$1));
        }
        planned = plannedSkips.any((e) => entryCovers(e, day, period));
      }

      slots.add(PickerSlot(
        period: period,
        subject: subjects.isEmpty ? '?' : subjects.join(' / '),
        detail: detail,
        taught: taught.isNotEmpty,
        past: past,
        planned: planned,
        changed: changed,
      ));
    }
    return slots;
  }

  /// Cached month-level slot map for [month] (Mon–Fri) so [PlannerMonthCalendar]
  /// does not recompute every cell on each rebuild (R3c S7).
  ///
  /// Today is NEVER served from the cache (R3c S11): within a day, lessons
  /// become `past` as the clock advances past their start time, so today is
  /// recomputed live via [pickerSlotsFor] on every call while all other days
  /// of the month are cached.
  Map<DateTime, List<PickerSlot>> pickerSlotsForMonth(
    DateTime month, [
    DateTime? now,
  ]) {
    final current = now ?? clock.now();
    final today = DateTime(current.year, current.month, current.day);
    final hol = calendarData().dates.toList()..sort();
    final holidaysHash = Object.hashAll(hol);
    final key = (
      month.year,
      month.month,
      dataRev,
      plannedSkips.toString(),
      today,
      semClose('sem1'),
      semClose('sem2'),
      holidaysHash,
    );
    if (monthSlotsCacheKey != key || monthSlotsCache == null) {
      final cached = <DateTime, List<PickerSlot>>{};
      var d = DateTime(month.year, month.month, 1);
      final end = month.month == 12
          ? DateTime(month.year + 1, 1, 1)
          : DateTime(month.year, month.month + 1, 1);
      while (d.isBefore(end)) {
        if (d.weekday <= DateTime.friday && d != today) {
          cached[d] = pickerSlotsFor(d, current);
        }
        d = addDays(d, 1);
      }
      monthSlotsCacheKey = key;
      monthSlotsCache = cached;
    }
    final out = Map<DateTime, List<PickerSlot>>.of(monthSlotsCache!);
    if (today.year == month.year &&
        today.month == month.month &&
        today.weekday <= DateTime.friday) {
      out[today] = pickerSlotsFor(today, current);
    }
    return out;
  }

  /// `[(term, impact rows)]` for a prospective range (what-if preview).
  List<(Object?, List<Object?>)> planImpact(String startIso, String endIso,
      [int? startPeriod, int? endPeriod, DateTime? now]) {
    final entry = normalizePlannedEntry({
      'start_date': startIso,
      'end_date': endIso,
      'start_period': startPeriod,
      'end_period': endPeriod,
    });
    if (entry == null) return [];
    try {
      return yearPlan(now).impactOfEntry(entry);
    } catch (_) {
      return [];
    }
  }

  List<(Object?, List<Object?>)> planImpactEntries(
      List<Map<String, Object?>> entries,
      [DateTime? now]) {
    final valid = [
      for (final x in entries) normalizePlannedEntry(x),
    ].whereType<Map<String, Object?>>().toList();
    if (valid.isEmpty) return [];
    try {
      return yearPlan(now).impactOfEntries(valid);
    } catch (_) {
      return [];
    }
  }

  /// Removes one planned entry (range-aware lunch re-enable). Port of
  /// `unplan_entry()`.
  bool unplanEntry(Map<String, Object?> entry) {
    final target = normalizePlannedEntry(entry);
    final before = plannedSkips.length;
    final prevSkips = List<Map<String, Object?>>.of(plannedSkips);
    final prevCancelled = Set<String>.of(cancelledLunches);
    final prevOrders = Map<String, String>.of(orders);
    final prevPending = Set<String>.of(pendingOrders);
    final removedDays = target == null ? <DateTime>[] : entryDays(target);
    if (target != null) {
      plannedSkips =
          plannedSkips.where((e) => !_entriesEqual(e, target)).toList();
    } else {
      plannedSkips =
          plannedSkips.where((e) => !_entriesEqual(e, entry)).toList();
    }
    final remaining = <String>{};
    for (final kept in plannedSkips) {
      if (!cancelsLunch(kept)) continue;
      for (final day in entryDays(kept)) {
        remaining.add(fmtDay(day));
      }
    }
    for (final day in removedDays) {
      final dayLabel = fmtDay(day);
      if (remaining.contains(dayLabel)) continue;
      cancelledLunches.remove(dayLabel);
      // Drop a staged planner deorder so the tab falls back to web truth.
      String? staged;
      try {
        staged = orders[dayLabel];
      } catch (_) {
        staged = null;
      }
      if (staged != null && staged.contains('&-1&')) {
        orders.remove(dayLabel);
        pendingOrders.remove(dayLabel);
      }
    }
    try {
      config.set('planned_skips', List<Map<String, Object?>>.of(plannedSkips));
      config.save();
    } catch (_) {
      plannedSkips = prevSkips;
      cancelledLunches = prevCancelled;
      orders
        ..clear()
        ..addAll(prevOrders);
      pendingOrders
        ..clear()
        ..addAll(prevPending);
      _emit();
      return false;
    }
    syncAndroidState(); // the alarm rings again for unplanned lessons
    _emit();
    return plannedSkips.length < before;
  }

  Map<String, Object?>? plannedFor(String dayIso) {
    DateTime? day;
    try {
      day = DateTime.parse(dayIso);
    } catch (_) {
      day = null;
    }
    if (day == null) {
      for (final entry in plannedSkips) {
        if (entryStartIso(entry) == dayIso) return entry;
      }
      return null;
    }
    for (final entry in plannedSkips) {
      final days = entryDays(entry);
      if (days.any((d) => d == day)) return entry;
    }
    return null;
  }

  /// Subjects the limits tab may list (stable + tracked), or null when
  /// neither is known. Port of `limit_subjects()`.
  List<String>? limitSubjects() {
    Set<String>? allowed;
    try {
      final tracked = trackedSubjects();
      if (tracked != null) {
        allowed = {for (final n in tracked) canonSubject(n)};
      }
    } catch (_) {
      allowed = null;
    }
    Set<String>? stableNames;
    try {
      final baseline = stableBaseline();
      if (baseline.isNotEmpty) {
        final hours = stableWeeklyHours(baseline);
        if (hours.isNotEmpty) {
          stableNames = {for (final n in hours.keys) canonSubject(n)};
        }
      }
    } catch (_) {
      stableNames = null;
    }
    if (allowed == null) {
      allowed = stableNames;
    } else if (stableNames != null) {
      allowed = allowed.intersection(stableNames);
    }
    if (allowed == null || allowed.isEmpty) return null;
    // Map back to display names from absence keys.
    List<String> absenceNames;
    try {
      absenceNames = absence().keys.toList();
    } catch (_) {
      return allowed.toList()..sort();
    }
    final out = <String>[];
    final seen = <String>{};
    for (final name in absenceNames) {
      String canon;
      try {
        canon = canonSubject(name);
      } catch (_) {
        continue;
      }
      if (allowed.contains(canon) && !seen.contains(canon)) {
        seen.add(canon);
        out.add(name);
      }
    }
    out.addAll((allowed.difference(seen).toList())..sort());
    return out;
  }

  /// The stable timetable: the cached scraped 'Stálý' view, else {}.
  /// Never learned from actual weeks. Port of `stable_baseline()`.
  Map<(int, int), Object> stableBaseline() {
    final key = (dataRev, data);
    if (baselineCacheKey == key && baselineCache != null) {
      return baselineCache!;
    }
    var baseline = <(int, int), Object>{};
    final stored = data['stable_baseline'];
    if (stableComplete() && stored is Map && stored.isNotEmpty) {
      try {
        baseline = Map<(int, int), Object>.of(
            baselineFromDict(stored.cast<Object?, Object?>()));
      } catch (_) {
        baseline = {};
      }
    }
    baselineCache = baseline;
    baselineCacheKey = key;
    return baseline;
  }

  /// True when the cached baseline is the scraped template week.
  bool stableComplete() {
    try {
      return '${data['stable_baseline_source'] ?? ''}' == 'scraped';
    } catch (_) {
      return false;
    }
  }
}

/// Riverpod facade for the planner screen (phase 6).
class PlannerController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final plannerControllerProvider =
    NotifierProvider<PlannerController, AppState>(PlannerController.new);
