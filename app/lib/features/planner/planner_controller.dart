import 'plan_reserve.dart';

/// Planner state. Port of state_planner.PlannerMixin (UI-owned parts).
///
/// Pure-Dart controller: config map + listener list, no Flutter import
/// except via the view. Persistence is injectable so tests never touch
/// disk or servers.
class PlannerController {
  final Map<String, dynamic> config;
  final List<void Function()> _listeners = [];
  final List<Map<String, dynamic>> plannedSkips = [];
  final Set<String> cancelledLunches = {};
  final Map<String, String> orders = {};
  final Set<String> pendingOrders = {};

  /// Persist [plannedSkips]; false/throw rolls memory back (mirrors the
  /// try/except rollback in plan_custom_skip/plan_entries/unplan_entry).
  final bool Function()? persist;

  /// Fired when a plan action should wake the tutorial (`day_planned`).
  final void Function(String event)? onTutorialEvent;

  /// Whether lunch ordering is currently open for `D.M.YYYY` (cutoff).
  final bool Function(String dayLabel)? isLunchOpen;

  String? plannerTerm;
  bool stravaEnabled = false;

  /// Optional live-state delegation hooks (wired by `planner_live.dart`).
  bool Function(int days)? setPlannerTargetHook;
  void Function(String? key)? selectPlannerTermHook;
  bool Function(
    String startIso,
    String endIso,
    int? startPeriod,
    int? endPeriod,
    String template, {
    required bool cancelLunch,
  })? planCustomSkipHook;
  int Function(List<Map<String, dynamic>> rawEntries)? planEntriesHook;
  bool Function(Map<String, dynamic> entry)? unplanEntryHook;

