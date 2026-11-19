// Live wiring of the unified Absences & Planner screen to the shared AppState.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/app_state.dart' hide PlannerController;

import '../common/app_tokens.dart';
import '../planner/planner_live.dart';
import 'absences_controller.dart';
import 'absences_view.dart';

/// Builds a snapshot [AbsencesController] from the shared [AppState].
AbsencesController absencesControllerFor(AppState s, [DateTime? now]) {
  final c = AbsencesController();
  c.demoMode = s.demoMode;
  c.updatedLabel = s.updatedLabel;
  final rawLimits = s.get('subject_limits', {});
  c.hasSubjectLimits = rawLimits is Map && rawLimits.isNotEmpty;
  final rawDefaultLimit = s.get('absence_critical_pct', 25.0);
  c.defaultLimitPct = rawDefaultLimit is num
      ? rawDefaultLimit.toDouble()
      : double.tryParse('$rawDefaultLimit') ?? 25.0;
  final (states, _) = s.subjectStates();
  c.subjects = [
    for (final st in states)
      SubjectAbsence(
        name: st.name,
        currentPct: st.currentPct,
        status: st.status,
        limitPct: st.limitPct,
        effectivePlanLimit: st.effectivePlanLimit,
        effectivePlanSafe: st.effectivePlanSafe,
      ),
  ];
  try {
    final yp = s.yearPlan(now);
    final term = yp.term(s.plannerTerm) ?? yp.defaultTerm;
    if (term != null && term.hasData) {
      c.budgets = {
        for (final e in term.budgetByCanon.entries)
          e.key: SubjectBudget(
            freeHours: e.value.freeHours,
            planned: e.value.planned,
            projectedPct: e.value.projectedPct,
          ),
      };
    }
  } catch (_) {
    c.budgets = null;
  }
  return c;
}

/// The unified Absences route: rebuilds whenever the shared state emits.
class LiveAbsencesView extends ConsumerWidget {
  final AppTokens? tokens;
  final bool narrow;
  final DateTime? now;

  const LiveAbsencesView({
    super.key,
    this.tokens,
    this.narrow = false,
    this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final tok = tokens ?? s.appTokens;
    final absController = absencesControllerFor(s, now);
    final planner = plannerControllerFor(s);
    final hasTimetable = s.timetable().isNotEmpty;
    final planData =
        hasTimetable && absController.subjects.isNotEmpty
            ? yearPlanDataFor(s, now)
            : null;
    if (planData != null) {
      final term = planData.term(planner.plannerTerm) ?? planData.defaultTerm;
      if (term != null && term.hasData && term.recommended.isNotEmpty) {
        s.tutorialOffer('absences');
      }
    }
    return AbsencesView(
      controller: absController,
      tokens: tok,
      narrow: narrow,
      planner: planner,
      plan: planData,
      hasTimetable: hasTimetable,
      calendarSummary: calendarSummaryFor(s),
      stravaOn: s.stravaEnabled(),
      impactOf: (entry) => convertPlannerImpacts(
        s.planImpact(
          '${entry['start_date'] ?? ''}',
          '${entry['end_date'] ?? ''}',
          entry['start_period'] as int?,
          entry['end_period'] as int?,
          now,
        ),
      ),
      impactOfEntries: (entries) => convertPlannerImpacts(
        s.planImpactEntries([
          for (final e in entries) Map<String, Object?>.of(e),
        ], now),
      ),
      lessonsFor: (day) => s.pickerSlotsFor(day, now),
      freeDays: () => s.calendarData().dates,
      onOpenCalendar: () {
        s.setSettingsSection('calendar');
        s.go('settings');
      },
      onOpenLimits: () {
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go('/absences/limits');
        } else {
          s.go('absences/limits');
        }
      },
      tutorialEvent: s.tutorialEvent,
    );
  }
}
