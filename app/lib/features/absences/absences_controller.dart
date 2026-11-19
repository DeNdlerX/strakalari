import 'package:flutter/foundation.dart';

import '../../l10n/strings.dart';
import '../common/format.dart';

/// One subject's absence state — the fields `views/absences.py` reads
/// off `SubjectState` (`name`, `current_pct`, `status`, `limit_pct`,
/// `effective_plan_limit`, `effective_plan_safe`).
class SubjectAbsence {
  final String name;
  final double currentPct;

  /// `ok | warning | critical`.
  final String status;
  final double limitPct;
  final double effectivePlanLimit;
  final int effectivePlanSafe;

  const SubjectAbsence({
    required this.name,
    required this.currentPct,
    required this.status,
    required this.limitPct,
    required this.effectivePlanLimit,
    required this.effectivePlanSafe,
  });
}

/// Planner budget for one subject (`term.budget_by_canon` rows:
/// `free_hours`, `planned`, `projected_pct`).
class SubjectBudget {
  final int freeHours;
  final double planned;
  final double projectedPct;

  const SubjectBudget({
    required this.freeHours,
    required this.planned,
    required this.projectedPct,
  });
}

/// Absences (Absence) screen state + logic — a `ChangeNotifier` port
/// of `views/absences.py` (the `subject_states()` computation itself is
/// the planner domain and arrives via [subjects]; this file ports the
/// view-side aggregation and detail lines exactly).
class AbsencesController extends ChangeNotifier {
AbsencesController();

  /// Per-subject absence states (planner domain input).
  List<SubjectAbsence> subjects = [];

  /// Planner budgets keyed by canonical subject name
  /// (`term.budget_by_canon`; null = no data).
  Map<String, SubjectBudget>? budgets;

  bool demoMode = false;

  /// `updated_label` text (unused by the layout but kept for parity).
  String updatedLabel = '';

  /// Whether at least one per-subject limit is set in `subject_limits`.
  bool hasSubjectLimits = false;

  /// Default per-subject critical absence limit (`absence_critical_pct`).
  double defaultLimitPct = 25.0;

  /// Mean of subject percents — like `sum(s.current_pct) / len(states)`.
  double get average => subjects.isEmpty
      ? 0.0
      : subjects.map((e) => e.currentPct).reduce((a, b) => a + b) /
          subjects.length;

  int get warnCount =>
      subjects.where((e) => e.status == 'warning').length;

  int get critCount =>
      subjects.where((e) => e.status == 'critical').length;

  /// Detail line under the subject name — like `absences._detail`.
  /// With a planner budget: `Limit: X % · N h volno · … · na konci ~P %`;
  /// otherwise: `Limit: X % · Bezpečně do: Y % · Zbývá hodin: Z`.
  String detail(SubjectAbsence subject) {
    final budget = budgets?[canonSubject(subject.name)];
    if (budget == null) {
      return '${Strings.get('col_limit')}: ${gFormat(subject.limitPct)} % · '
          '${Strings.get('safe_to')}: ${gFormat(subject.effectivePlanLimit)} % · '
          '${Strings.get('col_safe')}: ${subject.effectivePlanSafe}';
    }
    final parts = <String>[
      '${Strings.get('col_limit')}: ${gFormat(subject.limitPct)} %',
      Strings.format('hours_free', {'n': budget.freeHours}),
    ];
    if (budget.planned != 0) {
      parts.add(
          '${Strings.get('legend_planned')}: ${budget.planned.toInt()} h');
    }
    parts.add(Strings.format('budget_end', {
      'p': budget.projectedPct.toStringAsFixed(1),
    }));
    return parts.join(' · ');
  }

  /// Canonical subject name for budget lookup —
  /// like `forecast.canon_subject` (lowercase, whitespace-collapsed).
  static String canonSubject(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
