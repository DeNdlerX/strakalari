import 'package:clock/clock.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:app/widgets/app_widgets.dart' as w;
import 'package:app/features/common/app_tokens.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/features/planner/plan_reserve.dart';
import 'package:app/features/planner/planner_controller.dart';
import 'package:app/widgets/overlays.dart';

/// Impact preview row for one subject (port of core planner ImpactRow).
class ImpactRowData {
  final String name;
  final double cost;
  final double freeAfter;
  final double projectedAfter;
  final String level; // ok | reserve | over

  const ImpactRowData({
    required this.name,
    required this.cost,
    required this.freeAfter,
    required this.projectedAfter,
    required this.level,
  });
}

/// One term of an impact preview: (term label, rows).
class ImpactTerm {
  final String label;
  final List<ImpactRowData> rows;

  const ImpactTerm(this.label, this.rows);
}

/// One per-subject budget bar (port of core planner budget rows).
class BudgetRowData {
  final String name;
  final double missed;
  final double planned;
  final double free;
  final double buffer;
  final double schoolCap;
  final double schoolLeft;
  final double projectedPct;
  final double limitPct;
  final String status; // ok | tight | reserve | over

  const BudgetRowData({
    required this.name,
    required this.missed,
    required this.planned,
    required this.free,
    required this.buffer,
    required this.schoolCap,
    required this.schoolLeft,
    required this.projectedPct,
    required this.limitPct,
    required this.status,
  });
}

/// One recommended / overview day.
class DayOptionData {
  final DateTime day;
  final int lessonsCount;
  final double cost;
  final double budgetHours;
  final List<String>
  tags; // bridge | long_weekend | light | free | final_week | late_week
  final int streak;
  final bool feasible;
  final Map<String, String> blockedNames;
  final List<String> blockedBy;
  final List<String> lessons;
  final bool finalWeek;
  final bool lateWeek;

  const DayOptionData({
    required this.day,
    this.lessonsCount = 0,
    this.cost = 0,
    this.budgetHours = 0,
    this.tags = const [],
    this.streak = 0,
    this.feasible = true,
    this.blockedNames = const {},
    this.blockedBy = const [],
    this.lessons = const [],
    this.finalWeek = false,
    this.lateWeek = false,
  });
}

/// One planned entry row with its computed cost.
class PlannedRowData {
  final Map<String, dynamic> entry;
  final List<DateTime> days;
  final int costHours;
  final bool over;
  final bool reserve;

  /// Sum of the per-subject hours it costs (Python `sum(row.cost.values())`).
  final int costSum;

  /// Display names of the subjects past the limit / eating the buffer.
  final List<String> overNames;
  final List<String> reserveNames;

  const PlannedRowData({
    required this.entry,
    required this.days,
    this.costHours = 0,
    this.over = false,
    this.reserve = false,
    this.costSum = 0,
    this.overNames = const [],
    this.reserveNames = const [],
  });
}

/// One semester of the year plan.
class TermPlanData {
  final String key;
  final DateTime start;
  final DateTime close;
  final int capacity;
  final Set<DateTime> plannedDates;
  final List<DateTime> remainingDays;
  final List<String> fastPace;
  final TightestData? tightest;
  final List<BudgetRowData> budgets;
  final List<DayOptionData> recommended;
  final Map<DateTime, DayOptionData> options;
  final List<PlannedRowData> planned;
  final bool hasData;
  final bool active;

  const TermPlanData({
    required this.key,
    required this.start,
    required this.close,
    this.capacity = 0,
    this.plannedDates = const {},
    this.remainingDays = const [],
    this.fastPace = const [],
    this.tightest,
    this.budgets = const [],
    this.recommended = const [],
    this.options = const {},
    this.planned = const [],
    this.hasData = false,
    this.active = false,
  });
}

class TightestData {
  final String name;
  final double free;
  final String status;

  const TightestData({
    required this.name,
    required this.free,
    required this.status,
  });
}

/// Whole-year plan (core-backed later; tests hand-build it).
class YearPlanData {
  final DateTime today;
  final DateTime firstDay;
  final Set<DateTime> holidays;
  final Map<DateTime, String> freeLabels;
  final List<TermPlanData> terms;
  final int Function(DateTime day) lessonsOn;

  const YearPlanData({
    required this.today,
    required this.firstDay,
    this.holidays = const {},
    this.freeLabels = const {},
    this.terms = const [],
    required this.lessonsOn,
  });

  TermPlanData? term(String? key) {
    for (final t in terms) {
      if (t.key == key) return t;
    }
    return null;
  }

  TermPlanData? get defaultTerm {
    for (final t in terms) {
      if (t.active) return t;
    }
    return terms.isEmpty ? null : terms.first;
  }
}

/// One lesson slot in the planner calendar / day dialog.
class PickerSlot {
  final int? period;
  final String subject;
  final String detail;
  final bool taught;
  final bool past;
  final bool planned;
  final bool changed;

  const PickerSlot({
    this.period,
    this.subject = '?',
    this.detail = '',
    this.taught = true,
    this.past = false,
    this.planned = false,
    this.changed = false,
  });

  bool get pickable => taught && period != null && !past && !planned;
}

/// Listens to [PlannerController] changes and rebuilds [builder].
class PlannerListener extends StatefulWidget {
  final PlannerController? controller;
  final WidgetBuilder builder;

  const PlannerListener({
    super.key,
    required this.controller,
    required this.builder,
  });

  @override
  State<PlannerListener> createState() => _PlannerListenerState();
}

class _PlannerListenerState extends State<PlannerListener> {
  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant PlannerListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onChanged);
      widget.controller?.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 4-color stacked hour-budget bar shared by the Absence subject list.
Widget plannerBudgetBar(Tokens tok, BudgetRowData b) {
  final over = b.status == 'over';
  final segments = <(double, Color)>[
    (b.missed, over ? tok.red : tok.muted),
    (b.planned, over ? tok.red : tok.accent),
    (b.free < 0 ? 0.0 : b.free, tok.green),
    (
      (b.buffer < b.schoolLeft ? b.buffer : b.schoolLeft).clamp(0.0, 1e9),
      tintColor(tok.yellow, 0.55),
    ),
  ];
  var total = b.schoolCap > b.missed + b.planned
      ? b.schoolCap
      : b.missed + b.planned;
  if (total < 0.1) total = 0.1;
  final parts = <Widget>[];
  var used = 0;
  for (final (hours, color) in segments) {
    final share = core.roundHalfEvenToInt(
      (hours < 0 ? 0.0 : hours) / total * 1000,
    );
    if (share <= 0) continue;
    used += share;
    parts.add(
      Expanded(
        flex: share,
        child: ColoredBox(color: color),
      ),
    );
  }
  if (used < 1000) {
    parts.add(Expanded(flex: 1000 - used, child: const SizedBox.shrink()));
  }
  return Container(
    height: 8,
    clipBehavior: Clip.hardEdge,
    decoration: BoxDecoration(
      color: tok.overlay,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: parts,
    ),
  );
}

DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);
DateTime _m(DateTime x) => DateTime(x.year, x.month, 1);

