// Dynamic network-aware refresh schedule, tier selection, data-usage estimator,
// and one-time F6 schedule-defaults startup upgrade.
//
// See `docs/qa-roadmap/design-F6.md` §3.3 and §7.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../lunches/lunch_cutoff.dart';
import '../planning/schedule.dart';
import '../planning/school_presets.dart';
import '../storage/accounts.dart';
import '../storage/cache.dart';
import '../storage/config.dart';
import '../storage/helpers.dart';
import '../wakeup.dart' as wakeup;

/// Device network metering classification used to pick polling cadence.
///
/// Never blocks a refresh: `unknown` is conservatively treated as `metered`
/// for interval selection only.
enum NetworkKind { unmetered, metered, unknown }

/// Active daytime school-hours window for one calendar day.
typedef ActiveDayWindow = ({DateTime start, DateTime end});

/// New F6 schedule keys whose absence in `global.json` / `config.json` marks
/// a pre-F6 install for [applyF6ScheduleDefaultsOnce].
const Set<String> f6NewScheduleKeys = {
  'check_interval_mobile_minutes',
  'check_interval_off_hours_minutes',
  'refresh_wifi_always_fast',
};

/// Estimated data usage and request counts for one schedule configuration.
class DataUsageEstimate {
  final double mobileSchoolDayMb;
  final double wifiSchoolDayMb;
  final double typicalMonthlyMobileMb;
  final double allMobileMonthlyMb;
  final int requestsPerSchoolDay;
  final double effectiveWifiMin;
  final double effectiveMobileDayMin;
  final double effectiveOffHoursMin;

  const DataUsageEstimate({
    required this.mobileSchoolDayMb,
    required this.wifiSchoolDayMb,
    required this.typicalMonthlyMobileMb,
    required this.allMobileMonthlyMb,
    required this.requestsPerSchoolDay,
    required this.effectiveWifiMin,
    required this.effectiveMobileDayMin,
    required this.effectiveOffHoursMin,
  });
}

double _numOr(Object? value, double fallback) {
  if (value is num) {
    final d = value.toDouble();
    if (!d.isNaN && !d.isInfinite) return d;
    return fallback;
  }
  if (value is String) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    if (parsed != null && !parsed.isNaN && !parsed.isInfinite) return parsed;
  }
  return fallback;
}

Map<String, Object?>? _asStringMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': e.value};
  }
  return null;
}

/// Active school-hours window for [day] (`1 hour before first lesson -> 17:00`,
/// or end of last lesson if later; `start` floored at `05:00`).
///
/// Returns `null` on free days, weekends with no non-cancelled lessons, or
/// days with zero non-cancelled lessons when timetable/baseline data exists.
/// On a cold install (both timetable and stable baseline empty), Mon-Fri
/// defaults to `07:00-17:00` and Sat-Sun returns `null`.
ActiveDayWindow? activeDayWindow(
  Map<String, Object?>? cache,
  Map<String, Object?> cfg,
  DateTime day,
) {
  final dayOnly = DateTime(day.year, day.month, day.day);
  Set<DateTime> freeDays;
  try {
    freeDays = effectiveCalendar(cfg, clip: false).dates;
  } catch (_) {
    freeDays = const {};
  }
  if (freeDays.contains(dayOnly)) return null;

  final timetable = _asStringMap(cache?['timetable']);
  final days = wakeup.indexDays(timetable);
  final rawBaseline = cache?['stable_baseline'];
  final baseline =
      rawBaseline is Map ? baselineFromDict(rawBaseline) : null;
  final hasBaseline = baseline != null && baseline.isNotEmpty;

  if (days.isEmpty && !hasBaseline) {
    if (dayOnly.weekday > 5) return null;
    return (
      start: DateTime(dayOnly.year, dayOnly.month, dayOnly.day, 7, 0),
      end: DateTime(dayOnly.year, dayOnly.month, dayOnly.day, 17, 0),
    );
  }

  final lessons = wakeup.lessonsFor(days, dayOnly, hasBaseline ? baseline : null);
  final slots = wakeup.periodSlots(days);
  // Pass planned: const [] so a planned skip does not hide school hours.
  final first = wakeup.firstLesson(lessons, dayOnly, const [], slots);
  if (first == null) return null;

  var lastEnd = first.start + 45;
  for (final raw in lessons) {
    if (wakeup.isCancelledLesson(raw, dayOnly)) continue;
    final period = wakeup.periodOf(raw, dayOnly);
    final clock = wakeup.clockOf(raw, dayOnly, period, slots);
    if (clock != null && clock.$2 > lastEnd) {
      lastEnd = clock.$2;
    }
  }

  final startMin = math.max(5 * 60, first.start - 60);
  final endMin = math.max(17 * 60, lastEnd);
  return (
    start: dayOnly.add(Duration(minutes: startMin)),
    end: dayOnly.add(Duration(minutes: endMin)),
  );
}

