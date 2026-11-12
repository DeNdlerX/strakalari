// Absence forecasting engine (pure functions — no I/O, no UI).
//
// Port of strakalari/core/forecast.py. Answers: how many hours of each
// subject can the student still miss, what will the final percentage be.
// Day-off planning lives in `planner`.
//
// Inputs are plain data (absence `{subject: pct}`, legacy timetable dict,
// holiday list, semester bounds) so every function is unit-testable.
import 'package:clock/clock.dart';

import '../models.dart';

/// Round-half-up for non-negative hour budgets (avoids banker's rounding).
int _halfUp(double value) {
  final floored = (value < 0 ? 0.0 : value) + 0.5;
  return floored.floor();
}

/// Python `round()` on a non-negative value: halves go to even.
int roundHalfEvenToInt(double value) {
  final floored = value.floor();
  final frac = value - floored;
  if (frac == 0.5) return floored.isEven ? floored : floored + 1;
  return value.round();
}

/// Python `f'{value:.digitsf}'`: correctly-rounded fixed decimals,
/// halves to even.
///
/// A plain `value * 10^digits` scaling double-rounds (2.675 * 100 is
/// exactly 267.5, which would round up while Python prints '2.67'),
/// so the rounding runs on the 17-significant-digit expansion, which
/// pins down the exact binary value.
String _formatFixed(double value, int digits) {
  if (value.isNaN || value.isInfinite) return '$value';
  final neg = value < 0;
  var s = value.abs().toStringAsPrecision(17);
  var exp = 0;
  final ePos = s.indexOf('e');
  if (ePos >= 0) {
    exp = int.parse(s.substring(ePos + 1));
    s = s.substring(0, ePos);
  }
  final point = s.indexOf('.');
  var intDigits = point + exp; // digits before the decimal point
  final digitStr = s.replaceAll('.', '');
  final stripped = digitStr.replaceFirst(RegExp('^0+'), '');
  intDigits -= digitStr.length - stripped.length;
  String intPart;
  String fracPart;
  if (stripped.isEmpty) {
    intPart = '0';
    fracPart = '';
  } else if (intDigits <= 0) {
    intPart = '0';
    fracPart = '${'0' * -intDigits}$stripped';
  } else if (intDigits >= stripped.length) {
    intPart = '$stripped${'0' * (intDigits - stripped.length)}';
    fracPart = '';
  } else {
    intPart = stripped.substring(0, intDigits);
    fracPart = stripped.substring(intDigits);
  }
  var kept = '$fracPart${'0' * digits}'.substring(0, digits);
  final rest = fracPart.length > digits ? fracPart.substring(digits) : '';
  var roundUp = false;
  if (rest.isNotEmpty) {
    final next = rest.codeUnitAt(0) - 48;
    if (next != 5) {
      roundUp = next > 5;
    } else if (rest.substring(1).contains(RegExp('[1-9]'))) {
      roundUp = true; // 5 followed by non-zero: strictly more than half
    } else {
      // Exact tie (within 17 digits): to even.
      final last = kept.isEmpty
          ? intPart.codeUnitAt(intPart.length - 1) - 48
          : kept.codeUnitAt(kept.length - 1) - 48;
      roundUp = last.isOdd;
    }
  }
  if (roundUp) {
    final chars = '$intPart$kept'.split('');
    var i = chars.length - 1;
    while (i >= 0 && chars[i] == '9') {
      chars[i] = '0';
      i--;
    }
    if (i < 0) {
      chars.insert(0, '1');
    } else {
      chars[i] = String.fromCharCode(chars[i].codeUnitAt(0) + 1);
    }
    final joined = chars.join();
    final splitAt = joined.length - digits;
    intPart = joined.substring(0, splitAt);
    kept = digits == 0 ? '' : joined.substring(splitAt);
  }
  final sign = neg ? '-' : '';
  return digits == 0 ? '$sign$intPart' : '$sign$intPart.$kept';
}

/// Python `round(value, digits)`: halves go to even.
double _roundHalfEven(double value, int digits) =>
    double.parse(_formatFixed(value, digits));

/// Reference semester length in weeks (kept for parity; the forecast
/// derives real day counts from the calendar instead).
const int standardSemesterWeeks = 16;