String _cz(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _costText(DayOptionData option) {
  final lessons = w.lessonsText(option.lessonsCount);
  if (option.cost == 0) {
    return '$lessons · ${Strings.get('day_cost_free')}';
  }
  return '$lessons · ${Strings.format('day_cost', {'n': option.budgetHours.round()})}';
}

/// Dedicated Plánovač sub-route (`/absences/plan`).
///
/// Holds the sub-page header with back arrow, term selector, compact 1-line
/// summary, warnings, single-month [PlannerMonthCalendar], recommended days
/// off, planned entries, and the school-calendar footer.
class PlannerPage extends StatelessWidget {
  final PlannerController controller;
  final AppTokens? tokens;
  final YearPlanData? plan;
  final bool hasTimetable;
  final bool hasData;
  final bool demoMode;
  final String calendarSummary;
  final bool stravaOn;
  final bool narrow;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final List<PickerSlot> Function(DateTime day)? lessonsFor;
  final Map<DateTime, List<PickerSlot>> Function(DateTime month)? monthSlotsFor;
  final Set<DateTime> Function()? freeDays;
  final VoidCallback? onOpenCalendar;
  final VoidCallback? onBack;
  final void Function(String template)? tutorialEvent;

  const PlannerPage({
    super.key,
    required this.controller,
    this.tokens,
    this.plan,
    this.hasTimetable = false,
    this.hasData = false,
    this.demoMode = false,
    this.calendarSummary = '',
    this.stravaOn = false,
    this.narrow = false,
    this.impactOf,
    this.impactOfEntries,
    this.lessonsFor,
    this.monthSlotsFor,
    this.freeDays,
    this.onOpenCalendar,
    this.onBack,
    this.tutorialEvent,
  });

  Tokens _tok(BuildContext context) => tokens ?? tokensOf(context);

  static String _termTitle(TermPlanData t) =>
      t.key == 'sem1' ? Strings.get('term_sem1') : Strings.get('term_sem2');

  static String _dayLabel(DateTime d) =>
      '${w.dayName(d)} ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    return PlannerListener(
      controller: controller,
      builder: (context) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final tok = _tok(context);
    final gap = narrow ? tok.gap * 0.75 : tok.gap;
    final blocks = <Widget>[
      Row(
        children: [
          IconButton(
            key: const Key('plan:back_btn'),
            icon: const Icon(Icons.arrow_back),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              Strings.get('planner_title'),
              style: TextStyle(
                color: tok.text,
                fontSize: tok.fsTitle,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    ];

    if (plan == null || !hasData) {
      blocks.add(w.EmptyState(text: Strings.get('no_data'), tok: tok));
      if (!hasTimetable) {
        blocks.add(_small(tok, Strings.get('planner_need_refresh')));
      } else if (demoMode) {
        blocks.add(_small(tok, Strings.get('need_credentials')));
      }
      return _scroll(tok, blocks, gap);
    }

    final p = plan!;
    final term = p.term(controller.plannerTerm) ?? p.defaultTerm;
    if (term == null) {
      blocks.add(
        w.AppCard(
          tok: tok,
          children: [
            _small(tok, Strings.get('term_nothing'), size: tok.fsBody),
          ],
        ),
      );
      blocks.addAll(_planned(context, tok, p));
      blocks.addAll(_footer(tok));
      return _scroll(tok, blocks, gap);
    }

    final compactStyle = narrow
        ? const ButtonStyle(
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            minimumSize: WidgetStatePropertyAll(Size(0, 36)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          )
        : null;
    final compactTextStyle = narrow ? TextStyle(fontSize: tok.fsSmall) : null;

    if (p.terms.length >= 2) {
      final termButtons = [
        for (final other in p.terms)
          () {
            final label =
                '${_termTitle(other)} · ${Strings.format('term_until', {'d': w.czDay(other.close)})}';
            void pick() => controller.selectPlannerTerm(other.key);
            final child = Text(
              label,
              style: compactTextStyle,
              textAlign: narrow ? TextAlign.center : null,
              maxLines: narrow ? 2 : null,
            );
            return other.key == term.key
                ? ElevatedButton(
                    style: compactStyle,
                    onPressed: pick,
                    child: child,
                  )
                : OutlinedButton(
                    style: compactStyle,
                    onPressed: pick,
                    child: child,
                  );
          }(),
      ];
      blocks.add(
        narrow
            ? Row(
                spacing: tok.gap / 2,
                children: [for (final b in termButtons) Expanded(child: b)],
              )
            : Wrap(
                spacing: tok.gap / 2,
                runSpacing: tok.gap / 2,
                children: termButtons,
              ),
      );
    }
    if (!term.hasData) {
      blocks.add(
        Text(
          Strings.get('term_fresh'),
          style: TextStyle(color: tok.accent, fontSize: tok.fsSmall),
        ),
      );
    }

    blocks.add(_summaryCard(tok, term));
    blocks.addAll(_warnings(tok, term));
    blocks.add(w.SectionHeader(Strings.get('section_overview'), tok: tok));
    blocks.add(
      TutorialAnchor(
        anchorKey: 'plan_strip',
        child: PlannerMonthCalendar(
          controller: controller,
          plan: p,
          term: term,
          stravaOn: stravaOn,
          lessonsFor: lessonsFor,
          monthSlotsFor: monthSlotsFor,
          freeDays: freeDays?.call() ?? p.holidays,
          impactOf: impactOf,
          impactOfEntries: impactOfEntries,
        ),
      ),
    );
    blocks.addAll(_recommended(context, tok, p, term));
    blocks.addAll(_planned(context, tok, p));
    blocks.addAll(_footer(tok));
    return _scroll(tok, blocks, gap);
  }

  Widget _summaryCard(Tokens tok, TermPlanData term) {
    final remaining = term.remainingDays.toSet();
    final plannedDays = term.plannedDates.intersection(remaining).length;
    final plannedHours = term.planned.fold(0, (sum, r) => sum + r.costHours);
    final line1 =
        '${Strings.get('stat_can_afford')}: ${daysText(term.capacity)} · '
        '${Strings.get('stat_planned')}: ${daysText(plannedDays)} ($plannedHours h) · '
        '${Strings.get('planner_horizon')}: ${term.remainingDays.length}';
    final tight = term.tightest;
    return Card(
      key: const Key('plan:summary'),
      color: tok.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tok.radiusMd),
        side: BorderSide(color: tok.border),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: tok.pad, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 3,
          children: [
            Text(
              line1,
              style: TextStyle(
                color: tok.text,
                fontSize: tok.fsSmall,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (tight != null)
              Text(
                '${Strings.get('stat_tightest')}: ${tight.name} (${Strings.format('hours_free', {'n': hoursText(tight.free)})})',
                style: TextStyle(color: tok.muted, fontSize: tok.fsTiny),
              ),
          ],
        ),
      ),
    );
  }

  Widget _scroll(Tokens tok, List<Widget> blocks, double gap) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          blocks[i],
          if (i != blocks.length - 1) SizedBox(height: gap),
        ],
        SizedBox(height: tok.pad * 2),
      ],
    );
  }

  Widget _small(Tokens tok, String text, {bool faint = true, double? size}) =>
      Text(
        text,
        style: TextStyle(
          color: faint ? tok.faint : tok.muted,
          fontSize: size ?? tok.fsSmall,
        ),
      );

  List<Widget> _warnings(Tokens tok, TermPlanData term) {
    final over = <String>{for (final r in term.planned) ...r.overNames}.toList()
      ..sort();
    final reserveSet = <String>{for (final r in term.planned) ...r.reserveNames}
      ..removeAll(over);
    final reserveW = reserveSet.toList()..sort();
    final fast = [...term.fastPace]..sort();
    final out = <Widget>[];
    if (over.isNotEmpty) {
      out.add(
        Text(
          Strings.format('warn_over', {'subjects': over.join(', ')}),
          style: TextStyle(color: tok.red, fontSize: tok.fsSmall),
        ),
      );
    }
    if (reserveW.isNotEmpty) {
      out.add(
        Text(
          Strings.format('warn_reserve', {'subjects': reserveW.join(', ')}),
          style: TextStyle(color: tok.yellow, fontSize: tok.fsSmall),
        ),
      );
    }
    if (fast.isNotEmpty) {
      out.add(
        Text(
          Strings.format('warn_pace', {'subjects': fast.join(', ')}),
          style: TextStyle(color: tok.yellow, fontSize: tok.fsSmall),
        ),
      );
    }
    return out.isEmpty ? const [] : [w.AppCard(tok: tok, children: out)];
  }

  Widget _tagBadge(Tokens tok, String tag, DayOptionData o) {
    switch (tag) {
      case 'bridge':
        return w.Badge(
          text: Strings.format('tag_bridge', {'n': o.streak}),
          tok: tok,
          kind: 'sent',
        );
      case 'long_weekend':
        return w.Badge(
          text: Strings.get('tag_long_weekend'),
          tok: tok,
          kind: 'ok',
        );
      case 'light':
        return w.Badge(text: Strings.get('tag_light'), tok: tok);
      case 'free':
        return w.Badge(text: Strings.get('tag_free'), tok: tok, kind: 'ok');
      case 'final_week':
        return w.Badge(
          text: Strings.get('tag_final_week'),
          tok: tok,
          kind: 'warning',
        );
      default:
        return w.Badge(
          text: Strings.get('tag_late_week'),
          tok: tok,
          kind: 'pending',
        );
    }
  }

  static String _subjectsText(List<String> names, [int limit = 6]) {
    final unique = {
      for (final n in names)
        if (n.trim().isNotEmpty) n,
    }.toList()..sort();
    if (unique.length > limit) return '${unique.take(limit).join('; ')} …';
    return unique.join('; ');
  }

  List<Widget> _recommended(
    BuildContext context,
    Tokens tok,
    YearPlanData p,
    TermPlanData term,
  ) {
    final picks = term.recommended;
    final heading = w.SectionHeader(
      '${Strings.get('section_plan')} (${picks.length})',
      tok: tok,
    );
    final actions = <Widget>[
      _targetDropdown(tok, term),
      if (picks.isNotEmpty)
        ElevatedButton.icon(
          onPressed: () =>
              showPlanAllDialog(context, [for (final o in picks) o.day]),
          icon: const Icon(Icons.done_all, size: 18),
          label: Text('${Strings.get('plan_all')} (${picks.length})'),
        ),
    ];
    final out = <Widget>[
      if (narrow) ...[
        heading,
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ] else
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 8,
          children: [
            Expanded(child: heading),
            ...actions,
          ],
        ),
    ];
    if (picks.isEmpty) {
      final already = term.plannedDates
          .intersection(term.remainingDays.toSet())
          .length;
      final target = controller.plannerTargetDays();
      final text = target > 0 && already >= target
          ? Strings.format('plan_target_met', {'n': already})
          : Strings.get('plan_budget_empty');
      out.add(
        w.AppCard(
          tok: tok,
          children: [
            Text(
              text,
              style: TextStyle(color: tok.faint, fontSize: tok.fsBody),
            ),
          ],
        ),
      );
      return out;
    }
    final showToggle = picks.length > 3;
    final visibleCount =
        (!showToggle || controller.showAllPicks) ? picks.length : 3;
    for (var i = 0; i < visibleCount; i++) {
      final option = picks[i];
      final lessonsToday = lessonsFor?.call(option.day) ?? const <PickerSlot>[];
      final taught = lessonsToday.where((s) => s.taught).toList();
      final today = clock.now();
      final Widget when;
      if (_d(option.day) == _d(today) && taught.isNotEmpty) {
        final left = taught.where((s) => !s.past).length;
        when = Text(
          Strings.format('today_left_note', {'n': left, 't': taught.length}),
          style: TextStyle(color: tok.yellow, fontSize: tok.fsSmall),
        );
      } else {
        when = Text(
          _costText(option),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        );
      }
      final card = w.AppCard(
        tok: tok,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 8,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _dayLabel(option.day),
                          style: TextStyle(
                            color: tok.text,
                            fontSize: tok.fsBody,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        for (final tag in option.tags)
                          _tagBadge(tok, tag, option),
                      ],
                    ),
                    when,
                    Text(
                      _subjectsText(option.lessons),
                      style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: () => showPlanDayDialog(
                  context,
                  option.day,
                  slots: lessonsFor?.call(option.day),
                  existingEntries: controller.plannedEntriesFor(_iso(option.day)),
                ),
                child: Text(Strings.get('plan_skip')),
              ),
            ],
          ),
        ],
      );
      out.add(
        i == 0 ? TutorialAnchor(anchorKey: 'plan_first', child: card) : card,
      );
    }
    if (showToggle) {
      out.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: controller.toggleShowAllPicks,
            child: Text(
              controller.showAllPicks
                  ? Strings.get('plan_show_less')
                  : Strings.format('plan_show_all', {'n': picks.length}),
            ),
          ),
        ),
      );
    }
    return out;
  }

  Widget _targetDropdown(Tokens tok, TermPlanData term) {
    final remaining = term.remainingDays.toSet();
    final already = term.plannedDates.where(remaining.contains).length;
    final maximum = already + term.capacity;
    final current = controller.plannerTargetDays();
    final top = [maximum, current, 1].reduce((a, b) => a > b ? a : b);
    final limit = top > 60 ? 60 : top;
    return SizedBox(
      width: 230,
      child: DropdownButtonFormField<int>(
        initialValue: current <= limit ? current : 0,
        isExpanded: true,
        dropdownColor: tok.card,
        decoration: InputDecoration(labelText: Strings.get('target_label')),
        items: [
          DropdownMenuItem(
            value: 0,
            child: Text(Strings.format('target_auto', {'n': maximum})),
          ),
          for (var i = 1; i <= limit; i++)
            DropdownMenuItem(value: i, child: Text(daysText(i))),
        ],
        onChanged: (v) {
          if (v != null) controller.setPlannerTarget(v);
        },
      ),
    );
  }

  List<Widget> _planned(BuildContext context, Tokens tok, YearPlanData p) {
    Map<String, Object?> raw(Map<String, dynamic> e) =>
        Map<String, Object?>.of(e);
    final planned = [...controller.plannedSkips]
      ..sort((a, b) {
        final x = core
            .entryStartIso(raw(a))
            .compareTo(core.entryStartIso(raw(b)));
        if (x != 0) return x;
        return core.entryEndIso(raw(a)).compareTo(core.entryEndIso(raw(b)));
      });
    final costs = <String, (int, bool, bool)>{};
    for (final term in p.terms) {
      for (final row in term.planned) {
        final key = '${core.normalizePlannedEntry(row.entry)}';
        final old = costs[key] ?? (0, false, false);
        costs[key] = (
          old.$1 + row.costSum,
          old.$2 || row.over,
          old.$3 || row.reserve,
        );
      }
    }
    final blocks = <Widget>[
      w.SectionHeader(
        '${Strings.get('planned_title')} (${planned.length})',
        tok: tok,
      ),
    ];
    if (planned.isEmpty) {
      blocks.add(
        w.AppCard(
          tok: tok,
          children: [
            Text(
              Strings.get('no_planned'),
              style: TextStyle(color: tok.faint, fontSize: tok.fsBody),
            ),
          ],
        ),
      );
      return blocks;
    }
    final today = _d(clock.now());
    for (final entry in planned) {
      final end = DateTime.tryParse(core.entryEndIso(raw(entry)));
      final isPast = end != null && _d(end).isBefore(today);
      final template = '${entry['template'] ?? ''}'.trim().split('\n').first;
      final preview = template.length > 80
          ? template.substring(0, 80)
          : template;
      final (hours, over, reserve) =
          costs['${core.normalizePlannedEntry(entry)}'] ?? (0, false, false);
      final badges = <Widget>[
        Text(
          entryLabel(entry),
          style: TextStyle(
            color: tok.text,
            fontSize: tok.fsBody,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (over && !isPast)
          w.Badge(text: Strings.get('budget_over'), tok: tok, kind: 'critical')
        else if (reserve && !isPast)
          w.Badge(
            text: Strings.get('budget_reserve'),
            tok: tok,
            kind: 'warning',
          ),
      ];
      final meta = [
        if (hours > 0 && !isPast) Strings.format('planned_cost', {'h': hours}),
        preview,
      ].where((x) => x.isNotEmpty).join(' · ');
      blocks.add(
        w.AppCard(
          tok: tok,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: badges,
                      ),
                      if (meta.isNotEmpty)
                        Text(
                          meta,
                          style: TextStyle(
                            color: tok.muted,
                            fontSize: tok.fsSmall,
                          ),
                        ),
                    ],
                  ),
                ),
                if (isPast)
                  w.Badge(
                    text: Strings.get('day_passed'),
                    tok: tok,
                    kind: 'pending',
                  )
                else
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: tok.red),
                    onPressed: () {
                      if (controller.unplanEntry(entry)) {
                        appSnack(context, Strings.get('plan_removed'));
                      } else {
                        appSnack(context, Strings.get('save_failed'));
                      }
                    },
                    child: Text(Strings.get('unplan')),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return blocks;
  }

  List<Widget> _footer(Tokens tok) => [
    _small(tok, Strings.get('holidays_note')),
    if (calendarSummary.isNotEmpty) _small(tok, calendarSummary),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        onPressed: onOpenCalendar,
        child: Text(Strings.get('cal_open_calendar')),
      ),
    ),
  ];

  Future<void> showPlanDayDialog(
    BuildContext context,
    DateTime day, {
    List<PickerSlot>? slots,
    List<Map<String, dynamic>> existingEntries = const [],
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => PlanDayDialog(
        controller: controller,
        day: day,
        stravaOn: stravaOn,
        isLunchOpen: controller.isLunchOpen,
        impactOf: impactOf,
        impactOfEntries: impactOfEntries,
        slots: slots,
        existingEntries: existingEntries,
      ),
    );
  }

  Future<void> showPlanAllDialog(BuildContext context, List<DateTime> days) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _PlanAllDialog(
        controller: controller,
        days: days,
        stravaOn: stravaOn,
      ),
    );
  }
}