/// Union of [activeDayWindow] across all `background_refresh != false`
/// accounts (earliest `start` to latest `end`), or `null` if all are off.
ActiveDayWindow? combinedActiveDayWindow(
  Iterable<({Map<String, Object?>? cache, Map<String, Object?> cfg})> accounts,
  DateTime day,
) {
  DateTime? earliestStart;
  DateTime? latestEnd;
  for (final acc in accounts) {
    if (acc.cfg['background_refresh'] == false) continue;
    final w = activeDayWindow(acc.cache, acc.cfg, day);
    if (w == null) continue;
    if (earliestStart == null || w.start.isBefore(earliestStart)) {
      earliestStart = w.start;
    }
    if (latestEnd == null || w.end.isAfter(latestEnd)) {
      latestEnd = w.end;
    }
  }
  if (earliestStart == null || latestEnd == null) return null;
  return (start: earliestStart, end: latestEnd);
}

/// Effective polling interval in minutes (`0.0` = paused off-hours).
///
/// Mobile daytime is clamped to `max(wifiFast, mobileDay)` so mobile never
/// polls faster than Wi-Fi.
double effectiveCheckIntervalMinutes(
  Map<String, Object?> cfg,
  ActiveDayWindow? window,
  NetworkKind network,
  DateTime now,
) {
  final wifiFast = math.max(1.0, _numOr(cfg['check_interval_minutes'], 5.0));
  final mobileDay = math.max(
    wifiFast,
    math.max(1.0, _numOr(cfg['check_interval_mobile_minutes'], 5.0)),
  );
  final rawOff = _numOr(cfg['check_interval_off_hours_minutes'], 60.0);
  final offHours = rawOff <= 0 ? 0.0 : math.max(1.0, rawOff);
  final wifiAlwaysFast = cfg['refresh_wifi_always_fast'] != false;
  final inWindow =
      window != null && !now.isBefore(window.start) && now.isBefore(window.end);

  if (network == NetworkKind.unmetered) {
    if (wifiAlwaysFast) return wifiFast;
    return inWindow ? wifiFast : offHours;
  }
  return inWindow ? mobileDay : offHours;
}

