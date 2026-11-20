// Automatic lunch picks (`strava_order_mode = auto`) — pure helpers.
//
// Port of strakalari/core/lunch_auto.py. Used by the refresh pipeline (auto
// mode) and the Lunches view filter: first non-banned meal per orderable
// day, optionally Gemini picks when an auto run is due. No I/O except the
// optional Gemini request.
//
// Cross-module notes (phase-3 rewires, see STATUS.md):
// - Food-ban matching delegates to planning/matching.dart
//   ([_isFoodBannedPair] → `isFoodBanned`); the stem/token logic lives
//   there, exactly like lunch_auto.py calls matching.is_food_banned.
// - [orderWindowPredicate] resolves its cutoff and free-day set from
//   school_presets (`resolveLunchCutoff` / `effectiveCalendar(...,
//   clip: false)`), like lunch_auto.py; the optional
//   [cutoffOverride]/[freeDaysOverride] seams stay for tests.
// - Key decryption ([decryptStrict], [isEncryptedFlag]), [getLanguage],
//   [canonicalDayKey] and [parseCzDate] are the already-ported canonical
//   implementations.
import 'package:clock/clock.dart';

import '../i18n.dart';
import '../models.dart';
import '../planning/matching.dart' as matching;
import '../planning/school_presets.dart'
    show effectiveCalendar, resolveLunchCutoff;
import '../storage/helpers.dart';
import 'gemini.dart';
import 'lunch_cutoff.dart';

/// Default Gemini auto-run interval in days.
const int geminiIntervalDefault = 2;

/// Minimum Gemini auto-run interval in days.
const int geminiIntervalMin = 1;

/// Maximum Gemini auto-run interval in days.
const int geminiIntervalMax = 30;

/// Data-cache key: days an earlier auto run already dealt with.
const String handledKey = 'auto_lunch_handled';

/// Data-cache key: days whose automatic lunch cancellation already ran
/// or was overridden by a manual meal pick.
const String cancelHandledKey = 'auto_lunch_cancel_handled';

/// True when automatic lunch cancellation is enabled (default `true`).
bool stravaAutoCancelEnabled(Map<String, Object?>? configData) {
  final cfg = configData ?? const <String, Object?>{};
  if (!cfg.containsKey('strava_auto_cancel_lunches')) return true;
  final value = cfg['strava_auto_cancel_lunches'];
  if (value == null) return true;
  if (value is bool) return value;
  if (value is num) return value != 0;
  return !['false', '0', 'no'].contains('$value'.trim().toLowerCase());
}

/// Canonical `DD.MM.YYYY` school free days from preset + user overrides.
Set<String> freeLunchDays(Map<String, Object?>? configData) {
  try {
    final dates = effectiveCalendar(configData, clip: false).dates;
    return {for (final d in dates) canonicalDayKey(d)};
  } on Object catch (e) {
    // ignore: avoid_print
    print('Warning: could not resolve free lunch days: $e');
    return <String>{};
  }
}

/// School free days skipped by ordering/filtering when automatic lunch
/// cancellation is enabled (empty when `strava_auto_cancel_lunches` is off).
Set<String> autoCancelFreeLunchDays(
  Map<String, Object?>? configData, [
  Iterable<String>? freeDays,
]) {
  if (!stravaAutoCancelEnabled(configData)) return <String>{};
  if (freeDays != null) {
    return <String>{for (final d in freeDays) _canonDay(d)};
  }
  return freeLunchDays(configData);
}

/// Progress events from [planAutoOrders] (`emit(key, {field: value})`).
typedef LunchAutoEmit = void Function(String key,
    [Map<String, Object?> fields]);

/// Clamps the Gemini auto-run interval to [1, 30] days (default 2).
int clampGeminiInterval(Object? value) {
  try {
    final text = '${value ?? geminiIntervalDefault}'.replaceAll(',', '.');
    final parsed = double.tryParse(text.trim());
    if (parsed == null || parsed.isNaN || parsed.isInfinite) {
      return geminiIntervalDefault;
    }
    return parsed
        .truncate()
        .clamp(geminiIntervalMin, geminiIntervalMax);
  } catch (_) {
    return geminiIntervalDefault;
  }
}