/// Shows every planned entry touching a fully planned day, each with its own
/// independent *Zrušit plán* button (R3c M1).
Future<void> showPlannedDialog(
  BuildContext context,
  PlannerController controller,
  List<Map<String, dynamic>> entries,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _PlannedEntriesDialog(
      controller: controller,
      entries: entries,
    ),
  );
}

class _PlannedEntriesDialog extends StatefulWidget {
  final PlannerController controller;
  final List<Map<String, dynamic>> entries;

  const _PlannedEntriesDialog({
    required this.controller,
    required this.entries,
  });

  @override
  State<_PlannedEntriesDialog> createState() => _PlannedEntriesDialogState();
}

class _PlannedEntriesDialogState extends State<_PlannedEntriesDialog> {
  late final List<Map<String, dynamic>> _remaining = [
    for (final e in widget.entries) Map<String, dynamic>.of(e),
  ];

  @override
  Widget build(BuildContext context) {
    if (_remaining.length == 1) {
      final entry = _remaining.first;
      return AlertDialog(
        title: Text(entryLabel(entry)),
        content: Text('${entry['template'] ?? ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(Strings.get('cancel')),
          ),
          TextButton(
            onPressed: () {
              final ok = widget.controller.unplanEntry(entry);
              Navigator.of(context).pop();
              appSnack(
                context,
                ok ? Strings.get('plan_removed') : Strings.get('save_failed'),
              );
            },
            child: Text(Strings.get('unplan')),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(Strings.get('planned_title')),
      content: SizedBox(
        width: w.dialogWidth(context, 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              for (var i = 0; i < _remaining.length; i++)
                _entryCard(context, i, _remaining[i]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('close')),
        ),
      ],
    );
  }

  Widget _entryCard(
    BuildContext context,
    int index,
    Map<String, dynamic> entry,
  ) {
    final tpl = '${entry['template'] ?? ''}'.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    entryLabel(entry),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (tpl.isNotEmpty) Text(tpl),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                final ok = widget.controller.unplanEntry(entry);
                appSnack(
                  context,
                  ok ? Strings.get('plan_removed') : Strings.get('save_failed'),
                );
                if (!ok) return;
                if (_remaining.length <= 1) {
                  Navigator.of(context).pop();
                } else {
                  setState(() => _remaining.removeAt(index));
                }
              },
              child: Text(Strings.get('unplan')),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-month-at-a-time interactive planner calendar.
///
/// Replaces both the multi-month semester strip and the separate custom picker
/// dialog: shows past days greyed and non-tappable, resolves each cell from its
/// owning term (S2), computes one month slot map (S7, today always live S11),
/// handles fully and partly planned days from M2 slots (M1), and supports both
/// single-day tap and *Vybrat více dní* multi-day selection.
class PlannerMonthCalendar extends StatefulWidget {
  final PlannerController controller;
  final YearPlanData? plan;
  final TermPlanData? term;
  final bool stravaOn;
  final List<PickerSlot> Function(DateTime day)? lessonsFor;
  final Map<DateTime, List<PickerSlot>> Function(DateTime month)? monthSlotsFor;
  final Set<DateTime> freeDays;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final DateTime? initialMonth;
  final DateTime? firstMonth;
  final DateTime? lastMonth;

  const PlannerMonthCalendar({
    super.key,
    required this.controller,
    this.plan,
    this.term,
    this.stravaOn = false,
    this.lessonsFor,
    this.monthSlotsFor,
    this.freeDays = const {},
    this.impactOf,
    this.impactOfEntries,
    this.initialMonth,
    this.firstMonth,
    this.lastMonth,
  });

  @override
  State<PlannerMonthCalendar> createState() => _PlannerMonthCalendarState();
}

class _PlannerMonthCalendarState extends State<PlannerMonthCalendar> {
  late DateTime _month;
  bool _multiMode = false;
  final Set<DateTime> _selectedDays = {};
  final Map<DateTime, List<PickerSlot>> _selectedSlots = {};

  DateTime get _today => _d(widget.plan?.today ?? clock.now());

  DateTime? _firstMonthBound() {
    if (widget.firstMonth != null) return _m(widget.firstMonth!);
    final t = widget.term;
    if (t == null) return null;
    final schoolYear = t.start.month >= 8 ? t.start.year : t.start.year - 1;
    return DateTime(schoolYear, 9, 1);
  }

  DateTime? _lastMonthBound() {
    if (widget.lastMonth != null) return _m(widget.lastMonth!);
    final t = widget.term;
    if (t == null) return null;
    return _m(t.close);
  }

  DateTime _clampMonth(DateTime target, DateTime? minM, DateTime? maxM) {
    var out = _m(target);
    if (minM != null && out.isBefore(minM)) out = minM;
    if (maxM != null && out.isAfter(maxM)) out = maxM;
    return out;
  }

  @override
  void initState() {
    super.initState();
    final t = widget.term;
    if (widget.initialMonth != null) {
      _month = _m(widget.initialMonth!);
    } else if (t != null) {
      _month = _clampMonth(_m(_today), _m(t.start), _m(t.close));
    } else {
      _month = _m(_today);
    }
  }

  @override
  void didUpdateWidget(covariant PlannerMonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.term?.key != widget.term?.key && widget.term != null) {
      final t = widget.term!;
      _month = _clampMonth(_month, _m(t.start), _m(t.close));
      _selectedDays.clear();
      _selectedSlots.clear();
    }
  }

  TermPlanData? _owningTerm(DateTime day) {
    final p = widget.plan;
    if (p != null) {
      for (final t in p.terms) {
        if (!day.isBefore(_d(t.start)) && !day.isAfter(_d(t.close))) {
          return t;
        }
      }
    }
    final t = widget.term;
    if (t != null && !day.isBefore(_d(t.start)) && !day.isAfter(_d(t.close))) {
      return t;
    }
    return null;
  }

  DateTime? _earliestTermStart() {
    final p = widget.plan;
    if (p != null && p.terms.isNotEmpty) {
      var minStart = _d(p.terms.first.start);
      for (final t in p.terms.skip(1)) {
        final s = _d(t.start);
        if (s.isBefore(minStart)) minStart = s;
      }
      return minStart;
    }
    return widget.term != null ? _d(widget.term!.start) : null;
  }

  Map<DateTime, List<PickerSlot>>? _buildMonthSlots() {
    if (widget.monthSlotsFor != null) {
      return widget.monthSlotsFor!(_month);
    }
    if (widget.lessonsFor == null) return null;
    final out = <DateTime, List<PickerSlot>>{};
    var d = DateTime(_month.year, _month.month, 1);
    final end = monthAdd(_month, 1);
    while (d.isBefore(end)) {
      if (d.weekday <= DateTime.friday) {
        try {
          out[d] = widget.lessonsFor!(d);
        } catch (_) {
          out[d] = const [];
        }
      }
      d = core.addDays(d, 1);
    }
    return out;
  }

  void _toggleMultiDay(DateTime day, List<PickerSlot>? slots) {
    setState(() {
      if (_selectedDays.contains(day)) {
        _selectedDays.remove(day);
        _selectedSlots.remove(day);
      } else {
        _selectedDays.add(day);
        if (slots != null) {
          _selectedSlots[day] = slots;
        }
      }
    });
  }

  Map<DateTime, Set<int>> _pickedPeriodsForSelected(
    Map<DateTime, List<PickerSlot>>? monthSlots,
  ) {
    final picked = <DateTime, Set<int>>{};
    final sorted = _selectedDays.toList()..sort();
    for (final day in sorted) {
      final slots = monthSlots?[day] ?? _selectedSlots[day];
      if (slots != null) {
        final p = {for (final s in slots) if (s.pickable) s.period!};
        if (p.isNotEmpty) picked[day] = p;
      } else {
        picked[day] = {1};
      }
    }
    return picked;
  }

  Map<DateTime, Set<int>> _taughtPeriodsForSelected(
    Map<DateTime, List<PickerSlot>>? monthSlots,
  ) {
    final lessons = <DateTime, Set<int>>{};
    final sorted = _selectedDays.toList()..sort();
    for (final day in sorted) {
      final slots = monthSlots?[day] ?? _selectedSlots[day];
      if (slots != null) {
        final t = {
          for (final s in slots)
            if (s.taught && s.period != null) s.period!,
        };
        if (t.isNotEmpty) lessons[day] = t;
      } else {
        lessons[day] = {1};
      }
    }
    return lessons;
  }

  List<Map<String, dynamic>> _prospectiveMultiEntries(
    Map<DateTime, List<PickerSlot>>? monthSlots,
  ) {
    final picked = _pickedPeriodsForSelected(monthSlots);
    if (picked.isEmpty) return const [];
    final lessons = _taughtPeriodsForSelected(monthSlots);
    return core
        .entriesForSelection(
          picked: picked,
          lessons: lessons,
          template: '',
          cancelLunch: false,
        )
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  int _totalMultiHours(Map<DateTime, List<PickerSlot>>? monthSlots) {
    var total = 0;
    for (final day in _selectedDays) {
      final slots = monthSlots?[day] ?? _selectedSlots[day];
      if (slots != null) {
        total += slots.where((s) => s.pickable).length;
      } else {
        final cellTerm = _owningTerm(day);
        final opt = cellTerm?.options[day];
        if (opt != null) {
          total += opt.budgetHours.round();
        } else if (widget.plan != null) {
          total += widget.plan!.lessonsOn(day);
        }
      }
    }
    return total;
  }

  String _monthHeaderLabel() {
    final names = Strings.get('pick_months').split(',');
    if (_month.month >= 1 && _month.month <= names.length) {
      return '${names[_month.month - 1]} ${_month.year}';
    }
    return '${_month.month}/${_month.year}';
  }

  String _cellTip(
    DateTime day,
    String label,
    DayOptionData? option, {
    required bool isFree,
    required bool isFullyPlanned,
    required bool isPartlyPlanned,
    required int remainingPickable,
    required bool past,
    required bool recommended,
  }) {
    final p = widget.plan;
    if (isFree) {
      final free = p?.freeLabels[day];
      return '$label · ${free == null || free.isEmpty ? Strings.get('cal_tip_free') : free}';
    }
    if (isFullyPlanned) return '$label · ${Strings.get('cal_tip_planned')}';
    if (isPartlyPlanned) {
      return '$label · ${Strings.get('cal_tip_planned')} · ${w.lessonsText(remainingPickable)}';
    }
    if (past) return '$label · ${Strings.get('cal_tip_past')}';
    if (option == null) {
      final n = p?.lessonsOn(day) ?? 0;
      return n > 0 ? '$label · ${w.lessonsText(n)}' : label;
    }
    if (!option.feasible) {
      final names = [
        for (final c in option.blockedBy) option.blockedNames[c] ?? c,
      ]..sort();
      return '$label · ${_costText(option)}\n${Strings.format('cal_tip_blocked', {'subjects': names.join(', ')})}';
    }
    final key = recommended ? 'cal_tip_recommended' : 'cal_tip_fits';
    return '$label · ${_costText(option)}\n${Strings.format(key, {'h': option.budgetHours.round()})}';
  }

  @override
  Widget build(BuildContext context) {
    final tok = tokensOf(context);
    final monthSlots = _buildMonthSlots();
    final fm = _firstMonthBound();
    final lm = _lastMonthBound();
    final canPrev = fm == null || _month.isAfter(fm);
    final canNext = lm == null || _month.isBefore(lm);
    final effectiveFree = {...widget.freeDays, ...?widget.plan?.holidays};
    final earliestStart = _earliestTermStart();
    final maxClose = widget.term != null ? _d(widget.term!.close) : null;

    // Weekday headers Mon..Fri (anchor on a known Monday: 2026-09-07).
    final mondayRef = DateTime(2026, 9, 7);
    final dayNames = [
      for (var i = 0; i < 5; i++) w.dayName(core.addDays(mondayRef, i), true),
    ];

    final first = DateTime(_month.year, _month.month, 1);
    var monday = core.addDays(first, -(first.weekday - 1));
    final end = monthAdd(_month, 1);
    final weekRows = <Widget>[
      Row(
        spacing: 4,
        children: [
          for (final n in dayNames)
            Expanded(
              child: Center(
                child: Text(
                  n,
                  style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
                ),
              ),
            ),
        ],
      ),
    ];
    while (monday.isBefore(end)) {
      final week = [for (var i = 0; i < 5; i++) core.addDays(monday, i)];
      if (week.any((d) => d.month == _month.month)) {
        weekRows.add(
          Row(
            spacing: 4,
            children: [
              for (final d in week)
                Expanded(
                  child: d.month == _month.month
                      ? _buildCell(
                          context,
                          tok,
                          d,
                          monthSlots: monthSlots,
                          effectiveFree: effectiveFree,
                          earliestStart: earliestStart,
                          maxClose: maxClose,
                        )
                      : const SizedBox(height: 44),
                ),
            ],
          ),
        );
      }
      monday = core.addDays(monday, 7);
    }

    Widget legend(Color? color, String label, {Color? border}) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: border == null ? null : Border.all(color: border),
          ),
        ),
        Text(
          label,
          style: TextStyle(color: tok.muted, fontSize: tok.fsTiny),
        ),
      ],
    );