/// The single authoritative function answering "when is the next scheduled
/// check due?".
///
/// Never feeds `0` (paused) to `nextDue`. Handles:
/// - clamping an off-hours interval to today's (or next) window start when
///   fast checks begin earlier than `lastRun + offHours`;
/// - off-hours pause (`0`): wakes at the earliest of the next active window
///   start (up to 14 days ahead) or `nextAlarm - 30 min` (pre-alarm quick
///   tick, once per alarm), falling back to `now + 6 hours`.
DateTime nextScheduledWake(
  DateTime? lastRun,
  Map<String, Object?> cfg,
  ActiveDayWindow? Function(DateTime day) windowFor,
  NetworkKind network,
  DateTime now, {
  DateTime? nextAlarm,
}) {
  if (lastRun == null) return now;

  final today = DateTime(now.year, now.month, now.day);
  final todayWindow = windowFor(today);
  final effective =
      effectiveCheckIntervalMinutes(cfg, todayWindow, network, now);
  final inWindow = todayWindow != null &&
      !now.isBefore(todayWindow.start) &&
      now.isBefore(todayWindow.end);

  if (effective > 0) {
    var candidate =
        lastRun.add(Duration(microseconds: (effective * 60 * 1000000).round()));
    if (!inWindow) {
      // If a daytime window starts after `now` and before `candidate`, clamp
      // to it so fast checks begin right at `firstLesson - 60 min`.
      DateTime? nextStart;
      if (todayWindow != null && todayWindow.start.isAfter(now)) {
        nextStart = todayWindow.start;
      } else if (candidate.isAfter(now)) {
        // Calendar days: the day the clocks go forward is only 23 h long.
        final daysAhead = daysBetween(today, candidate);
        for (var d = 1; d <= math.min(daysAhead, 14); d++) {
          final w = windowFor(addDays(today, d));
          if (w != null && w.start.isAfter(now)) {
            nextStart = w.start;
            break;
          }
        }
      }
      if (nextStart != null && nextStart.isBefore(candidate)) {
        candidate = nextStart;
      }
    }
    return candidate;
  }

  // effective == 0: off-hours pause.
  DateTime? nextWindowStart;
  for (var d = 0; d <= 14; d++) {
    final w = windowFor(addDays(today, d));
    if (w != null && w.start.isAfter(now)) {
      nextWindowStart = w.start;
      break;
    }
  }

  DateTime? preAlarmCandidate;
  if (nextAlarm != null && nextAlarm.isAfter(now)) {
    final preAlarm = nextAlarm.subtract(const Duration(minutes: 30));
    if (lastRun.isBefore(preAlarm)) {
      preAlarmCandidate = preAlarm.isBefore(now) ? now : preAlarm;
    }
  }

  if (nextWindowStart != null && preAlarmCandidate != null) {
    return preAlarmCandidate.isBefore(nextWindowStart)
        ? preAlarmCandidate
        : nextWindowStart;
  }
  if (preAlarmCandidate != null) return preAlarmCandidate;
  if (nextWindowStart != null) return nextWindowStart;
  return now.add(const Duration(hours: 6));
}

/// Decides whether a scheduled tick for one account runs a full (`'all'`) or
/// quick (`'quick'`) refresh, and whether a quick tick should also read the
/// Komens outbox (`quickOutbox`) while excuses are pending.
({String scope, bool quickOutbox}) chooseScheduledScope(
  Map<String, Object?> cfg,
  Map<String, Object?> cache,
  DateTime now, {
  required bool hasPendingExcuses,
  required bool hasUnconfirmed,
}) {
  final lastUpdated = lastUpdatedTime(cache);
  final partFull = partUpdatedTime(cache, 'full');
  // Rule 1: cold cache.
  if (lastUpdated == null && partFull == null) {
    return (scope: 'all', quickOutbox: false);
  }
  final lastFull = partFull ?? lastUpdated!;

  // Rule 2: first run of a new calendar day.
  if (lastFull.year != now.year ||
      lastFull.month != now.month ||
      lastFull.day != now.day) {
    return (scope: 'all', quickOutbox: false);
  }

  // Rule 3: last full run >= 6 hours old (~4 full runs/day).
  if (now.difference(lastFull) >= const Duration(hours: 6)) {
    return (scope: 'all', quickOutbox: false);
  }

  final lastOutbox = partUpdatedTime(cache, 'outbox');

  // Rule 4: unconfirmed submit waiting for settlement (>= 30 min old outbox).
  if (hasUnconfirmed &&
      (lastOutbox == null ||
          now.difference(lastOutbox) >= const Duration(minutes: 30))) {
    return (scope: 'all', quickOutbox: false);
  }

  // Rule 5 (R8a S2): previous full run did not finish its job.
  final (hasBak, _) = hasValidCredentials(cfg);
  if (hasBak && (lastOutbox == null || lastOutbox.isBefore(lastFull))) {
    return (scope: 'all', quickOutbox: false);
  }
  final failedStamp = '${cache[scheduledRefreshFailedKey] ?? ''}'.trim();
  final failedScope = '${cache[scheduledRefreshFailedScopeKey] ?? ''}'.trim();
  if (failedStamp.isNotEmpty && failedScope == 'all') {
    return (scope: 'all', quickOutbox: false);
  }

  // Otherwise quick tick; keep outbox <= 60 min old while excuses are pending.
  final quickOutbox = hasPendingExcuses &&
      (lastOutbox == null ||
          now.difference(lastOutbox) >= const Duration(minutes: 60));
  return (scope: 'quick', quickOutbox: quickOutbox);
}