DateTime? _checkedYmd(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return null;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final maxDay = lengths[month - 1] + (month == 2 && leap ? 1 : 0);
  if (day > maxDay) return null;
  return DateTime(year, month, day);
}

/// Parses the stored `gemini_last_run` stamp (ISO date, CZ fallback).
DateTime? parseLastRun(Object? value) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) return null;
  final head = text.length > 10 ? text.substring(0, 10) : text;
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(head);
  if (iso != null) {
    return _checkedYmd(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3)!));
  }
  final cz =
      RegExp(r'^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$').firstMatch(text);
  if (cz != null) {
    try {
      return _checkedYmd(int.parse(cz.group(3)!), int.parse(cz.group(2)!),
          int.parse(cz.group(1)!));
    } catch (_) {
      return null;
    }
  }
  return null;
}

bool _isTruthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// True when a Gemini auto-run is due (date granularity — hour-agnostic).
///
/// Runs at most once per [intervalDays]: never ran → due, otherwise
/// `(today - lastRun).days >= interval`. A corrupt stamp counts as
/// never-ran (fail open toward running once, the run re-stamps).
bool shouldRunGeminiAuto(
  Object? enabled,
  Object? lastRunIso,
  Object? intervalDays, [
  DateTime? today,
]) {
  if (!_isTruthy(enabled)) return false;
  final ref = today ?? clock.now();
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final interval = clampGeminiInterval(intervalDays);
  final last = parseLastRun(lastRunIso);
  if (last == null) return true;
  try {
    return daysBetween(last, refDay) >= interval;
  } catch (_) {
    return true;
  }
}

int _mealOrderKey(String mid) {
  final m = RegExp(r'&(\d+)&').firstMatch(mid);
  return m == null ? 99 : int.parse(m.group(1)!);
}

/// Best-effort canonical day key (`DD.MM.YYYY`), spelling-tolerant.
///
/// Falls back to the stripped raw string when unparseable — callers only
/// use it for equality, never for date math.
String _canonDay(Object? value) {
  try {
    return canonicalDayKey(value);
  } catch (_) {
    return '${value ?? ''}'.trim();
  }
}

// -- food-ban matching (canonical: planning/matching.dart) ----------------------
///
/// Python's `unicodedata NFD` keeps letters without a decomposition (`ø`,
/// `ł`, `ß`, …) unchanged; matching.dart replicates that exactly, so all
/// blacklist checks delegate to it.

/// Canonical `matching.is_food_banned`: (banned, matchedKeyword).
/// Case/diacritics-insensitive, whole-word, Czech-stem aware.
(bool, String) _isFoodBannedPair(String foodName, List<String> blacklist) =>
    matching.isFoodBanned(foodName, blacklist);

// -- picks ---------------------------------------------------------------

