import 'package:app/l10n/strings.dart';
import 'dart:math' as math;


/// Pure planning-reserve math. Port of the reserve parts of
/// `core/forecast.py` + `state_planner.plan_reserve` used by the planner.
///
/// The planner stops at (limit − reserve); school truth still uses the
/// real limit. A hand-built forecast without reserve data falls back to
/// the school values (see [effectivePlanLimit]/[effectivePlanSafe]).
double planLimit(double limitPct, double reservePct) {
  final reserve = reservePct.isNaN ? 10.0 : math.max(0.0, reservePct);
  return math.max(0.0, limitPct - reserve);
}

/// Clamp for the `absence_plan_reserve_pct` setting. NaN/non-finite and
/// negatives fall back to 10.0 (mirrors `plan_reserve`).
double clampReserve(Object? value) {
  if (value is num && value.isFinite) {
    return math.max(0.0, value.toDouble());
  }
  return 10.0;
}

/// Validation for the reserve setting (port of `validate_config` parts).
/// Returns an error path, or null when valid.
String? validateReserve(Object? value) {
  if (value is! num || !value.isFinite || value < 0) {
    return 'absence_plan_reserve_pct';
  }
  return null;
}

/// Minimal forecast subject for the planner view/tests.
class PlanSubject {
  final String name;
  final double currentPct;
  final double limitPct;
  final double safeHoursLeft;
  final double? planLimitPct;
  final double? planSafeHoursLeft;

  const PlanSubject({
    required this.name,
    required this.currentPct,
    required this.limitPct,
    required this.safeHoursLeft,
    this.planLimitPct,
    this.planSafeHoursLeft,
  });

  /// Effective planning limit: reserve applied, else the school limit
  /// (hand-built states without reserve data fall back, see
  /// test_handbuilt_states_fall_back_to_school_values).
  double get effectivePlanLimit => planLimitPct ?? limitPct;

  double get effectivePlanSafe => planSafeHoursLeft ?? safeHoursLeft;

  /// School status: still uses the real limit.
  String get status => currentPct >= limitPct ? 'critical' : 'ok';

  /// Planning status: uses the reserve-lowered limit.
  String get planStatus =>
      currentPct >= effectivePlanLimit ? 'critical' : 'ok';
}

/// Applies the reserve to a list of subjects (port of
/// `forecast_all(..., reserve_pct=...)` reserve parts).
List<PlanSubject> applyReserve(
    List<PlanSubject> states, double reservePct) {
  final reserve = clampReserve(reservePct);
  return [
    for (final s in states)
      PlanSubject(
        name: s.name,
        currentPct: s.currentPct,
        limitPct: s.limitPct,
        safeHoursLeft: s.safeHoursLeft,
        planLimitPct: planLimit(s.limitPct, reserve),
        planSafeHoursLeft:
            math.max(0.0, s.safeHoursLeft - reserve),
      ),
  ];
}

/// '1 den' / '3 dny' / '5 dní' (Czech plural rules; English 1/other).
String daysText(int n) {
  if (Strings.lang == 'en') {
    return Strings.format('days_many', {'n': n});
  }
  if (n == 1) return Strings.format('days_one', {'n': n});
  if (n >= 2 && n <= 4) return Strings.format('days_few', {'n': n});
  return Strings.format('days_many', {'n': n});
}

/// Budget hours for display: floored, never negative ('3', '0').
String hoursText(double value) {
  return '${math.max(0, (value + 1e-9).floor())}';
}

/// '1.–3., 5.' — the chosen lessons as runs over the day's lessons.
String runsLabel(List<int> order, Set<int> chosen) {
  final runs = <List<int>>[];
  var current = <int>[];
  for (final period in order) {
    if (chosen.contains(period)) {
      current.add(period);
    } else if (current.isNotEmpty) {
      runs.add(current);
      current = [];
    }
  }
  if (current.isNotEmpty) runs.add(current);
  return runs
      .map((r) => r.length == 1 ? '${r[0]}.' : '${r[0]}.–${r.last}.')
      .join(', ');
}

/// Adds [delta] months to the first of [month].
DateTime monthAdd(DateTime month, int delta) {
  final idx = month.year * 12 + (month.month - 1) + delta;
  return DateTime(idx ~/ 12, idx % 12 + 1, 1);
}

// ---------------------------------------------------------------------------
// Excuse-template helpers (port of planner._template_options/_template_labels
// and the signature handling covered by test_ui_views).
// ---------------------------------------------------------------------------