    return w.AppCard(
      tok: tok,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('cal:prev_month'),
              icon: const Icon(Icons.chevron_left),
              tooltip: Strings.get('pick_prev_month'),
              onPressed: canPrev
                  ? () => setState(() => _month = monthAdd(_month, -1))
                  : null,
            ),
            Expanded(
              child: Center(
                child: Text(
                  _monthHeaderLabel(),
                  style: TextStyle(
                    color: tok.text,
                    fontSize: tok.fsBody,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('cal:next_month'),
              icon: const Icon(Icons.chevron_right),
              tooltip: Strings.get('pick_next_month'),
              onPressed: canNext
                  ? () => setState(() => _month = monthAdd(_month, 1))
                  : null,
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilterChip(
            key: const Key('plan:multi_toggle'),
            selected: _multiMode,
            label: Text(Strings.get('plan_select_multi')),
            onSelected: (on) {
              setState(() {
                _multiMode = on;
                if (!on) {
                  _selectedDays.clear();
                  _selectedSlots.clear();
                }
              });
            },
          ),
        ),
        Column(spacing: 4, children: weekRows),
        if (_multiMode) _buildMultiBar(context, tok, monthSlots),
        Wrap(
          spacing: tok.gap,
          runSpacing: 4,
          children: [
            legend(tok.overlay, Strings.get('legend_school')),
            legend(null, Strings.get('legend_free'), border: tok.border),
            legend(tok.green, Strings.get('legend_recommended')),
            legend(tok.accent, Strings.get('legend_planned')),
            legend(tintColor(tok.red, 0.35), Strings.get('legend_blocked')),
            legend(null, Strings.get('legend_today'), border: tok.text),
          ],
        ),
        Text(
          Strings.get('overview_hint'),
          style: TextStyle(color: tok.faint, fontSize: tok.fsSmall),
        ),
      ],
    );
  }