/// First-non-banned pick per orderable day (mirrors `evaluate()`).
///
/// Skips past days, planner-cancelled days and cutoff-closed days. Days
/// where everything is banned fall back to the menu's deorder element
/// (`&-1&` id) when present, else are left unpicked. Pure — no I/O.
Map<String, String> filterPicks(
  Map<String, Map<String, String>>? foodData, {
  Iterable<String>? blacklist,
  Iterable<String>? cancelledDays,
  bool Function(DateTime)? isOpen,
  DateTime? today,
}) {
  final ref = today ?? clock.now();
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final cancelled = {for (final d in cancelledDays ?? <String>[]) _canonDay(d)};
  final words = [for (final w in blacklist ?? <String>[]) if (w.isNotEmpty) w];

  bool banned(Object? name) {
    try {
      return _isFoodBannedPair('${name ?? ''}', words).$1;
    } catch (_) {
      // Fail-closed: an uncheckable meal must not be auto-ordered.
      return true;
    }
  }

  final picks = <String, String>{};
  for (final entry in (foodData ?? {}).entries) {
    final dayS = entry.key;
    if (cancelled.contains(_canonDay(dayS))) continue;
    final selection = entry.value;
    if (selection.isEmpty) continue;
    late final DateTime dayDate;
    try {
      final parsed = parseDate(dayS);
      dayDate = DateTime(parsed.year, parsed.month, parsed.day);
    } catch (_) {
      continue;
    }
    try {
      if (dayDate.isBefore(refDay)) continue;
    } catch (_) {
      continue;
    }
    if (isOpen != null) {
      try {
        if (!isOpen(dayDate)) continue;
      } catch (_) {
        // Fail-closed: an uncheckable cutoff must skip the day.
        continue;
      }
    }
    String? deorderId;
    final available = <MapEntry<String, String>>[];
    for (final meal in selection.entries) {
      if (meal.key.contains('&-1&')) {
        deorderId = meal.key;
      } else {
        available.add(MapEntry(meal.key, meal.value));
      }
    }
    available.sort(
        (a, b) => _mealOrderKey(a.key).compareTo(_mealOrderKey(b.key)));
    String? chosen;
    for (final meal in available) {
      if (banned(meal.value)) continue;
      chosen = meal.key;
      break;
    }
    chosen ??= deorderId;
    if (chosen != null) {
      // Canonical day key: "01.10.2026" and "1.10.2026" spellings
      // must not coexist as two entries for the same day.
      picks[_canonDay(dayS)] = chosen;
    }
  }
  return picks;
}

/// Keeps valid Gemini picks, fills the gaps with [filterPicks].
///
/// A Gemini pick survives only when the meal is on the menu, not banned,
/// the day is orderable (future, open, not cancelled). Remaining orderable
/// days get the filter pick so auto mode never leaves a day empty while the
/// menu is full.
Map<String, String> mergeGeminiWithFilter(
  Map<String, String>? geminiOrders,
  Map<String, Map<String, String>> foodData, {
  Iterable<String>? blacklist,
  Iterable<String>? cancelledDays,
  bool Function(DateTime)? isOpen,
  DateTime? today,
}) {
  final ref = today ?? clock.now();
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final cancelled = {for (final d in cancelledDays ?? <String>[]) _canonDay(d)};
  final words = [for (final w in blacklist ?? <String>[]) if (w.isNotEmpty) w];
  // Canonical-tolerant menu lookup: Gemini day keys may use another
  // spelling than the extractor's raw keys.
  final canonFood = <String, String>{};
  for (final dayKey in foodData.keys) {
    try {
      canonFood.putIfAbsent(_canonDay(dayKey), () => dayKey);
    } catch (_) {
      continue;
    }
  }

  bool banned(Object? name) {
    try {
      return _isFoodBannedPair('${name ?? ''}', words).$1;
    } catch (_) {
      // Fail-closed: an uncheckable meal must not be auto-ordered.
      return true;
    }
  }

  DateTime? dayOk(String dayS) {
    if (cancelled.contains(_canonDay(dayS))) return null;
    var meals = foodData[dayS];
    if (meals == null || meals.isEmpty) {
      try {
        meals = foodData[canonFood[_canonDay(dayS)]];
      } catch (_) {
        meals = null;
      }
    }
    if (meals == null || meals.isEmpty) return null;
    late final DateTime dayDate;
    try {
      final parsed = parseDate(dayS);
      dayDate = DateTime(parsed.year, parsed.month, parsed.day);
    } catch (_) {
      return null;
    }
    try {
      if (dayDate.isBefore(refDay)) return null;
    } catch (_) {
      return null;
    }
    if (isOpen != null) {
      try {
        if (!isOpen(dayDate)) return null;
      } catch (_) {
        // Fail-closed: an uncheckable cutoff must skip the day.
        return null;
      }
    }
    return dayDate;
  }

  final merged = <String, String>{};
  for (final entry in (geminiOrders ?? {}).entries) {
    final dayS = entry.key;
    final midS = entry.value;
    if (dayOk(dayS) == null) continue;
    Map<String, String>? menu = foodData[dayS];
    menu ??= foodData[canonFood[_canonDay(dayS)] ?? dayS] ?? {};
    // The meal must be on THAT day's menu — an id borrowed from
    // another day would be skipped at order time and block the
    // filter fallback for this day.
    if (!menu.containsKey(midS)) continue;
    if (!midS.contains('&-1&')) {
      if (banned(menu[midS])) continue;
    }
    // Canonical day key (see filterPicks): raw spellings from Gemini
    // ("1.10.2026") must merge with extractor keys ("01.10.2026").
    merged[_canonDay(dayS)] = midS;
  }
  for (final entry in filterPicks(foodData,
          blacklist: words,
          cancelledDays: cancelled,
          isOpen: isOpen,
          today: refDay)
      .entries) {
    merged.putIfAbsent(entry.key, () => entry.value);
  }
  return merged;
}

