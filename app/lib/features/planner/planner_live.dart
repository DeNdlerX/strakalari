// Bridges [AppState] (Riverpod) to [PlannerController] / [PlannerView].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart' hide PlannerController;
import '../../l10n/strings.dart';
import 'planner_controller.dart';
import 'planner_view.dart';

void _syncFromState(PlannerController c, AppState s) {
  c.plannedSkips
    ..clear()
    ..addAll([
      for (final e in s.plannedSkips) Map<String, dynamic>.of(e),
    ]);
  c.cancelledLunches
    ..clear()
    ..addAll(s.cancelledLunches);
  c.orders
    ..clear()
    ..addAll(s.orders);
  c.pendingOrders
    ..clear()
    ..addAll(s.pendingOrders);
  c.plannerTerm = s.plannerTerm;
  c.stravaEnabled = s.stravaEnabled();
}

/// Builds a [PlannerController] populated from [s] and wired so
/// plan/unplan/target/term actions mutate [s] directly.
PlannerController plannerControllerFor(AppState s) {
  final c = PlannerController(
    Map<String, dynamic>.of(s.config.data),
    onTutorialEvent: s.tutorialEvent,
    isLunchOpen: s.isLunchOrderOpen,
  );
  _syncFromState(c, s);

  c.setPlannerTargetHook = (days) {
    final ok = s.setPlannerTarget(days);
    _syncFromState(c, s);
    return ok;
  };
  c.selectPlannerTermHook = (key) {
    s.selectPlannerTerm(key);
    _syncFromState(c, s);
  };
  c.planCustomSkipHook = (
    startIso,
    endIso,
    startPeriod,
    endPeriod,
    template, {
    required cancelLunch,
  }) {
    final ok = s.planCustomSkip(
      startIso,
      endIso,
      startPeriod,
      endPeriod,
      template,
      cancelLunch: cancelLunch,
    );
    _syncFromState(c, s);
    return ok;
  };
  c.planEntriesHook = (rawEntries) {
    final n = s.planEntries([
      for (final r in rawEntries) Map<String, Object?>.of(r),
    ]);
    _syncFromState(c, s);
    return n;
  };
  c.unplanEntryHook = (entry) {
    final ok = s.unplanEntry(Map<String, Object?>.of(entry));
    _syncFromState(c, s);
    return ok;
  };
  return c;
}

/// Converts [AppState.yearPlan] into [YearPlanData] for [PlannerView].
YearPlanData? yearPlanDataFor(AppState s, [DateTime? now]) {
  if (s.timetable().isEmpty) return null;
  final plan = s.yearPlan(now);
  final terms = <TermPlanData>[
    for (final t in plan.terms)
      TermPlanData(
        key: t.key,
        start: t.start,
        close: t.close,
        capacity: t.capacity,
        plannedDates: t.plannedDates,
        remainingDays: t.remainingDays,
        fastPace: [for (final b in t.fastPace) b.name],
        tightest: t.tightest == null
            ? null
            : TightestData(
                name: t.tightest!.name,
                free: t.tightest!.free,
                status: t.tightest!.status,
              ),
        budgets: [
          for (final b in t.budgets)
            BudgetRowData(
              name: b.name,
              missed: b.missed,
              planned: b.planned,
              free: b.free,
              buffer: b.buffer,
              schoolCap: b.schoolCap,
              schoolLeft: b.schoolLeft,
              projectedPct: b.projectedPct,
              limitPct: b.limitPct,
              status: b.status,
            ),
        ],
        recommended: [
          for (final o in t.recommended)
            DayOptionData(
              day: o.day,
              lessonsCount: o.lessonsCount,
              cost: o.budgetHours.toDouble(),
              budgetHours: o.budgetHours.toDouble(),
              tags: o.tags,
              streak: o.streak,
              feasible: o.feasible,
              blockedNames: o.names,
              blockedBy: o.blockedBy,
              lessons: o.lessons,
              finalWeek: o.finalWeek,
            ),
        ],
        planned: [
          for (final p in t.planned)
            PlannedRowData(
              entry: Map<String, dynamic>.of(p.entry),
              days: p.days.keys.toList()..sort(),
              costHours: p.hours,
              over: p.over.isNotEmpty,
              reserve: p.reserve.isNotEmpty,
            ),
        ],
        hasData: t.hasData,
        active: t.active,
      ),
  ];
  return YearPlanData(
    today: plan.today,
    firstDay: plan.firstDay,
    holidays: plan.holidays,
    freeLabels: plan.freeLabels,
    terms: terms,
    lessonsOn: (day) => plan.lessonsOn(day).length,
  );
}