/// True when a quick tick should also refresh Strava (missing stamp, 30 min
/// daytime, 60 min off-hours, or 15 min within 60 min before today's cutoff).
bool stravaQuickFetchDue(
  Map<String, Object?> cache,
  Map<String, Object?> cfg,
  DateTime now, {
  ActiveDayWindow? window,
}) {
  final lastStrava = partUpdatedTime(cache, 'strava');
  if (lastStrava == null) return true;
  final age = now.difference(lastStrava);

  final win = window ?? activeDayWindow(cache, cfg, now);
  final inWindow =
      win != null && !now.isBefore(win.start) && now.isBefore(win.end);

  if (inWindow && age >= const Duration(minutes: 30)) return true;
  if (!inWindow && age >= const Duration(minutes: 60)) return true;

  final (cutH, cutM) = parseCutoffTime(resolveLunchCutoff(cfg));
  final cutoff = DateTime(now.year, now.month, now.day, cutH, cutM);
  final untilCutoff = cutoff.difference(now);
  if (!untilCutoff.isNegative &&
      untilCutoff <= const Duration(minutes: 60) &&
      age >= const Duration(minutes: 15)) {
    return true;
  }
  return false;
}

/// One-time startup upgrade of pre-F6 schedule defaults (owner Q1, 2026-11-22).
///
/// Writes the 4 new schedule defaults (`5` / `5` / `60` / `true`) into
/// `<rootDir>/global.json` (or `<rootDir>/config.json` in [degraded] mode)
/// ONLY when none of [f6NewScheduleKeys] are present yet. Re-checks under
/// `<file>.lock`, postpones cleanly if busy, leaves every other key untouched,
/// and logs the previous value.
bool applyF6ScheduleDefaultsOnce(
  String rootDir, {
  bool degraded = false,
  @visibleForTesting double lockTimeoutS = 10.0,
}) {
  final path =
      degraded ? p.join(rootDir, 'config.json') : p.join(rootDir, globalConfigFile);

  Map<String, Object?>? readRaw() {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return null;
      return {for (final e in decoded.entries) '${e.key}': e.value as Object?};
    } catch (_) {
      return null;
    }
  }

  final initial = readRaw();
  if (initial == null || initial.keys.any(f6NewScheduleKeys.contains)) {
    return false;
  }

  final lock = InterProcessLock('$path.lock');
  if (!lock.acquire(timeoutS: lockTimeoutS)) {
    print('Info: F6 schedule defaults postponed (settings busy).');
    return false;
  }
  try {
    final current = readRaw();
    if (current == null || current.keys.any(f6NewScheduleKeys.contains)) {
      return false;
    }
    final oldVal = current['check_interval_minutes'];
    current['check_interval_minutes'] = 5;
    current['check_interval_mobile_minutes'] = 5;
    current['check_interval_off_hours_minutes'] = 60;
    current['refresh_wifi_always_fast'] = true;
    atomicWriteJson(path, current);
    print(
      'Info: F6 schedule defaults applied '
      '(check_interval_minutes ${oldVal ?? 'unset'} -> 5).',
    );
    return true;
  } on Object catch (e) {
    print('Warning: Could not apply F6 schedule defaults: $e');
    return false;
  } finally {
    lock.release();
  }
}