/// `date -> bool` cutoff predicate for auto picks (null = unavailable).
///
/// Fail-closed: a day whose deadline cannot be computed reads as closed.
/// The cutoff and free-day set resolve from [configData] through
/// school_presets (`resolveLunchCutoff` / `effectiveCalendar(..., clip:
/// false)`); [cutoffOverride] and [freeDaysOverride] stay injectable
/// seams for tests.
bool Function(DateTime)? orderWindowPredicate(
  Map<String, Object?>? configData, {
  DateTime? now,
  String? cutoffOverride,
  Set<DateTime>? freeDaysOverride,
}) {
  try {
    final cutoff = cutoffOverride ?? resolveLunchCutoff(configData);
    final free =
        freeDaysOverride ?? effectiveCalendar(configData, clip: false).dates;
    final moment = now ?? clock.now();
    bool isOpen(DateTime day) {
      try {
        return isLunchOrderOpen(day,
            now: moment, cutoffTime: cutoff, freeDays: free);
      } catch (_) {
        return false;
      }
    }

    return isOpen;
  } catch (_) {
    return null;
  }
}

/// Cancellations for planned days off that still hold an ordered lunch.
///
/// Only days whose lunch is ordered on the web, whose menu offers a cancel
/// (`&-1&`) control and whose order window is still open. Like Python, the
/// "today" reference is always the real clock (the function takes no [today]
/// override) — an uncheckable day is left alone (fail-closed).
Map<String, String> _plannedDeorders(
  Map<String, Map<String, String>> food,
  Map<String, String> ordered,
  Set<String> cancelled,
  bool Function(DateTime) isOpen,
) {
  final nowRef = clock.now();
  final todayD = DateTime(nowRef.year, nowRef.month, nowRef.day);
  final orderedDays = {
    for (final e in ordered.entries)
      if (e.value.isNotEmpty && !e.value.contains('&-1&')) _canonDay(e.key)
  };
  final out = <String, String>{};
  for (final entry in food.entries) {
    final canon = _canonDay(entry.key);
    if (!cancelled.contains(canon) || !orderedDays.contains(canon)) continue;
    String? deorder;
    for (final mid in entry.value.keys) {
      if (mid.contains('&-1&')) {
        deorder = mid;
        break;
      }
    }
    if (deorder == null) continue;
    try {
      final parsed = parseDate(entry.key);
      final dayDate = DateTime(parsed.year, parsed.month, parsed.day);
      if (dayDate.isBefore(todayD) || !isOpen(dayDate)) continue;
    } catch (_) {
      continue; // fail-closed: an uncheckable day is left alone
    }
    out[canon] = deorder;
  }
  return out;
}

/// Builds Strava cancel picks (`&-1&` meal ids) for ordered lunches on
/// school free days or planned skip days (`cancelledDays`), skipping any
/// days already dealt with or manually re-ordered (`cancelHandled`).
///
/// Returns `{}` when [stravaAutoCancelEnabled] is false or the order/cancel
/// deadline predicate cannot be resolved (fail-closed).
Map<String, String> planAutoCancels(
  Map<String, Map<String, String>>? foodData,
  Map<String, Object?>? configData, {
  Iterable<String>? cancelledDays,
  Map<String, String>? ordered,
  Iterable<String>? cancelHandled,
  bool Function(DateTime)? isOpen,
}) {
  final food = Map<String, Map<String, String>>.from(foodData ?? {});
  if (food.isEmpty) return <String, String>{};
  final cfg = configData ?? const <String, Object?>{};
  if (!stravaAutoCancelEnabled(cfg)) return <String, String>{};
  final open = isOpen ?? orderWindowPredicate(cfg);
  if (open == null) return <String, String>{};
  final handledSet = <String>{
    for (final d in cancelHandled ?? const <String>[]) _canonDay(d),
  };
  final targets = <String>{
    for (final d in cancelledDays ?? const <String>[]) _canonDay(d),
    ...freeLunchDays(cfg),
  }..removeAll(handledSet);
  if (targets.isEmpty) return <String, String>{};
  return _plannedDeorders(
      food, ordered ?? const <String, String>{}, targets, open);
}