List<ImpactTerm> _convertImpacts(List<(Object?, List<Object?>)> raw) {
  final out = <ImpactTerm>[];
  for (final (termObj, rowsObj) in raw) {
    final key = termObj is core.TermPlan ? termObj.key : 'sem1';
    final label =
        key == 'sem1' ? Strings.get('term_sem1') : Strings.get('term_sem2');
    final rows = <ImpactRowData>[
      for (final r in rowsObj)
        if (r is core.ImpactRow)
          ImpactRowData(
            name: r.name,
            cost: r.cost.toDouble(),
            freeAfter: r.freeAfter,
            projectedAfter: r.projectedAfter,
            level: r.level,
          ),
    ];
    out.add(ImpactTerm(label, rows));
  }
  return out;
}

/// Live Riverpod-backed Planner screen.
class LivePlannerView extends ConsumerWidget {
  final bool narrow;
  final DateTime? now;

  const LivePlannerView({
    super.key,
    this.narrow = false,
    this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final controller = plannerControllerFor(s);
    final hasTimetable = s.timetable().isNotEmpty;
    final (states, _) = hasTimetable
        ? s.subjectStates()
        : (<core.SubjectState>[], <DateTime>[]);
    final hasData = hasTimetable && states.isNotEmpty;
    final planData = hasData ? yearPlanDataFor(s, now) : null;

    if (planData != null) {
      final term =
          planData.term(controller.plannerTerm) ?? planData.defaultTerm;
      if (term != null && term.hasData && term.recommended.isNotEmpty) {
        s.tutorialOffer('planner');
      }
    }

    var calSummary = '';
    try {
      final (presetN, addedN, forcedN, sem1, sem2) = s.calendarSummary();
      calSummary =
          '${Strings.format('cal_summary', {'preset': presetN, 'added': addedN, 'forced': forcedN})}'
          ' · ${Strings.format('cal_closes', {
        'a': sem1.isEmpty ? Strings.get('cal_auto') : sem1,
        'b': sem2.isEmpty ? Strings.get('cal_auto') : sem2,
      })}';
    } catch (_) {
      calSummary = '';
    }

    return PlannerView(
      controller: controller,
      plan: planData,
      hasTimetable: hasTimetable,
      hasData: hasData,
      updatedLabel: s.updatedLabel,
      calendarSummary: calSummary,
      stravaOn: s.stravaEnabled(),
      narrow: narrow,
      impactOf: (entry) => _convertImpacts(
        s.planImpact(
          '${entry['start_date'] ?? ''}',
          '${entry['end_date'] ?? ''}',
          entry['start_period'] as int?,
          entry['end_period'] as int?,
          now,
        ),
      ),
      impactOfEntries: (entries) => _convertImpacts(
        s.planImpactEntries(
          [for (final e in entries) Map<String, Object?>.of(e)],
          now,
        ),
      ),
      freeDays: () => s.calendarData().dates,
      onOpenAbsences: () => s.go('absences'),
      onOpenCalendar: () {
        s.setSettingsSection('calendar');
        s.go('settings');
      },
      tutorialEvent: s.tutorialEvent,
    );
  }
}