/// Pure, deterministic data-usage estimator matching `design-F6.md` §2.
DataUsageEstimate estimateDataUsage(
  Map<String, Object?> cfg, {
  int accountCount = 1,
  bool persistentTls = false,
  double schoolDayHours = 10.0,
  bool useStrava = true,
}) {
  final accounts = math.max(1, accountCount);
  final dayHours = schoolDayHours.clamp(0.0, 24.0);
  final offHoursPerDay = 24.0 - dayHours;

  final wifiMin = math.max(1.0, _numOr(cfg['check_interval_minutes'], 5.0));
  final mobileDayMin = math.max(
    wifiMin,
    math.max(1.0, _numOr(cfg['check_interval_mobile_minutes'], 5.0)),
  );
  final rawOff = _numOr(cfg['check_interval_off_hours_minutes'], 60.0);
  final offMin = rawOff <= 0 ? 0.0 : math.max(1.0, rawOff);
  final wifiAlwaysFast = cfg['refresh_wifi_always_fast'] != false;

  double tickKb(double intervalMin) {
    if (intervalMin <= 0) return 0.0;
    // Bakalari's sliding session is 15 min: steady intervals < 15 min reuse
    // the cookie without extra logins; >= 15 min pay one login (+8 KB).
    final reused = intervalMin < 15.0;
    if (persistentTls) return reused ? 11.0 : 19.0;
    return reused ? 18.0 : 26.0;
  }

  double tickReqs(double intervalMin) {
    if (intervalMin <= 0) return 0.0;
    return intervalMin < 15.0 ? 3.0 : 5.0;
  }

  // Non-quick-tick school-day baseline (MB) from §2:
  // triggered marks (0.56) + changed weeks (0.21) + hourly safety net
  // (0.065 * dayHours) + Strava (0.22) + 4 full runs (1.66) = ~3.30 MB.
  final stravaDayMb = useStrava ? 0.22 : 0.0;
  final baselineSchoolDayMb =
      0.56 + 0.21 + (0.065 * dayHours) + stravaDayMb + 1.66;

  // Daytime-only baseline (typical mobile at school: triggered marks +
  // changed weeks + hourly safety net + daytime Strava + ~1 daytime full run).
  final daytimeBaselineMb =
      0.56 + 0.21 + (0.065 * dayHours) + (useStrava ? 0.14 : 0.0) + 0.34;

  // Day-off baseline (4 full runs + hourly Strava, no daytime safety net).
  final dayOffBaselineMb = 1.66 + (useStrava ? 0.14 : 0.0);

  // Mobile school day: fast daytime ticks + off-hours ticks + baseline.
  final mobileDayTicks = (dayHours * 60.0) / mobileDayMin;
  final offTicks = offMin > 0 ? (offHoursPerDay * 60.0) / offMin : 0.0;
  final mobileDayTicksMb = (mobileDayTicks * tickKb(mobileDayMin)) / 1000.0;
  final mobileOffTicksMb = (offTicks * tickKb(offMin)) / 1000.0;
  final mobileSchoolDayPerAcc =
      mobileDayTicksMb + mobileOffTicksMb + baselineSchoolDayMb;

  // Wi-Fi school day.
  final double wifiTicksMb;
  final double wifiDayTicks = (dayHours * 60.0) / wifiMin;
  final double wifiOffTicks;
  if (wifiAlwaysFast) {
    wifiOffTicks = (offHoursPerDay * 60.0) / wifiMin;
    wifiTicksMb = ((wifiDayTicks + wifiOffTicks) * tickKb(wifiMin)) / 1000.0;
  } else {
    wifiOffTicks = offTicks;
    wifiTicksMb =
        (wifiDayTicks * tickKb(wifiMin) + wifiOffTicks * tickKb(offMin)) /
            1000.0;
  }
  final wifiSchoolDayPerAcc = wifiTicksMb + baselineSchoolDayMb;

  // Typical mobile/month: 21 school days on mobile during daytime only.
  final typicalMonthlyPerAcc = 21.0 * (mobileDayTicksMb + daytimeBaselineMb);

  // 100% mobile/month: 21 school days + 9 days off.
  final dayOffMobileTicks = offMin > 0 ? (24.0 * 60.0) / offMin : 0.0;
  final dayOffMobilePerAcc =
      (dayOffMobileTicks * tickKb(offMin)) / 1000.0 + dayOffBaselineMb;
  final allMobileMonthlyPerAcc =
      21.0 * mobileSchoolDayPerAcc + 9.0 * dayOffMobilePerAcc;

  // School-day requests (mobile cadence: 4 full runs ~42 + triggered ~16 = 58).
  final reqsPerAcc =
      (mobileDayTicks * tickReqs(mobileDayMin) +
              offTicks * tickReqs(offMin) +
              58.0)
          .round();

  return DataUsageEstimate(
    mobileSchoolDayMb: mobileSchoolDayPerAcc * accounts,
    wifiSchoolDayMb: wifiSchoolDayPerAcc * accounts,
    typicalMonthlyMobileMb: typicalMonthlyPerAcc * accounts,
    allMobileMonthlyMb: allMobileMonthlyPerAcc * accounts,
    requestsPerSchoolDay: reqsPerAcc * accounts,
    effectiveWifiMin: wifiMin,
    effectiveMobileDayMin: mobileDayMin,
    effectiveOffHoursMin: offMin,
  );
}
