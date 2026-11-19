// Bridges [AppState] (Riverpod) to [PlannerController] / [PlannerPage].
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart' hide PlannerController;
import '../../l10n/strings.dart';
import '../common/app_tokens.dart';
import 'planner_controller.dart';
import 'planner_view.dart';

void _syncFromState(PlannerController c, AppState s) {
  c.plannedSkips
    ..clear()
    ..addAll([for (final e in s.plannedSkips) Map<String, dynamic>.of(e)]);
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
  c.showAllPicks = s.plannerShowAllPicks;
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
  c.toggleShowAllPicksHook = () {
    s.togglePlannerShowAllPicks();
    _syncFromState(c, s);
  };
  c.planCustomSkipHook =
      (
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

DayOptionData _dayOption(core.DayOption o) => DayOptionData(
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
  lateWeek: o.lateWeek,
);

/// Converts [AppState.yearPlan] into [YearPlanData] for [PlannerSections].
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
        recommended: [for (final o in t.recommended) _dayOption(o)],
        options: {
          for (final e in t.options.entries) e.key: _dayOption(e.value),
        },
        planned: [
          for (final p in t.planned)
            PlannedRowData(
              entry: Map<String, dynamic>.of(p.entry),
              days: p.days.keys.toList()..sort(),
              costHours: p.hours,
              over: p.over.isNotEmpty,
              reserve: p.reserve.isNotEmpty,
              costSum: p.cost.values.fold(0, (a, b) => a + b),
              overNames: [
                for (final c in p.over)
                  if (t.budgetByCanon[c] != null) t.budgetByCanon[c]!.name,
              ],
              reserveNames: [
                for (final c in p.reserve)
                  if (t.budgetByCanon[c] != null) t.budgetByCanon[c]!.name,
              ],
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

/// Converts raw core impact rows into view [ImpactTerm] entries.
List<ImpactTerm> convertPlannerImpacts(List<(Object?, List<Object?>)> raw) {
  final out = <ImpactTerm>[];
  for (final (termObj, rowsObj) in raw) {
    final key = termObj is core.TermPlan ? termObj.key : 'sem1';
    final label = key == 'sem1'
        ? Strings.get('term_sem1')
        : Strings.get('term_sem2');
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

/// Formats the school calendar summary footer line for [s].
String calendarSummaryFor(AppState s) {
  try {
    final (presetN, addedN, forcedN, sem1, sem2) = s.calendarSummary();
    return '${Strings.format('cal_summary', {'preset': presetN, 'added': addedN, 'forced': forcedN})}'
        ' · ${Strings.format('cal_closes', {'a': sem1.isEmpty ? Strings.get('cal_auto') : sem1, 'b': sem2.isEmpty ? Strings.get('cal_auto') : sem2})}';
  } catch (_) {
    return '';
  }
}

/// Live Plánovač sub-route (`/absences/plan`) wired to [appStateProvider].
class LivePlannerPage extends ConsumerWidget {
  final AppTokens? tokens;
  final bool narrow;
  final DateTime? now;
  final VoidCallback? onBack;

  const LivePlannerPage({
    super.key,
    this.tokens,
    this.narrow = false,
    this.now,
    this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final tok = tokens ?? s.appTokens;
    final planner = plannerControllerFor(s);
    final hasTimetable = s.timetable().isNotEmpty;
    final (states, _) = s.subjectStates();
    final hasData = hasTimetable && states.isNotEmpty;
    final planData = hasData ? yearPlanDataFor(s, now) : null;
    if (planData != null) {
      final term = planData.term(planner.plannerTerm) ?? planData.defaultTerm;
      if (term != null && term.hasData && term.recommended.isNotEmpty) {
        s.tutorialOffer('absences_plan');
      }
    }
    return PlannerPage(
      controller: planner,
      tokens: tok,
      plan: planData,
      hasTimetable: hasTimetable,
      hasData: hasData,
      demoMode: s.demoMode,
      calendarSummary: calendarSummaryFor(s),
      stravaOn: s.stravaEnabled(),
      narrow: narrow,
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
      monthSlotsFor: (month) => s.pickerSlotsForMonth(month, now),
      freeDays: () => s.calendarData().dates,
      onOpenCalendar: () {
        s.setSettingsSection('calendar');
        s.go('settings');
      },
      onBack: onBack,
      tutorialEvent: s.tutorialEvent,
    );
  }
}