  PlannerController(
    this.config, {
    this.persist,
    this.onTutorialEvent,
    this.isLunchOpen,
  });

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);
  void _emit() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  dynamic get(String key, [dynamic fallback]) =>
      config.containsKey(key) ? config[key] : fallback;

  // -- reserve -------------------------------------------------------------
  double planReserve() => clampReserve(get('absence_plan_reserve_pct', 10.0));

  // -- target days ----------------------------------------------------------
  int plannerTargetDays() {
    try {
      final v = get('planner_target_days', 0) ?? 0;
      return (v is num ? v.toInt() : int.parse('$v')).clamp(0, 1 << 30);
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
    if (setPlannerTargetHook != null) {
      final ok = setPlannerTargetHook!(days);
      if (ok) config['planner_target_days'] = days;
      _emit();
      return ok;
    }
    config['planner_target_days'] = days;
    _emit();
    return true;
  }

  void selectPlannerTerm(String? key) {
    plannerTerm = key;
    selectPlannerTermHook?.call(key);
    _emit();
  }

  // -- plan / unplan ---------------------------------------------------------
  bool planSkip(String dayIso, String template, {bool cancelLunch = true}) =>
      planCustomSkip(dayIso, dayIso, null, null, template,
          cancelLunch: cancelLunch);

  bool planCustomSkip(
    String startIso,
    String endIso,
    int? startPeriod,
    int? endPeriod,
    String template, {
    bool cancelLunch = true,
  }) {
    if (planCustomSkipHook != null) {
      final ok = planCustomSkipHook!(
        startIso,
        endIso,
        startPeriod,
        endPeriod,
        template,
        cancelLunch: cancelLunch,
      );
      _emit();
      return ok;
    }
    final entry = normalizePlannedEntry({
      'start_date': startIso,
      'end_date': endIso,
      'start_period': startPeriod,
      'end_period': endPeriod,
      'template': template,
      'cancel_lunch': cancelLunch,
    });
    if (entry == null || entryDays(entry).length > 31) return false;
    return _commit([entry], stravaCancel: cancelLunch && stravaEnabled);
  }

  int planDays(List<String> dayIsos, String template,
      {bool cancelLunch = true}) {
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

  int planEntries(List<Map<String, dynamic>> rawEntries) {
    if (planEntriesHook != null) {
      final n = planEntriesHook!(rawEntries);
      _emit();
      return n;
    }
    final entries = <Map<String, dynamic>>[];
    for (final raw in rawEntries) {
      final entry = normalizePlannedEntry(raw);
      if (entry == null || entryDays(entry).length > 31) continue;
      if (plannedSkips.any((e) => _sameEntry(e, entry))) continue;
      if (entries.any((e) => _sameEntry(e, entry))) continue;
      entries.add(entry);
    }
    if (entries.isEmpty) return 0;
    final ok = _commit(entries,
        stravaCancel: stravaEnabled);
    return ok ? entries.length : 0;
  }

  bool _commit(List<Map<String, dynamic>> entries,
      {required bool stravaCancel}) {
    final prevSkips = List.of(plannedSkips);
    final prevCancelled = Set.of(cancelledLunches);
    final prevOrders = Map.of(orders);
    final prevPending = Set.of(pendingOrders);
    for (final entry in entries) {
      if (!plannedSkips.any((e) => _sameEntry(e, entry))) {
        plannedSkips.add(entry);
      }
      if (stravaCancel && entry['cancel_lunch'] == true) {
        _stageLunchCancel(entry);
      }
    }
    try {
      if (persist != null && persist!() == false) {
        throw StateError('persist failed');
      }
    } catch (_) {
      plannedSkips
        ..clear()
        ..addAll(prevSkips);
      cancelledLunches
        ..clear()
        ..addAll(prevCancelled);
      orders
        ..clear()
        ..addAll(prevOrders);
      pendingOrders
        ..clear()
        ..addAll(prevPending);
      _emit();
      return false;
    }
    onTutorialEvent?.call('day_planned');
    _emit();
    return true;
  }

  void _stageLunchCancel(Map<String, dynamic> entry) {
    for (final day in entryDays(entry)) {
      final label =
          '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';
      var open = true;
      try {
        if (isLunchOpen != null) open = isLunchOpen!(label);
      } catch (_) {
        open = true;
      }
      if (!open) continue;
      cancelledLunches.add(label);
      orders.remove(label);
      pendingOrders.remove(label);
    }
  }

  bool unplanEntry(Map<String, dynamic> entry) {
    if (unplanEntryHook != null) {
      final ok = unplanEntryHook!(entry);
      _emit();
      return ok;
    }
    final target = normalizePlannedEntry(entry);
    final before = plannedSkips.length;
    final prevSkips = List.of(plannedSkips);
    final prevCancelled = Set.of(cancelledLunches);
    final prevOrders = Map.of(orders);
    final prevPending = Set.of(pendingOrders);
    List<DateTime> removedDays = [];
    if (target != null) {
      removedDays = entryDays(target);
      plannedSkips.removeWhere((e) => _sameEntry(e, target));
    } else {
      plannedSkips.removeWhere((e) => _sameEntry(e, entry));
    }
    final remaining = <String>{};
    for (final kept in plannedSkips) {
      if (kept['cancel_lunch'] != true) continue;
      for (final day in entryDays(kept)) {
        remaining.add(_cz(day));
      }
    }
    for (final day in removedDays) {
      final label = _cz(day);
      if (remaining.contains(label)) continue;
      cancelledLunches.remove(label);
      final staged = orders[label];
      if (staged != null && staged.contains('&-1&')) {
        orders.remove(label);
        pendingOrders.remove(label);
      }
    }
    try {
      if (persist != null && persist!() == false) {
        throw StateError('persist failed');
      }
    } catch (_) {
      plannedSkips
        ..clear()
        ..addAll(prevSkips);
      cancelledLunches
        ..clear()
        ..addAll(prevCancelled);
      orders
        ..clear()
        ..addAll(prevOrders);
      pendingOrders
        ..clear()
        ..addAll(prevPending);
      _emit();
      return false;
    }
    _emit();
    return plannedSkips.length < before;
  }

  Map<String, dynamic>? plannedFor(String dayIso) {
    DateTime? day;
    try {
      day = DateTime.parse(dayIso);
    } catch (_) {
      day = null;
    }
    for (final entry in plannedSkips) {
      final days = entryDays(entry);
      if (day != null) {
        if (days.any((d) => d == day)) return entry;
      } else if (entryStartIso(entry) == dayIso) {
        return entry;
      }
    }
    return null;
  }

  static bool _sameEntry(Map<String, dynamic> a, Map<String, dynamic> b) {
    return entryStartIso(a) == entryStartIso(b) &&
        entryEndIso(a) == entryEndIso(b) &&
        '${a['start_period']}' == '${b['start_period']}' &&
        '${a['end_period']}' == '${b['end_period']}' &&
        '${a['template']}' == '${b['template']}';
  }

  static String _cz(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}