  Widget _buildMultiBar(
    BuildContext context,
    Tokens tok,
    Map<DateTime, List<PickerSlot>>? monthSlots,
  ) {
    final chosen = _selectedDays.toList()..sort();
    if (chosen.isEmpty) {
      return Container(
        key: const Key('plan:multi_bar'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: tok.overlay,
          borderRadius: BorderRadius.circular(tok.radiusSm),
        ),
        child: Text(
          Strings.get('pick_empty'),
          style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
        ),
      );
    }
    final prospective = _prospectiveMultiEntries(monthSlots);
    final impacts = widget.impactOfEntries?.call(prospective) ?? const [];
    final totalHours = _totalMultiHours(monthSlots);
    return Container(
      key: const Key('plan:multi_bar'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tok.overlay,
        borderRadius: BorderRadius.circular(tok.radiusSm),
        border: Border.all(color: tok.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Text(
            Strings.format('plan_multi_summary', {
              'days': daysText(chosen.length),
              'h': totalHours,
            }),
            style: TextStyle(
              color: tok.text,
              fontSize: tok.fsSmall,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (impacts.isNotEmpty) _PlanDayDialogStaticImpact(impacts: impacts),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('plan:multi_clear'),
                onPressed: () {
                  setState(() {
                    _selectedDays.clear();
                    _selectedSlots.clear();
                  });
                },
                child: Text(Strings.get('plan_multi_clear')),
              ),
              FilledButton(
                key: const Key('plan:multi_confirm'),
                onPressed: () async {
                  final picked = _pickedPeriodsForSelected(monthSlots);
                  final taught = _taughtPeriodsForSelected(monthSlots);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => PlanMultiDialog(
                      controller: widget.controller,
                      days: chosen,
                      pickedByDay: picked,
                      taughtByDay: taught,
                      stravaOn: widget.stravaOn,
                      impactOfEntries: widget.impactOfEntries,
                    ),
                  );
                  if (confirmed == true && mounted) {
                    setState(() {
                      _selectedDays.clear();
                      _selectedSlots.clear();
                      _multiMode = false;
                    });
                  }
                },
                child: Text(Strings.get('plan_multi_btn')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    Tokens tok,
    DateTime rawDay, {
    required Map<DateTime, List<PickerSlot>>? monthSlots,
    required Set<DateTime> effectiveFree,
    required DateTime? earliestStart,
    required DateTime? maxClose,
  }) {
    final day = _d(rawDay);
    final outOfRange =
        (maxClose != null && day.isAfter(maxClose)) ||
        (earliestStart != null && day.isBefore(earliestStart));
    final cellTerm = _owningTerm(day);
    final option = cellTerm?.options[day];
    final isFree = effectiveFree.contains(day);
    final isToday = day == _today;

    final slots = monthSlots?[day];
    final taughtSlots = slots
        ?.where((s) => s.taught && s.period != null)
        .toList();
    final plannedSlots = taughtSlots?.where((s) => s.planned).toList();
    final pickableSlots = taughtSlots?.where((s) => s.pickable).toList();

    final bool isPast;
    if (widget.plan != null) {
      isPast =
          day.isBefore(_d(widget.plan!.firstDay)) ||
          (isToday &&
              slots != null &&
              taughtSlots!.isNotEmpty &&
              pickableSlots!.isEmpty &&
              plannedSlots!.isEmpty);
    } else {
      isPast =
          slots != null &&
          taughtSlots!.isNotEmpty &&
          taughtSlots.every((s) => s.past);
    }

    final bool isFullyPlanned;
    final bool isPartlyPlanned;
    if (slots != null) {
      final hasPlanned = plannedSlots!.isNotEmpty;
      isFullyPlanned = hasPlanned && pickableSlots!.isEmpty;
      isPartlyPlanned = hasPlanned && pickableSlots!.isNotEmpty;
    } else {
      isFullyPlanned = cellTerm?.plannedDates.contains(day) ?? false;
      isPartlyPlanned = false;
    }
    final isPlanned = isFullyPlanned || isPartlyPlanned;

    final isOver =
        cellTerm != null &&
        cellTerm.planned.any((r) => r.over && r.days.any((x) => _d(x) == day));
    final isRecommended =
        cellTerm != null &&
        cellTerm.recommended.any((o) => _d(o.day) == day);
    final isSelected = _multiMode && _selectedDays.contains(day);

    Color? fill;
    Color? border;
    if (outOfRange) {
      fill = null;
    } else if (isFree) {
      border = tok.border;
    } else if (isSelected) {
      fill = tok.accent;
      border = tok.accentText;
    } else if (isPlanned) {
      fill = isOver ? tok.red : tok.accent;
      if (isPast) fill = tintColor(fill, 0.45);
    } else if (isPast) {
      fill = tintColor(tok.overlay, 0.55);
    } else if (option == null) {
      fill = tok.overlay;
    } else if (!option.feasible) {
      fill = tintColor(tok.red, 0.35);
    } else if (isRecommended) {
      fill = tok.green;
    } else {
      fill = tok.overlay;
    }
    if (isToday && !outOfRange) {
      border = tok.text;
    }

    VoidCallback? onTap;
    if (!outOfRange && !isFree && !isPast) {
      if (_multiMode) {
        final canPickInMulti =
            !isFullyPlanned &&
            ((slots != null && pickableSlots!.isNotEmpty) ||
                (slots == null && option != null));
        if (canPickInMulti) {
          onTap = () => _toggleMultiDay(day, slots);
        }
      } else {
        if (isFullyPlanned) {
          final entries = widget.controller.plannedEntriesFor(_iso(day));
          if (entries.isNotEmpty) {
            onTap = () => showPlannedDialog(context, widget.controller, entries);
          }
        } else if (isPartlyPlanned ||
            (slots != null && pickableSlots!.isNotEmpty) ||
            (slots == null && option != null)) {
          onTap = () => showDialog<void>(
            context: context,
            builder: (ctx) => PlanDayDialog(
              controller: widget.controller,
              day: day,
              stravaOn: widget.stravaOn,
              isLunchOpen: widget.controller.isLunchOpen,
              impactOf: widget.impactOf,
              impactOfEntries: widget.impactOfEntries,
              slots: slots,
              existingEntries: widget.controller.plannedEntriesFor(_iso(day)),
            ),
          );
        }
      }
    }

    final label = '${w.dayName(day, true)} ${w.czDay(day)}';
    var tip = outOfRange
        ? label
        : _cellTip(
            day,
            label,
            option,
            isFree: isFree,
            isFullyPlanned: isFullyPlanned,
            isPartlyPlanned: isPartlyPlanned,
            remainingPickable: pickableSlots?.length ?? 0,
            past: isPast,
            recommended: isRecommended,
          );
    if (!outOfRange && option != null && option.finalWeek && !isPlanned) {
      tip += '\n${Strings.get('cal_tip_final')}';
    }

    final solid =
        fill == tok.green ||
        fill == tok.accent ||
        fill == tok.red ||
        isSelected;
    final textColor = solid
        ? tok.accentText
        : (outOfRange || isPast || isFree ? tok.faint : tok.text);

    Widget content = Text(
      '${day.day}',
      style: TextStyle(
        fontSize: tok.fsSmall,
        fontWeight: FontWeight.w600,
        color: textColor,
      ),
    );
    if (isSelected) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          Center(child: content),
          Positioned(
            top: 3,
            right: 4,
            child: Icon(Icons.check, size: 11, color: tok.accentText),
          ),
        ],
      );
    } else if (isPartlyPlanned && !isPast && !outOfRange) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          Center(child: content),
          Positioned(
            bottom: 4,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: tok.accentText,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      content = Center(child: content);
    }

    return Tooltip(
      message: tip,
      child: InkWell(
        key: ValueKey('day_${day.year}_${day.month}_${day.day}'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
            border: border == null
                ? null
                : Border.all(color: border, width: isToday ? 2 : 1),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Single-day plan dialog: template picker + optional per-lesson checkboxes +
/// lunch toggle + impact preview + existing partial entries (O3, M1, S3).
class PlanDayDialog extends StatefulWidget {
  final PlannerController controller;
  final DateTime day;
  final bool stravaOn;
  final bool Function(String dayLabel)? isLunchOpen;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final List<PickerSlot>? slots;
  final List<Map<String, dynamic>> existingEntries;

  const PlanDayDialog({
    super.key,
    required this.controller,
    required this.day,
    required this.stravaOn,
    this.isLunchOpen,
    this.impactOf,
    this.impactOfEntries,
    this.slots,
    this.existingEntries = const [],
  });

  @override
  State<PlanDayDialog> createState() => _PlanDayDialogState();
}

class _PlanDayDialogState extends State<PlanDayDialog> {
  int picked = 0;
  late bool cancelLunch;
  bool _lunchTouched = false;
  late bool _chooseLessonsExpanded;
  late Set<int> _selectedPeriods;
  late List<Map<String, dynamic>> _existingEntries;

  Set<int> get _taughtPeriods => {
    for (final s in widget.slots ?? const <PickerSlot>[])
      if (s.taught && s.period != null) s.period!,
  };

  Set<int> get _pickablePeriods => {
    for (final s in widget.slots ?? const <PickerSlot>[])
      if (s.pickable) s.period!,
  };

  bool get _hasSlots =>
      widget.slots != null &&
      widget.slots!.any((s) => s.period != null);

  bool get _isWholeDay {
    if (!_hasSlots) return true;
    final taught = _taughtPeriods;
    return taught.isNotEmpty &&
        _selectedPeriods.length == taught.length &&
        _selectedPeriods.containsAll(taught);
  }

  @override
  void initState() {
    super.initState();
    final hasPlannedSlot = (widget.slots ?? const <PickerSlot>[]).any(
      (s) => s.taught && s.planned,
    );
    _chooseLessonsExpanded = hasPlannedSlot;
    _selectedPeriods = Set<int>.of(_pickablePeriods);
    _existingEntries = [
      for (final e in widget.existingEntries) Map<String, dynamic>.of(e),
    ];
    // S3: default cancelLunch on for whole-day plans, off for partial-day plans.
    cancelLunch = _isWholeDay;
  }

  void _syncDefaultCancelLunch() {
    if (!_lunchTouched) {
      cancelLunch = _isWholeDay;
    }
  }

  List<Map<String, dynamic>> _buildEntries(String tpl) {
    final day = _d(widget.day);
    final dayIso = _iso(day);
    if (!_hasSlots || _isWholeDay) {
      return [
        {
          'start_date': dayIso,
          'end_date': dayIso,
          'start_period': null,
          'end_period': null,
          'template': tpl,
          'cancel_lunch': cancelLunch,
        },
      ];
    }
    if (_selectedPeriods.isEmpty) return const [];
    return core
        .entriesForSelection(
          picked: {day: _selectedPeriods},
          lessons: {day: _taughtPeriods},
          template: tpl,
          cancelLunch: cancelLunch,
        )
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  String _slotSubtitle(PickerSlot slot) {
    final parts = <String>[];
    if (slot.past) {
      parts.add(Strings.get('pick_started'));
    } else if (!slot.taught) {
      parts.add(Strings.get('status_lesson_cancelled'));
    } else if (slot.planned) {
      parts.add(Strings.get('cal_tip_planned'));
    } else if (slot.changed) {
      parts.add(Strings.get('pick_change'));
    }
    if (slot.detail.isNotEmpty) {
      parts.add(slot.detail);
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(
      widget.controller.config,
      kind: 'day',
      signature: '${widget.controller.get('your_signature', '')}',
    );
    final options = [for (final e in named) e.value];
    final labels = templateLabels(named);
    final tpl = options[picked.clamp(0, options.length - 1)];
    final dayIso = _iso(widget.day);
    final cz = _cz(widget.day);
    var orderOpen = true;
    if (widget.stravaOn) {
      try {
        orderOpen = widget.isLunchOpen?.call(cz) ?? true;
      } catch (_) {
        orderOpen = true;
      }
    }
    final prospective = _buildEntries(tpl);
    final List<ImpactTerm> impacts;
    if (!_isWholeDay && widget.impactOfEntries != null) {
      impacts = prospective.isEmpty
          ? const []
          : widget.impactOfEntries!(prospective);
    } else {
      impacts =
          widget.impactOf?.call({'start_date': dayIso, 'end_date': dayIso}) ??
          const [];
    }
    final canConfirm = !_hasSlots || _selectedPeriods.isNotEmpty;
    final pickable = _pickablePeriods;
    final allPickableChecked =
        pickable.isNotEmpty &&
        _selectedPeriods.length == pickable.length &&
        _selectedPeriods.containsAll(pickable);

    return AlertDialog(
      title: Text(
        "${Strings.get('plan_skip')}: ${w.dayName(widget.day)} ${_cz(widget.day)}",
      ),
      content: SizedBox(
        width: w.dialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_existingEntries.isNotEmpty) ...[
                for (var i = 0; i < _existingEntries.length; i++)
                  Row(
                    children: [
                      Expanded(child: Text(entryLabel(_existingEntries[i]))),
                      TextButton(
                        onPressed: () {
                          final ok = widget.controller.unplanEntry(
                            _existingEntries[i],
                          );
                          appSnack(
                            context,
                            ok
                                ? Strings.get('plan_removed')
                                : Strings.get('save_failed'),
                          );
                          if (ok) {
                            setState(() => _existingEntries.removeAt(i));
                          }
                        },
                        child: Text(Strings.get('unplan')),
                      ),
                    ],
                  ),
                const Divider(),
              ],
              if (_hasSlots) ...[
                TextButton.icon(
                  key: const Key('plan:choose_lessons'),
                  onPressed: () => setState(
                    () => _chooseLessonsExpanded = !_chooseLessonsExpanded,
                  ),
                  icon: Icon(
                    _chooseLessonsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                  label: Text(Strings.get('pick_choose_lessons')),
                ),
                if (_chooseLessonsExpanded) ...[
                  CheckboxListTile(
                    key: const Key('plan:whole_day_check'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(Strings.get('whole_day')),
                    value: allPickableChecked,
                    onChanged: pickable.isEmpty
                        ? null
                        : (_) => setState(() {
                            if (allPickableChecked) {
                              _selectedPeriods.clear();
                            } else {
                              _selectedPeriods = Set<int>.of(pickable);
                            }
                            _syncDefaultCancelLunch();
                          }),
                  ),
                  for (final slot in widget.slots!)
                    if (slot.period != null)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${slot.period}. ${slot.subject}'),
                        subtitle: () {
                          final sub = _slotSubtitle(slot);
                          return sub.isEmpty ? null : Text(sub);
                        }(),
                        value: _selectedPeriods.contains(slot.period),
                        onChanged: !slot.pickable
                            ? null
                            : (v) => setState(() {
                                if (v == true) {
                                  _selectedPeriods.add(slot.period!);
                                } else {
                                  _selectedPeriods.remove(slot.period!);
                                }
                                _syncDefaultCancelLunch();
                              }),
                      ),
                  const Divider(),
                ],
              ],
              Text(Strings.get('choose_template')),
              DropdownButton<int>(
                value: picked.clamp(0, options.length - 1),
                items: [
                  for (var i = 0; i < labels.length; i++)
                    DropdownMenuItem(value: i, child: Text(labels[i].value)),
                ],
                onChanged: (v) => setState(() => picked = v ?? 0),
              ),
              Text(tpl),
              if (widget.stravaOn && orderOpen)
                CheckboxListTile(
                  title: Text(Strings.get('plan_cancel_lunch')),
                  value: cancelLunch,
                  onChanged: (v) => setState(() {
                    _lunchTouched = true;
                    cancelLunch = v ?? true;
                  }),
                ),
              if (widget.stravaOn && !orderOpen)
                Text(Strings.format('lunch_cannot_cancel', {'deadline': '—'})),
              ...impactWidgets(impacts),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: !canConfirm
              ? null
              : () {
                  final bool ok;
                  if (_isWholeDay) {
                    ok = widget.controller.planSkip(
                      dayIso,
                      tpl,
                      cancelLunch: cancelLunch,
                    );
                  } else {
                    final entries = _buildEntries(tpl);
                    ok = widget.controller.planEntries(entries) > 0;
                  }
                  Navigator.of(context).pop();
                  appSnack(
                    context,
                    ok
                        ? Strings.get('skip_planned')
                        : Strings.get('skip_not_planned'),
                  );
                },
          child: Text(Strings.get('confirm')),
        ),
      ],
    );
  }

  List<Widget> impactWidgets(List<ImpactTerm> impacts) {
    if (impacts.isEmpty) return [];
    final out = <Widget>[Text(Strings.get('impact_title'))];
    var worst = 'ok';
    var anyRows = false;
    for (final term in impacts) {
      if (impacts.length > 1) out.add(Text(term.label));
      for (final row in term.rows) {
        anyRows = true;
        if (row.level == 'over' || (row.level == 'reserve' && worst == 'ok')) {
          worst = row.level;
        }
        out.add(
          Text(
            Strings.format('impact_row', {
              'name': row.name,
              'cost': row.cost,
              'left': hoursText(row.freeAfter),
              'p': row.projectedAfter.toStringAsFixed(1),
            }),
          ),
        );
      }
    }
    if (!anyRows) {
      out.add(Text(Strings.get('impact_none')));
      return out;
    }
    out.add(
      Text(
        Strings.get(
          worst == 'over'
              ? 'impact_over'
              : worst == 'reserve'
              ? 'impact_reserve'
              : 'impact_ok',
        ),
      ),
    );
    return out;
  }
}

/// Multi-day confirmation dialog opened from [PlannerMonthCalendar]'s
/// selection bar (O3, S3).
class PlanMultiDialog extends StatefulWidget {
  final PlannerController controller;
  final List<DateTime> days;
  final Map<DateTime, Set<int>>? pickedByDay;
  final Map<DateTime, Set<int>>? taughtByDay;
  final bool stravaOn;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;

  const PlanMultiDialog({
    super.key,
    required this.controller,
    required this.days,
    this.pickedByDay,
    this.taughtByDay,
    required this.stravaOn,
    this.impactOfEntries,
  });

  @override
  State<PlanMultiDialog> createState() => _PlanMultiDialogState();
}

class _PlanMultiDialogState extends State<PlanMultiDialog> {
  int picked = 0;
  late bool cancelLunch;

  bool get _anyPartial {
    final pMap = widget.pickedByDay;
    final tMap = widget.taughtByDay;
    if (pMap == null || tMap == null) return false;
    for (final raw in widget.days) {
      final d = _d(raw);
      final p = pMap[d];
      final t = tMap[d];
      if (p != null && t != null && t.isNotEmpty) {
        if (p.length < t.length || !p.containsAll(t)) return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    // S3: default cancelLunch off whenever any chosen day is partial.
    cancelLunch = !_anyPartial;
  }

  List<Map<String, dynamic>> _entries(String template) {
    final chosen = <DateTime, Set<int>>{};
    final lessons = <DateTime, Set<int>>{};
    for (final raw in widget.days) {
      final d = _d(raw);
      final p = widget.pickedByDay?[d];
      final t = widget.taughtByDay?[d];
      chosen[d] = (p != null && p.isNotEmpty) ? p : {1};
      lessons[d] = (t != null && t.isNotEmpty) ? t : chosen[d]!;
    }
    return core
        .entriesForSelection(
          picked: chosen,
          lessons: lessons,
          template: template,
          cancelLunch: cancelLunch,
        )
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(
      widget.controller.config,
      kind: 'day',
      signature: '${widget.controller.get('your_signature', '')}',
    );
    final options = [for (final e in named) e.value];
    final labels = templateLabels(named);
    final tpl = options[picked.clamp(0, options.length - 1)];
    final entries = _entries(tpl);
    final impacts = widget.impactOfEntries?.call(entries) ?? const [];
    final listing = widget.days.map(_cz).join(', ');

    return AlertDialog(
      title: Text(Strings.get('plan_multi_btn')),
      content: SizedBox(
        width: w.dialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Text(listing),
              Text(Strings.get('choose_template')),
              DropdownButton<int>(
                value: picked.clamp(0, options.length - 1),
                items: [
                  for (var i = 0; i < options.length; i++)
                    DropdownMenuItem(value: i, child: Text(labels[i].value)),
                ],
                onChanged: (v) => setState(() => picked = v ?? 0),
              ),
              Text(tpl),
              if (widget.stravaOn)
                CheckboxListTile(
                  title: Text(Strings.get('plan_cancel_lunch')),
                  value: cancelLunch,
                  onChanged: (v) => setState(() => cancelLunch = v ?? true),
                ),
              _PlanDayDialogStaticImpact(impacts: impacts),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: entries.isEmpty
              ? null
              : () {
                  final n = widget.controller.planEntries(entries);
                  Navigator.of(context).pop(n > 0);
                  appSnack(
                    context,
                    n > 0
                        ? (cancelLunch && widget.stravaOn
                              ? Strings.get('skip_planned')
                              : Strings.get('skip_planned_keep_lunch'))
                        : Strings.get('skip_not_planned'),
                  );
                },
          child: Text(Strings.get('confirm')),
        ),
      ],
    );
  }
}

/// Plan-all dialog: one template for every recommended day.
class _PlanAllDialog extends StatefulWidget {
  final PlannerController controller;
  final List<DateTime> days;
  final bool stravaOn;

  const _PlanAllDialog({
    required this.controller,
    required this.days,
    required this.stravaOn,
  });

  @override
  State<_PlanAllDialog> createState() => _PlanAllDialogState();
}

class _PlanAllDialogState extends State<_PlanAllDialog> {
  int picked = 0;
  bool cancelLunch = true;

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(
      widget.controller.config,
      kind: 'day',
      signature: '${widget.controller.get('your_signature', '')}',
    );
    final options = [for (final e in named) e.value];
    final labels = templateLabels(named);
    final listing = widget.days.map(_cz).join(', ');
    return AlertDialog(
      title: Text(Strings.get('plan_all_title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Strings.format('plan_all_body', {'days': listing})),
            DropdownButton<int>(
              value: picked.clamp(0, options.length - 1),
              items: [
                for (var i = 0; i < options.length; i++)
                  DropdownMenuItem(value: i, child: Text(labels[i].value)),
              ],
              onChanged: (v) => setState(() => picked = v ?? 0),
            ),
            Text(options[picked.clamp(0, options.length - 1)]),
            if (widget.stravaOn)
              CheckboxListTile(
                title: Text(Strings.get('plan_cancel_lunch')),
                value: cancelLunch,
                onChanged: (v) => setState(() => cancelLunch = v ?? true),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: () {
            final n = widget.controller.planDays(
              [
                for (final d in widget.days) _iso(d),
              ],
              options[picked.clamp(0, options.length - 1)],
              cancelLunch: cancelLunch,
            );
            Navigator.of(context).pop();
            appSnack(
              context,
              n > 0
                  ? Strings.format('plan_all_done', {'n': n})
                  : Strings.get('skip_not_planned'),
            );
          },
          child: Text(Strings.get('confirm')),
        ),
      ],
    );
  }
}

class _PlanDayDialogStaticImpact extends StatelessWidget {
  final List<ImpactTerm> impacts;

  const _PlanDayDialogStaticImpact({required this.impacts});

  @override
  Widget build(BuildContext context) {
    if (impacts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(Strings.get('impact_title')),
        for (final term in impacts)
          for (final row in term.rows)
            Text(
              Strings.format('impact_row', {
                'name': row.name,
                'cost': row.cost,
                'left': hoursText(row.freeAfter),
                'p': row.projectedAfter.toStringAsFixed(1),
              }),
            ),
      ],
    );
  }
}

/// Reserve editor dialog (the planner's reserve entry point).
class ReserveDialog extends StatefulWidget {
  final double current;
  final void Function(double value) onSave;

  const ReserveDialog({super.key, required this.current, required this.onSave});

  @override
  State<ReserveDialog> createState() => _ReserveDialogState();
}

class _ReserveDialogState extends State<ReserveDialog> {
  late final TextEditingController text;

  @override
  void initState() {
    super.initState();
    text = TextEditingController(text: '${widget.current}');
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(Strings.get('reserve_limit')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Strings.get('reserve_hint')),
          TextField(
            controller: text,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: () {
            final v = double.tryParse(text.text.replaceAll(',', '.'));
            if (v == null || v < 0 || v > 99.9) {
              appSnack(context, Strings.get('save_failed'));
              return;
            }
            widget.onSave(v);
            Navigator.of(context).pop();
          },
          child: Text(Strings.get('confirm')),
        ),
      ],
    );
  }
}