String templateName(Object? template) {
  if (template is Map) {
    final name = template['name'];
    return name == null ? '' : '$name'.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
  return '';
}

String templateTextOf(Object? template) {
  if (template is Map) {
    final text = template['text'];
    return text == null ? '' : '$text';
  }
  return template.toString();
}

/// `(name, text)` excuse templates, optionally filtered to a task kind.
/// Falls back to all templates when the kind list is empty; unnamed
/// templates carry name ''. Mirrors `_template_options`.
List<MapEntry<String, String>> templateOptions(
  Map<String, dynamic> config, {
  String? kind,
  String? signature,
}) {
  final k = (kind ?? '').toLowerCase();
  List<String> keys;
  if (k == 'late') {
    keys = ['late_income_excuses'];
  } else if (k == 'soon' || k == 'early') {
    keys = ['left_soon_excuses'];
  } else if (k == 'short') {
    keys = ['short_absence_excuses'];
  } else if (k == 'long' || k == 'day') {
    keys = ['long_absence_excuses'];
  } else {
    keys = [
      'long_absence_excuses',
      'short_absence_excuses',
      'late_income_excuses',
      'left_soon_excuses',
    ];
  }

  List<MapEntry<String, String>> collect(List<String> listKeys) {
    final out = <MapEntry<String, String>>[];
    for (final key in listKeys) {
      final values = config[key];
      if (values is List) {
        for (final v in values) {
          final text = templateTextOf(v).trim();
          if (text.isNotEmpty) {
            out.add(MapEntry(templateName(v), templateTextOf(v)));
          }
        }
      }
    }
    return out;
  }

  var found = collect(keys);
  if (found.isEmpty && keys.length == 1) {
    found = collect([
      'long_absence_excuses',
      'short_absence_excuses',
      'late_income_excuses',
      'left_soon_excuses',
    ]);
  }
  final sig = (signature ?? '').trim();
  if (sig.isNotEmpty) {
    // Never duplicate a signature the template already ends with
    // (case-insensitive).
    found = [
      for (final e in found)
        MapEntry(
          e.key,
          e.value.toLowerCase().contains(sig.toLowerCase())
              ? e.value
              : '${e.value.trimRight()}\n$sig',
        ),
    ];
  }
  if (found.isEmpty) {
    return [MapEntry('', Strings.get('default_excuse_template'))];
  }
  return found;
}

/// Dropdown labels: the user's name, `template_n` for unnamed ones.
List<MapEntry<String, String>> templateLabels(
    List<MapEntry<String, String>> options) {
  return [
    for (var i = 0; i < options.length; i++)
      MapEntry('$i',
          options[i].key.isNotEmpty
              ? options[i].key
              : '${Strings.get('template_n')} ${i + 1}'),
  ];
}

/// Normalizes one planned entry map. Returns null when invalid.
/// Port of `planned_skips.normalize_planned_entry` (whole/partial days).
Map<String, dynamic>? normalizePlannedEntry(Map<String, dynamic> raw) {
  final start = '${raw['start_date'] ?? ''}';
  final end = '${raw['end_date'] ?? ''}';
  if (start.isEmpty || end.isEmpty) return null;
  DateTime startDate;
  DateTime endDate;
  try {
    startDate = DateTime.parse(start);
    endDate = DateTime.parse(end);
  } catch (_) {
    return null;
  }
  if (endDate.isBefore(startDate)) return null;
  int? period(Object? v) {
    if (v == null) return null;
    final n = int.tryParse('$v');
    return n;
  }

  final startP = period(raw['start_period']);
  final endP = period(raw['end_period']);
  if ((startP != null && startP < 1) || (endP != null && endP < 1)) {
    return null;
  }
  return {
    'start_date': start,
    'end_date': end,
    'start_period': startP,
    'end_period': endP,
    'template': '${raw['template'] ?? ''}',
    'cancel_lunch': raw['cancel_lunch'] != false,
  };
}

String entryStartIso(Map<String, dynamic> entry) =>
    '${entry['start_date'] ?? ''}';

String entryEndIso(Map<String, dynamic> entry) =>
    '${entry['end_date'] ?? ''}';

/// 'Mon 15.09.2026' / '15.09. – 17.09.' + optional period range.
String entryLabel(Map<String, dynamic> entry) {
  DateTime? start;
  DateTime? end;
  try {
    start = DateTime.parse(entryStartIso(entry));
    end = DateTime.parse(entryEndIso(entry));
  } catch (_) {
    return entryStartIso(entry).isEmpty ? '?' : entryStartIso(entry);
  }
  String base;
  if (start == end) {
    base =
        '${_weekdayShort(start.weekday)} ${_czDay(start)}';
  } else {
    base = '${_czDay(start)} – ${_czDay(end)}';
  }
  int? sp;
  int? ep;
  try {
    final v = entry['start_period'];
    sp = v == null ? null : int.parse('$v');
    final w = entry['end_period'];
    ep = w == null ? null : int.parse('$w');
  } catch (_) {
    sp = null;
    ep = null;
  }
  if (sp == null && ep == null) return base;
  return '$base · ${_periodLabel(sp, ep)}';
}

String _periodLabel(int? start, int? end) {
  if (start == null && end == null) return Strings.get('whole_day');
  if (start != null && end != null) {
    if (start == end) return '$start.';
    return '$start.–$end.';
  }
  if (start != null) return '${Strings.get('custom_from_lesson')} $start.';
  return '${Strings.get('custom_to_lesson')} $end.';
}

String _czDay(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _weekdayShort(int weekday) {
  const cs = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];
  const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return (Strings.lang == 'en' ? en : cs)[weekday - 1];
}