/// Auto-mode lunch picks: Gemini when due, else the blacklist filter.
///
/// Returns `(orders, usedGemini)`; `usedGemini` is true only when a real
/// Gemini answer produced picks (callers then stamp `gemini_last_run`). A
/// corrupt blacklist yields no picks at all (fail-closed).
/// `emit(key, {field: value})` receives progress events. [promptFallback]
/// is used when no `gemini_prompt` is configured.
///
/// Auto mode only fills gaps, it never overrides the user:
///
/// * days already ordered on the web ([ordered]) keep their meal;
/// * days in [handled] (dealt with by an earlier auto run, see
///   [updateHandledDays]) are left alone, so a lunch the user cancelled
///   on the web is not ordered again;
/// * [cancelledDays] (planned days off and calendar free days) get no meal —
///   and when a meal is still ordered there (unless in [cancelHandled] or
///   auto-cancel is disabled), its cancellation instead.
///
/// Never raises.
Future<(Map<String, String>, bool)> planAutoOrders(
  Map<String, Map<String, String>>? foodData,
  Map<String, Object?>? configData, {
  Iterable<String>? blacklist,
  bool blacklistBroken = false,
  Iterable<String>? cancelledDays,
  LunchAutoEmit? emit,
  String promptFallback = '',
  Map<String, String>? ordered,
  Iterable<String>? handled,
  Iterable<String>? cancelHandled,
  bool Function(DateTime)? isOpen,
  GeminiTransport? geminiTransport,
  Future<void> Function(Duration)? geminiSleep,
}) async {
  void sendEmit(String key, [Map<String, Object?> fields = const {}]) {
    if (emit == null) return;
    try {
      emit(key, fields);
    } catch (_) {}
  }

  final food = Map<String, Map<String, String>>.from(foodData ?? {});
  if (food.isEmpty) return (<String, String>{}, false);
  final cfg = configData ?? <String, Object?>{};
  final cancelled = <String>{
    for (final d in cancelledDays ?? <String>[]) _canonDay(d),
    ...autoCancelFreeLunchDays(cfg),
  };
  final open = isOpen ?? orderWindowPredicate(cfg);
  if (open == null) {
    // No verifiable deadline means no verifiably orderable day.
    return (<String, String>{}, false);
  }
  final cancelDone = <String>{
    for (final d in cancelHandled ?? const <String>[]) _canonDay(d),
  };
  final deorders = stravaAutoCancelEnabled(cfg)
      ? _plannedDeorders(
          food,
          ordered ?? {},
          cancelled.difference(cancelDone),
          open,
        )
      : <String, String>{};
  if (blacklistBroken) {
    sendEmit('blacklist_broken_log');
    return (deorders, false);
  }
  final skip = <String>{
    ...cancelled,
    for (final d in handled ?? <String>[]) _canonDay(d),
    for (final e in (ordered ?? {}).entries)
      if (e.value.isNotEmpty) _canonDay(e.key),
  };
  food.removeWhere((day, _) => skip.contains(_canonDay(day)));
  if (food.isEmpty) return (deorders, false);
  final words = [for (final w in blacklist ?? <String>[]) if (w.isNotEmpty) w];
  final enabled = _isTruthy(cfg['gemini_auto_enabled']);
  if (shouldRunGeminiAuto(enabled, cfg['gemini_last_run'] ?? '',
      cfg['gemini_interval_days'] ?? geminiIntervalDefault)) {
    try {
      var key = '${cfg['gemini_api_key'] ?? ''}';
      if (isEncryptedFlag(cfg['gemini_api_key_encrypted'])) {
        key = decryptStrict(key) ?? '';
      }
      key = key.trim();
      var model = '${cfg['gemini_model'] ?? ''}'.trim();
      if (model.isEmpty) model = defaultGeminiModel;
      if (key.isNotEmpty) {
        var prompt = '${cfg['gemini_prompt'] ?? ''}'.trim();
        if (prompt.isEmpty) prompt = promptFallback;
        final (_, geminiOrders) = await recommendLunches(
          food,
          prompt,
          key,
          model: model,
          language: getLanguage(),
          allowFallback: false,
          transport: geminiTransport,
          sleep: geminiSleep,
        );
        if (geminiOrders.isNotEmpty) {
          final merged = mergeGeminiWithFilter(
            geminiOrders,
            food,
            blacklist: words,
            cancelledDays: cancelled,
            isOpen: open,
          );
          if (merged.isNotEmpty) {
            sendEmit('gemini_auto_used', {'model': model});
            return ({...merged, ...deorders}, true);
          }
        }
      }
    } catch (_) {}
  }
  try {
    final picks = filterPicks(food,
        blacklist: words,
        cancelledDays: cancelled,
        isOpen: open);
    if (picks.isNotEmpty) sendEmit('filter_auto_used');
    return ({...picks, ...deorders}, false);
  } catch (_) {
    return (deorders, false);
  }
}

