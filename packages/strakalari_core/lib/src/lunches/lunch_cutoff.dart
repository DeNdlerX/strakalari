// Lunch ordering cutoff: order only until a set time on the previous
// business day.
//
// Port of strakalari/core/lunch_cutoff.py. Business day = Mon-Fri that is
// not a school free day (preset holidays + user additions minus forced
// school days). The cutoff time comes from the school preset (12:00 when the
// preset sets none) and can be overridden per user via
// `lunch_order_cutoff_time` (`HH:MM`, empty = follow preset).
//
// Time model: Dart has no fixed-offset datetimes, so [lunchOrderDeadline]
// returns the deadline as Prague wall time in a naive local [DateTime]
// (PLAN §3.5: keep naive local datetimes). [isLunchOrderOpen] still compares
// true instants: both sides are shifted to UTC with the EU daylight-saving
// offset in force on their own day, exactly like the Python aware-datetime
// comparison. The naive-input convention matches Python: naive datetimes
// are Prague wall time.
import 'package:clock/clock.dart';

/// (hour, minute) from `HH:MM`; [fallback] on anything unparseable.
(int, int) parseCutoffTime(Object? value,
    [(int, int) fallback = (12, 0)]) {
  try {
    final text = '${value ?? ''}'.trim();
    if (text.isEmpty) return fallback;
    final parts = text.replaceAll('.', ':').split(':');
    if (parts.length != 2) return fallback;
    final hour = int.tryParse(parts[0].trim());
    final minute = int.tryParse(parts[1].trim());
    if (hour == null || minute == null) return fallback;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
    return (hour, minute);
  } catch (_) {
    return fallback;
  }
}

/// True for empty (follow preset) or a strict `HH:MM` 24h time.
///
/// Accepts the `HH.MM` spelling too — the runtime ([parseCutoffTime])
/// treats dots as colons, so the validator must accept whatever the runtime
/// parses. Canonical: storage/config.dart carries a mirror
/// ([isValidCutoffTime] there); rewire it to this function when the lunches
/// library is exported from the barrel.
bool isValidCutoffTime(Object? value) {
  final text = '${value ?? ''}'.trim().replaceAll('.', ':');
  if (text.isEmpty) return true;
  if (RegExp(r'^\d{1,2}:\d{2}$').firstMatch(text) == null) return false;
  final parts = text.split(':');
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return false;
  return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
}

/// Canonical `HH:MM` (zero-padded) or [fallback] on bad input.
String normalizeCutoffTime(Object? value, [String fallback = '12:00']) {
  final fallbackHm = parseCutoffTime(fallback);
  final (hour, minute) = parseCutoffTime(value, fallbackHm);
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

DateTime _asDate(DateTime value) => DateTime(value.year, value.month, value.day);

Set<DateTime> _normalizeFree(Iterable<DateTime>? freeDays) {
  try {
    return {for (final d in freeDays ?? <DateTime>[]) _asDate(d)};
  } catch (_) {
    return <DateTime>{};
  }
}

/// Date of the last Sunday in [month] (EU daylight-saving rule).
DateTime _lastSunday(int year, int month) {
  final lastDay = DateTime(year, month + 1, 0).day;
  final day = DateTime(year, month, lastDay);
  // Dart weekday: Monday = 1 .. Sunday = 7 (Python: Monday = 0).
  return day.subtract(Duration(days: day.weekday % 7));
}

/// Fixed-offset Europe/Prague UTC offset for [day] (no tz database needed).
///
/// EU daylight saving: CEST (UTC+2) from the last Sunday in March up to the
/// last Sunday in October, otherwise CET (UTC+1). Cutoffs always sit at
/// midday, far from the ambiguous/overnight transition hours.
Duration _pragueOffset(DateTime day) {
  final date = _asDate(day);
  final start = _lastSunday(date.year, 3);
  final end = _lastSunday(date.year, 10);
  final dst = !date.isBefore(start) && date.isBefore(end);
  return Duration(hours: dst ? 2 : 1);
}

/// Mon-Fri and not in the school free-day set.
bool isBusinessDay(DateTime day, [Iterable<DateTime>? freeDays]) {
  final date = _asDate(day);
  if (date.weekday >= 6) return false;
  try {
    return !_normalizeFree(freeDays).contains(date);
  } catch (_) {
    return date.weekday < 6;
  }
}

/// Nearest business day strictly before [day] (capped at 366 steps).
///
/// A year-long free-day span never silently yields a non-business day as
/// "the" deadline day — the oldest checked day is returned so the deadline
/// stays fail-closed instead of pointing at a weekend.
DateTime previousBusinessDay(DateTime day, [Iterable<DateTime>? freeDays]) {
  final date = _asDate(day);
  final free = _normalizeFree(freeDays);
  var cursor = date.subtract(const Duration(days: 1));
  for (var i = 0; i < 366; i++) {
    if (isBusinessDay(cursor, free)) return cursor;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return cursor;
}

/// Deadline datetime for a lunch day: previous business day at cutoff time.
///
/// Returned as Prague wall time in a naive local [DateTime] (see library
/// docs for the time model).
DateTime lunchOrderDeadline(
  DateTime lunchDay, [
  Object? cutoffTime = '12:00',
  Iterable<DateTime>? freeDays,
]) {
  final (hour, minute) = parseCutoffTime(cutoffTime);
  final prev = previousBusinessDay(lunchDay, freeDays);
  return DateTime(prev.year, prev.month, prev.day, hour, minute);
}

DateTime _asUtcInstant(DateTime wall) => DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
      wall.microsecond,
    ).subtract(_pragueOffset(wall));

/// True while [now] is at or before the ordering deadline.
///
/// Naive inputs are Prague wall time (mirroring Python); UTC inputs compare
/// by instant. Defaults to the current moment via [clock.now()]. Fail-closed:
/// an uncomputable deadline never reads as "still open".
bool isLunchOrderOpen(
  DateTime lunchDay, {
  DateTime? now,
  Object? cutoffTime = '12:00',
  Iterable<DateTime>? freeDays,
}) {
  try {
    final deadline = lunchOrderDeadline(
        _asDate(lunchDay), cutoffTime, freeDays);
    final deadlineInstant = _asUtcInstant(deadline);
    final moment = now ?? clock.now();
    final nowInstant =
        moment.isUtc ? moment.toUtc() : _asUtcInstant(moment);
    return !nowInstant.isAfter(deadlineInstant);
  } catch (_) {
    // Fail-closed: an uncomputable deadline must never read as
    // "still open" (that ordered after the deadline). Callers treat
    // false as "closed / not orderable".
    return false;
  }
}