/// Normalizes `['25.12.2026', date, ...]` into a set of dates.
Set<DateTime> normalizeHolidays(Iterable<Object?>? holidays) {
  final out = <DateTime>{};
  for (final item in holidays ?? const <Object?>[]) {
    final parsed = parseCzDate(item);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

/// Counts lessons per subject across the loaded (stable) week(s).
///
/// Counts only — the 4 h/2 h core-subject fallback for subjects missing
/// from the timetable lives in [_fallbackWeeklyHours] (used by the
/// forecast entry point), not here.
Map<String, int> weeklyHoursPerSubject(
    Map<String, List<Map<String, Object?>>>? timetable) {
  final table = timetable ?? {};
  final counts = <String, int>{};
  for (final lessons in table.values) {
    for (final raw in lessons) {
      final name = '${raw['subject'] ?? ''}'.trim();
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  // A multi-week timetable would inflate counts — normalize to one week.
  // No max(1, ...) floor: a subject seen once across many weeks is a
  // one-off, not a weekly hour — flooring it to 1 would inflate rare
  // subjects into full weekly budgets. Zero-count leftovers are dropped;
  // consumers fall back to the core-subject heuristic instead.
  final dayCount = table.isEmpty ? 1 : table.length;
  if (dayCount > 5) {
    final factor = 5.0 / dayCount;
    final scaled = <String, int>{};
    for (final entry in counts.entries) {
      // Python round(): halves go to even.
      final n = roundHalfEvenToInt(entry.value * factor);
      if (n > 0) scaled[entry.key] = n;
    }
    return scaled;
  }
  return counts;
}

int _fallbackWeeklyHours(String subject) {
  final lowered = subject.toLowerCase();
  if (['matem', 'česk', 'cesk', 'angli', 'němč', 'nemč']
      .any(lowered.contains)) {
    return 4;
  }
  return 2;
}

/// Weekdays in [start, end] minus holidays.
List<DateTime> schoolDaysBetween(DateTime start, DateTime end,
    [Set<DateTime>? holidays]) {
  final holidaySet = holidays ?? const <DateTime>{};
  final days = <DateTime>[];
  var cursor = DateTime(start.year, start.month, start.day);
  final last = DateTime(end.year, end.month, end.day);
  while (!cursor.isAfter(last)) {
    // Dart weekday: Monday = 1 (Python weekday(): Monday = 0).
    if (cursor.weekday <= DateTime.friday && !holidaySet.contains(cursor)) {
      days.add(cursor);
    }
    // Constructor arithmetic: `+ Duration(days: 1)` drifts across DST
    // transitions (a local-midnight day + 24 h is not midnight after a
    // spring-forward), while Python `date + timedelta` stays on the date.
    cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
  }
  return days;
}

/// (first_day, last_day) of the running Czech semester for [today].
(DateTime, DateTime) semesterBounds(DateTime today) {
  if (today.month >= 9) {
    return (DateTime(today.year, 9, 1), DateTime(today.year + 1, 1, 31));
  }
  if (today.month == 1) {
    return (DateTime(today.year - 1, 9, 1), DateTime(today.year, 1, 31));
  }
  if (today.month >= 2) {
    return (DateTime(today.year, 2, 1), DateTime(today.year, 6, 30));
  }
  return (DateTime(today.year - 1, 9, 1), DateTime(today.year, 1, 31));
}

/// Collapses every whitespace run (incl. non-breaking spaces).
final _canonWsRe = RegExp('[\\s ]+');

/// Canonical subject key: whitespace (incl. nbsp) collapsed, lowercased.
///
/// The absence overview writes non-breaking spaces
/// (`Seminar z<nbsp>matematiky S`) while the timetable and the directory
/// use plain ones — comparisons must normalize or the same subject
/// silently counts as two.
String canonSubject(Object? name) {
  return '${name ?? ''}'
      .replaceAll(_canonWsRe, ' ')
      .trim()
      .toLowerCase();
}

/// Projects one subject to semester end.
///
/// [currentPct] applies to the taught part so far; future lessons are
/// assumed attended unless the caller subtracts planned skips first.
/// [taughtHours] overrides the estimated already-taught hours with the
/// real elapsed count from the absence overview (elapsed, never planned
/// totals); null keeps the weekly-hours estimate.
/// [warnPct] overrides the derived 60%-of-limit warning threshold.
/// [reservePct] (percentage points) is the safety reserve for vacation
/// planning: the planner stops recommending the subject once it reaches
/// `limit_pct - reserve_pct` instead of the bare school limit. The
/// school truth (`limit_pct` / `safe_hours_left`) is unaffected —
/// the reserve-aware budget lives in `plan_limit_pct` /
/// `plan_safe_hours_left`.
SubjectState forecastSubject({
  required num currentPct,
  required int weeklyHours,
  required int schoolDaysLeft,
  required int schoolDaysTotal,
  required num limitPct,
  double? warnPct,
  double reservePct = 0.0,
  Object? taughtHours,
}) {
  final current = currentPct.toDouble();
  final limit = limitPct.toDouble();
  final weekly = weeklyHours < 1 ? 1 : weeklyHours;
  // Python round(): halves go to even.
  final totalHours = roundHalfEvenToInt(weekly * schoolDaysTotal / 5) < 1
      ? 1
      : roundHalfEvenToInt(weekly * schoolDaysTotal / 5);
  double? taught;
  if (taughtHours is num) {
    taught = taughtHours.toDouble();
  } else if (taughtHours != null) {
    taught = double.tryParse('$taughtHours'.trim());
  }
  final double taughtSoFar;
  if (taught != null) {
    taughtSoFar = (taught.isNaN || taught < 0.0) ? 0.0 : taught;
  } else {
    final estimate =
        roundHalfEvenToInt(weekly * (schoolDaysTotal - schoolDaysLeft) / 5);
    taughtSoFar = (estimate < 1 ? 1 : estimate).toDouble();
  }
  final alreadyMissed =
      (current < 0.0 ? 0.0 : current) / 100.0 * taughtSoFar;
  final maxMissable = (limit < 0.0 ? 0.0 : limit) / 100.0 * totalHours;
  // Half-up rounding (not banker's): x.5 budgets must not round to even.
  final safeLeft = _halfUp(maxMissable - alreadyMissed) < 0
      ? 0
      : _halfUp(maxMissable - alreadyMissed);
  final projected = alreadyMissed / totalHours * 100.0;
  final reserve =
      (reservePct.isNaN || reservePct < 0.0) ? 0.0 : reservePct;
  final planLimit =
      _roundHalfEven((limit < 0.0 ? 0.0 : limit) - reserve, 1);
  final planMaxMissable = planLimit / 100.0 * totalHours;
  final planSafe = _halfUp(planMaxMissable - alreadyMissed) < 0
      ? 0
      : _halfUp(planMaxMissable - alreadyMissed);
  return SubjectState(
    name: '',
    currentPct: _roundHalfEven(current, 1),
    limitPct: limit,
    weeklyHours: weekly,
    safeHoursLeft: safeLeft,
    projectedPct: _roundHalfEven(projected, 1),
    warnPct: (warnPct == null || warnPct == 0.0) ? 0.0 : warnPct,
    planLimitPct: planLimit,
    planSafeHoursLeft: planSafe,
  );
}

/// Full-semester forecast for every subject with absence data.
///
/// Returns (subject_states, school_days_left_list). [warnPct] is the
/// explicit warning threshold (falls back to 60% of each limit).
/// [reservePct] is the global planning reserve (see [forecastSubject]).
/// [trackedSubjects] is the school-official subject set (the subject
/// directory): absence entries outside it are dropped — only tracked
/// subjects count toward limits, so anything else is always free to
/// skip and needs no budget. [absenceDetails] carries the full
/// overview rows (elapsed hours + school verdict badges) keyed by
/// subject; elapsed hours replace the taught-hours estimate and the
/// badges escalate the subject status.
///
/// [reservePct] (percentage points, global planning reserve) lowers
/// each subject's *planning* limit to `limit - reserve` — the planner
/// stops recommending a subject earlier while the school truth
/// (`limit_pct` / `safe_hours_left`) stays untouched.
/// When [stableBaseline] (the scraped "Stálý" view, serialized to plain
/// maps of `{slot: {subject: ...} | [{subject: ...}, ...]}`) is
/// given, weekly hours come from the stable timetable — cancellations,
/// substitutions and one-off events in the raw weeks don't inflate or
/// shrink a subject's hours. Absence entries for subjects the baseline
/// never saw (renamed subjects, one-off events) are dropped: only stable
/// subjects count toward absence limits, so anything else is always free
/// to skip and needs no budget. Without a baseline the legacy raw-count
/// + name-heuristic fallback applies (fresh installs, tests).
(List<SubjectState>, List<DateTime>) forecastAll({
  Map<String, Object?>? absence,
  Map<String, List<Map<String, Object?>>>? timetable,
  Map<String, Object?>? subjectLimits,
  Iterable<Object?>? holidays,
  DateTime? today,
  double defaultLimit = 25.0,
  Object? schoolYearEnd,
  Object? sem1Close,
  Object? sem2Close,
  double? warnPct,
  Map<dynamic, dynamic>? stableBaseline,
  double reservePct = 0.0,
  Iterable<Object?>? trackedSubjects,
  Map<dynamic, dynamic>? absenceDetails,
}) {
  final now = today ?? clock.now();
  final todayDay = DateTime(now.year, now.month, now.day);
  final holidaySet = normalizeHolidays(holidays);
  var (firstDay, semesterEnd) = semesterBounds(todayDay);
  // Absence/marks closure (e.g. final year ends sooner) replaces the
  // automatic semester bound. Legacy single `schoolYearEnd` acts as
  // a fallback for the running semester.
  final closeRaw =
      firstDay.month == 9 ? (sem1Close ?? schoolYearEnd) : (sem2Close ?? schoolYearEnd);
  if (closeRaw != null) {
    final parsedEnd = parseCzDate(closeRaw);
    if (parsedEnd != null && !parsedEnd.isBefore(firstDay)) {
      semesterEnd = parsedEnd;
    }
  }
  final daysTotal = schoolDaysBetween(firstDay, semesterEnd, holidaySet);
  final daysLeft = [
    for (final d in daysTotal)
      if (!d.isBefore(todayDay)) d,
  ];

  var weekly = weeklyHoursPerSubject(timetable);
  Set<String>? stableSubjects;
  if (stableBaseline != null && stableBaseline.isNotEmpty) {
    // Mirrors schedule.stable_weekly_hours on serialized baselines:
    // one slot per (weekday, period); split-group variant lists count
    // each distinct subject once.
    String nameOf(Object? variant) {
      if (variant is Map) return '${variant['subject'] ?? ''}'.trim();
      return '';
    }

    final stableHours = <String, int>{};
    for (final slotValue in stableBaseline.values) {
      final variants = slotValue is List ? slotValue : [slotValue];
      final names = <String>{
        for (final v in variants)
          if (nameOf(v).isNotEmpty) nameOf(v),
      };
      for (final name in names) {
        stableHours[name] = (stableHours[name] ?? 0) + 1;
      }
    }
    if (stableHours.isNotEmpty) {
      weekly = stableHours;
      // Only stable subjects count toward limits — one-offs never do.
      stableSubjects = {for (final name in stableHours.keys) canonSubject(name)};
    }
  }
  final limits = <String, double>{};
  for (final entry in (subjectLimits ?? {}).entries) {
    final v = entry.value is num
        ? (entry.value as num).toDouble()
        : double.tryParse('${entry.value}'.trim());
    if (v != null) limits[canonSubject(entry.key)] = v;
  }
  final Set<String>? tracked = trackedSubjects == null
      ? null
      : {for (final name in trackedSubjects) canonSubject(name)};
  final detailsBySubject = <String, Map<dynamic, dynamic>>{};
  for (final entry in (absenceDetails ?? {}).entries) {
    if (entry.value is Map) {
      detailsBySubject[canonSubject(entry.key)] =
          entry.value as Map<dynamic, dynamic>;
    }
  }
  final reserve = (reservePct.isNaN || reservePct < 0.0) ? 0.0 : reservePct;

  final states = <(int, SubjectState)>[];
  var index = 0;
  for (final entry in (absence ?? {}).entries) {
    final current = entry.value is num
        ? (entry.value as num).toDouble()
        : double.tryParse('${entry.value}'.trim());
    if (current == null) continue;
    final canon = canonSubject(entry.key);
    if (stableSubjects != null && !stableSubjects.contains(canon)) {
      // One-off / renamed subject: free to skip, no budget needed.
      continue;
    }
    if (tracked != null && !tracked.contains(canon)) {
      // Not a school-tracked subject (e.g. homeroom hour): no
      // absence downside, always free to skip.
      continue;
    }
    var hours = weekly[entry.key] ?? weekly[entry.key.trim()] ?? 0;
    if (hours == 0) {
      // Case-insensitive fallback before giving up to the heuristic.
      var match = 0;
      for (final weeklyEntry in weekly.entries) {
        if (canonSubject(weeklyEntry.key) == canon) {
          match = weeklyEntry.value;
          break;
        }
      }
      hours = match != 0 ? match : _fallbackWeeklyHours(entry.key);
    }
    final limit = limits[canon] ?? defaultLimit;
    final detail = detailsBySubject[canon] ?? {};
    double? taught;
    if (detail['total_hours'] is num) {
      taught = (detail['total_hours'] as num).toDouble();
    } else if (detail['total_hours'] != null) {
      taught = double.tryParse('${detail['total_hours']}'.trim());
    }
    final state = forecastSubject(
      currentPct: current,
      weeklyHours: hours,
      schoolDaysLeft: daysLeft.length,
      schoolDaysTotal: daysTotal.length,
      limitPct: limit,
      warnPct: warnPct,
      reservePct: reserve,
      taughtHours: taught,
    );
    states.add((
      index++,
      SubjectState(
        name: entry.key,
        currentPct: state.currentPct,
        limitPct: state.limitPct,
        weeklyHours: state.weeklyHours,
        safeHoursLeft: state.safeHoursLeft,
        projectedPct: state.projectedPct,
        warnPct: state.warnPct,
        planLimitPct: state.planLimitPct,
        planSafeHoursLeft: state.planSafeHoursLeft,
        approaching: detail['approaching'] == true,
        unclassifiable: detail['unclassifiable'] == true,
        taughtHours: taught ?? 0.0,
      )
    ));
  }
  states.sort((a, b) {
    final byPct = b.$2.currentPct.compareTo(a.$2.currentPct);
    if (byPct != 0) return byPct;
    return a.$1.compareTo(b.$1);
  });
  return ([for (final s in states) s.$2], daysLeft);
}