/// Days auto mode must not touch again, pruned to the last week.
///
/// A day counts as handled once it held an order (placed by auto mode or by
/// the user): from then on the user owns it, so cancelling it on the web is
/// final. Days that failed (e.g. no money) are not added and get retried on
/// the next run.
List<String> updateHandledDays(
  Iterable<String>? previous,
  Map<String, String>? ordered,
  Iterable<String>? placed, [
  DateTime? today,
]) {
  final ref = today ?? clock.now();
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final days = <String>{
    for (final d in previous ?? <String>[]) _canonDay(d),
    for (final e in (ordered ?? {}).entries)
      if (e.value.isNotEmpty && !e.value.contains('&-1&')) _canonDay(e.key),
    for (final d in placed ?? <String>[]) _canonDay(d),
  };
  final kept = <String>[];
  for (final day in days) {
    final parsed = parseCzDate(day);
    if (parsed == null ||
        daysBetween(DateTime(parsed.year, parsed.month, parsed.day), refDay) <=
            7) {
      kept.add(day);
    }
  }
  kept.sort((a, b) {
    final pa = parseCzDate(a);
    final pb = parseCzDate(b);
    if (pa == null && pb == null) return a.compareTo(b);
    if (pa == null) return -1;
    if (pb == null) return 1;
    final c = pa.compareTo(pb);
    return c != 0 ? c : a.compareTo(b);
  });
  return kept;
}

/// Days whose automatic lunch cancellation was already applied or overridden
/// by a manual meal pick, pruned to the last week.
List<String> updateCancelHandledDays(
  Iterable<String>? previous,
  Iterable<String>? added, [
  DateTime? today,
]) {
  final ref = today ?? clock.now();
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final days = <String>{
    for (final d in previous ?? const <String>[])
      if (d.trim().isNotEmpty) _canonDay(d),
    for (final d in added ?? const <String>[])
      if (d.trim().isNotEmpty) _canonDay(d),
  };
  final kept = <String>[];
  for (final day in days) {
    final parsed = parseCzDate(day);
    if (parsed == null ||
        daysBetween(DateTime(parsed.year, parsed.month, parsed.day), refDay) <=
            7) {
      kept.add(day);
    }
  }
  kept.sort((a, b) {
    final pa = parseCzDate(a);
    final pb = parseCzDate(b);
    if (pa == null && pb == null) return a.compareTo(b);
    if (pa == null) return -1;
    if (pb == null) return 1;
    final c = pa.compareTo(pb);
    return c != 0 ? c : a.compareTo(b);
  });
  return kept;
}
