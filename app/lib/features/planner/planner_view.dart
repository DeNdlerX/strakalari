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

/// One lesson slot in the custom picker.
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

/// The planner screen: year overview, budgets, recommendations, planned.
class PlannerView extends StatelessWidget {
  final PlannerController controller;
  final YearPlanData? plan;
  final bool hasTimetable;
  final bool hasData;
  final String updatedLabel;
  final String calendarSummary;
  final bool stravaOn;
  final bool narrow;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final List<PickerSlot> Function(DateTime day)? lessonsFor;
  final Set<DateTime> Function()? freeDays;
  final VoidCallback? onOpenAbsences;
  final VoidCallback? onOpenCalendar;
  final void Function(String template)? tutorialEvent;

  const PlannerView({
    super.key,
    required this.controller,
    this.plan,
    this.hasTimetable = false,
    this.hasData = false,
    this.updatedLabel = '',
    this.calendarSummary = '',
    this.stravaOn = false,
    this.narrow = false,
    this.impactOf,
    this.impactOfEntries,
    this.lessonsFor,
    this.freeDays,
    this.onOpenAbsences,
    this.onOpenCalendar,
    this.tutorialEvent,
  });

  Tokens _tok(BuildContext context) => tokensOf(context);

  @override
  Widget build(BuildContext context) {
    final tok = _tok(context);
    final reserve = controller.planReserve();
    final intro = Text(
      '${Strings.get('planner_desc')} ${Strings.format('plan_buffer_note', {'reserve': reserve})}',
      style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
    );
    final blocks = <Widget>[];
    if (plan == null || !hasData) {
      blocks
        ..add(
          w.HeaderRow(
            heading: Strings.get('planner_title'),
            updated: updatedLabel,
            tok: tok,
          ),
        )
        ..add(intro)
        ..add(w.EmptyState(text: Strings.get('no_data'), tok: tok));
      if (!hasTimetable) {
        blocks.add(_small(tok, Strings.get('planner_need_refresh')));
      } else {
        blocks.add(_small(tok, Strings.get('need_credentials')));
      }
      return _scroll(tok, blocks);
    }
    final p = plan!;
    final term = p.term(controller.plannerTerm) ?? p.defaultTerm;
    final customBtn = Tooltip(
      message: Strings.get('plan_custom_hint'),
      child: ElevatedButton.icon(
        onPressed: () => showCustomPlanDialog(context),
        icon: const Icon(Icons.edit_calendar_outlined, size: 18),
        label: Text(Strings.get('plan_custom')),
      ),
    );
    final seeAbsences = OutlinedButton(
      onPressed: onOpenAbsences,
      child: Text(Strings.get('see_absences')),
    );
    if (narrow) {
      blocks
        ..add(
          w.HeaderRow(
            heading: Strings.get('planner_title'),
            updated: updatedLabel,
            tok: tok,
          ),
        )
        ..add(
          Wrap(spacing: 8, runSpacing: 8, children: [seeAbsences, customBtn]),
        );
    } else {
      blocks.add(
        w.HeaderRow(
          heading: Strings.get('planner_title'),
          updated: updatedLabel,
          tok: tok,
          actions: [seeAbsences, customBtn],
        ),
      );
    }
    blocks.add(intro);
    if (term == null) {
      blocks.add(
        w.AppCard(
          tok: tok,
          children: [
            _small(tok, Strings.get('term_nothing'), size: tok.fsBody),
          ],
        ),
      );
    } else {
      if (p.terms.length >= 2) {
        blocks.add(
          Wrap(
            spacing: tok.gap / 2,
            runSpacing: tok.gap / 2,
            children: [
              for (final other in p.terms)
                () {
                  final label =
                      '${_termTitle(other)} · ${Strings.format('term_until', {'d': w.czDay(other.close)})}';
                  void pick() => controller.selectPlannerTerm(other.key);
                  return other.key == term.key
                      ? ElevatedButton(onPressed: pick, child: Text(label))
                      : OutlinedButton(onPressed: pick, child: Text(label));
                }(),
            ],
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
      blocks.add(_statsRow(tok, term));
      blocks.addAll(_warnings(tok, term));
      blocks.add(w.SectionHeader(Strings.get('section_overview'), tok: tok));
      blocks.add(
        TutorialAnchor(
          anchorKey: 'plan_strip',
          child: _calendarStrip(context, tok, p, term),
        ),
      );
      blocks.addAll(_recommended(context, tok, p, term));
      blocks.addAll(_budgets(tok, term));
    }
    blocks.addAll(_planned(context, tok, p));
    blocks.addAll(_footer(tok));
    return _scroll(tok, blocks);
  }

  Widget _scroll(Tokens tok, List<Widget> blocks) => ListView(
    padding: EdgeInsets.zero,
    children: [
      for (var i = 0; i < blocks.length; i++) ...[
        blocks[i],
        if (i != blocks.length - 1) SizedBox(height: tok.gap),
      ],
      SizedBox(height: tok.pad * 2),
    ],
  );

  Widget _small(Tokens tok, String text, {bool faint = true, double? size}) =>
      Text(
        text,
        style: TextStyle(
          color: faint ? tok.faint : tok.muted,
          fontSize: size ?? tok.fsSmall,
        ),
      );

  static String _termTitle(TermPlanData t) =>
      t.key == 'sem1' ? Strings.get('term_sem1') : Strings.get('term_sem2');

  static String _dayLabel(DateTime d) =>
      '${w.dayName(d)} ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  Widget _statsRow(Tokens tok, TermPlanData term) {
    final remaining = term.remainingDays.toSet();
    final plannedDays = term.plannedDates.intersection(remaining).length;
    final plannedHours = term.planned.fold(0, (sum, r) => sum + r.costHours);
    final tight = term.tightest;
    var tightLabel = Strings.get('stat_tightest');
    var tightValue = '—';
    var tightKind = 'info';
    if (tight != null) {
      tightLabel =
          '${Strings.get('stat_tightest')} · ${Strings.format('hours_free', {'n': hoursText(tight.free)})}';
      tightValue = tight.name;
      tightKind =
          const {
            'over': 'critical',
            'reserve': 'warning',
            'tight': 'warning',
          }[tight.status] ??
          'ok';
    }
    final cards = <Widget>[
      w.StatCard(
        label: Strings.get('stat_can_afford'),
        value: daysText(term.capacity),
        tok: tok,
        kind: term.capacity > 0 ? 'ok' : 'warning',
      ),
      w.StatCard(
        label: Strings.get('stat_planned'),
        value: '${daysText(plannedDays)} · $plannedHours h',
        tok: tok,
        kind: plannedDays > 0 ? 'sent' : 'info',
      ),
      w.StatCard(
        label: tightLabel,
        value: tightValue,
        tok: tok,
        kind: tightKind,
        singleLine: true,
      ),
      w.StatCard(
        label: Strings.get('planner_horizon'),
        value: '${term.remainingDays.length}',
        tok: tok,
      ),
    ];
    if (!narrow || cards.length <= 3) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tok.gap,
        children: cards,
      );
    }
    final half = tok.gap / 2;
    return Column(
      spacing: half,
      children: [
        for (var i = 0; i < cards.length; i += 2)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: half,
            children: cards.sublist(i, i + 2),
          ),
      ],
    );
  }

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

  String _cellTip(
    DateTime day,
    String label,
    DayOptionData? option, {
    required bool isFree,
    required bool isPlanned,
    required bool past,
    required YearPlanData p,
    required bool recommended,
  }) {
    if (isFree) {
      final free = p.freeLabels[day];
      return '$label · ${free == null || free.isEmpty ? Strings.get('cal_tip_free') : free}';
    }
    if (isPlanned) return '$label · ${Strings.get('cal_tip_planned')}';
    if (past) return '$label · ${Strings.get('cal_tip_past')}';
    if (option == null) {
      final n = p.lessonsOn(day);
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

  Widget _calendarStrip(
    BuildContext context,
    Tokens tok,
    YearPlanData p,
    TermPlanData term,
  ) {
    final recommended = {for (final o in term.recommended) _d(o.day)};
    final overDays = <DateTime>{};
    for (final row in term.planned) {
      if (row.over) overDays.addAll(row.days.map(_d));
    }
    final firstMonday = core.addDays(
      _d(term.start),
      -(term.start.weekday - 1),
    );
    final names = [
      for (var i = 0; i < 5; i++)
        w.dayName(core.addDays(firstMonday, i), true),
    ];
    Widget strip;
    if (narrow) {
      const labelW = 28.0;
      final rows = <Widget>[
        Row(
          spacing: 4,
          children: [
            const SizedBox(width: labelW),
            for (final n in names)
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
      var monday = firstMonday;
      while (!monday.isAfter(term.close)) {
        final week = [
          for (var i = 0; i < 5; i++) core.addDays(monday, i),
        ];
        final inTerm = [
          for (final d in week)
            if (!d.isBefore(_d(term.start)) && !d.isAfter(term.close)) d,
        ];
        final starts = [
          for (final d in inTerm)
            if (d.day == 1 || (d == inTerm.first && d == _d(term.start))) d,
        ];
        final monthLabel = starts.isEmpty ? '' : '${starts.first.month}.';
        rows.add(
          Row(
            spacing: 4,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: labelW,
                child: Text(
                  monthLabel,
                  style: TextStyle(
                    color: tok.faint,
                    fontSize: tok.fsSmall,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final d in week)
                Expanded(
                  child: _cell(
                    context,
                    tok,
                    p,
                    term,
                    d,
                    recommended,
                    overDays,
                    36,
                    true,
                  ),
                ),
            ],
          ),
        );
        monday = core.addDays(monday, 7);
      }
      strip = Column(spacing: 4, children: rows);
    } else {
      var monday = firstMonday;
      final columns = <Widget>[];
      int? lastMonth;
      while (!monday.isAfter(term.close)) {
        final week = [
          for (var i = 0; i < 5; i++) core.addDays(monday, i),
        ];
        final inTerm = [
          for (final d in week)
            if (!d.isBefore(_d(term.start)) && !d.isAfter(term.close)) d,
        ];
        var monthLabel = '';
        if (inTerm.isNotEmpty && inTerm.first.month != lastMonth) {
          lastMonth = inTerm.first.month;
          monthLabel = '${inTerm.first.month}.';
        }
        columns.add(
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 4,
              children: [
                SizedBox(
                  height: 16,
                  child: Text(
                    monthLabel,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
                  ),
                ),
                for (final d in week)
                  _cell(
                    context,
                    tok,
                    p,
                    term,
                    d,
                    recommended,
                    overDays,
                    18,
                    false,
                  ),
              ],
            ),
          ),
        );
        monday = core.addDays(monday, 7);
      }
      strip = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Column(
            spacing: 4,
            children: [
              const SizedBox(height: 16),
              for (final n in names)
                SizedBox(
                  height: 18,
                  width: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      n,
                      style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
                    ),
                  ),
                ),
            ],
          ),
          ...columns,
        ],
      );
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
        strip,
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
        _small(tok, Strings.get('overview_hint')),
      ],
    );
  }

  static DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);

  Widget _cell(
    BuildContext context,
    Tokens tok,
    YearPlanData p,
    TermPlanData term,
    DateTime rawDay,
    Set<DateTime> recommended,
    Set<DateTime> overDays,
    double size,
    bool numbered,
  ) {
    final day = _d(rawDay);
    if (day.isBefore(_d(term.start)) || day.isAfter(_d(term.close))) {
      return SizedBox(height: size);
    }
    final option = term.options[day];
    final isFree = p.holidays.contains(day);
    final isPlanned = term.plannedDates.contains(day);
    final past = day.isBefore(_d(p.firstDay));
    final label = '${w.dayName(day, true)} ${w.czDay(day)}';
    Color? fill;
    Color? border;
    final isRecommended = recommended.contains(day);
    if (isFree) {
      border = tok.border;
    } else if (isPlanned) {
      fill = overDays.contains(day) ? tok.red : tok.accent;
      if (past) fill = tintColor(fill, 0.45);
    } else if (past) {
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
    var tip = _cellTip(
      day,
      label,
      option,
      isFree: isFree,
      isPlanned: isPlanned,
      past: past,
      p: p,
      recommended: isRecommended,
    );
    if (option != null && option.finalWeek && !isPlanned) {
      tip += '\n${Strings.get('cal_tip_final')}';
    }
    final isToday = day == _d(p.today);
    if (isToday) border = tok.text;
    VoidCallback? onTap;
    if (isPlanned && !past) {
      final entry = controller.plannedFor(_iso(day));
      if (entry != null) {
        onTap = () => showPlannedDialog(context, Map.of(entry));
      }
    } else if (option != null && !past) {
      onTap = () => showPlanDayDialog(context, day);
    }
    Widget? number;
    if (numbered) {
      final solid = fill == tok.green || fill == tok.accent || fill == tok.red;
      number = Text(
        '${day.day}',
        style: TextStyle(
          fontSize: tok.fsSmall,
          fontWeight: FontWeight.w600,
          color: solid
              ? tok.accentText
              : (past || isFree ? tok.faint : tok.text),
        ),
      );
    }
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(numbered ? 6 : 3),
            border: border == null
                ? null
                : Border.all(color: border, width: isToday ? 2 : 1),
          ),
          child: number,
        ),
      ),
    );
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
      _small(tok, Strings.get('plan_explain')),
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
    for (var i = 0; i < picks.length; i++) {
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
                onPressed: () => showPlanDayDialog(context, option.day),
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
    return out;
  }

  Widget _targetDropdown(Tokens tok, TermPlanData term) {
    // Port of `_target_dropdown` (planner.py): the capacity on top of what
    // is already planned in the rest of the term.
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

  Widget _budgetBar(Tokens tok, BudgetRowData b) {
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
      final share =
          core.roundHalfEvenToInt((hours < 0 ? 0.0 : hours) / total * 1000);
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
      child: Row(children: parts),
    );
  }

  List<Widget> _budgets(Tokens tok, TermPlanData term) {
    if (term.budgets.isEmpty) return const [];
    final rows = <Widget>[];
    for (final b in term.budgets) {
      final kind =
          const {
            'over': 'critical',
            'reserve': 'warning',
            'tight': 'warning',
          }[b.status] ??
          'ok';
      final label = Strings.get(
        const {
              'over': 'budget_over',
              'reserve': 'budget_reserve',
              'tight': 'budget_tight',
            }[b.status] ??
            'budget_ok',
      );
      rows.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 3,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              spacing: 6,
              children: [
                Expanded(
                  child: Text(
                    b.name,
                    style: TextStyle(
                      color: tok.text,
                      fontSize: tok.fsSmall,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  Strings.format('budget_final', {
                    'p': b.projectedPct.toStringAsFixed(1),
                    'limit': b.limitPct,
                  }),
                  style: TextStyle(color: tok.faint, fontSize: tok.fsTiny),
                ),
                w.Badge(text: label, tok: tok, kind: kind),
              ],
            ),
            _budgetBar(tok, b),
            Text(
              Strings.format('budget_line', {
                'free': hoursText(b.free),
                'planned': b.planned.toInt(),
                'buffer': hoursText(b.buffer),
              }),
              style: TextStyle(color: tok.muted, fontSize: tok.fsTiny),
            ),
          ],
        ),
      );
    }
    Widget legend(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          label,
          style: TextStyle(color: tok.muted, fontSize: tok.fsTiny),
        ),
      ],
    );
    return [
      w.SectionHeader(Strings.get('section_budgets'), tok: tok),
      TutorialAnchor(
        anchorKey: 'plan_budget',
        child: w.AppCard(
          tok: tok,
          children: [
            Wrap(
              spacing: tok.gap,
              runSpacing: 4,
              children: [
                legend(tok.muted, Strings.get('legend_missed')),
                legend(tok.accent, Strings.get('legend_planned')),
                legend(tok.green, Strings.get('legend_free_h')),
                legend(
                  tintColor(tok.yellow, 0.55),
                  Strings.get('legend_buffer'),
                ),
              ],
            ),
            ...rows,
          ],
        ),
      ),
    ];
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

  String _costText(DayOptionData option) {
    final lessons = w.lessonsText(option.lessonsCount);
    if (option.cost == 0) {
      return '$lessons · ${Strings.get('day_cost_free')}';
    }
    return '$lessons · ${Strings.format('day_cost', {'n': option.budgetHours.round()})}';
  }

  // -- dialogs ---------------------------------------------------------------
  Future<void> showPlanDayDialog(BuildContext context, DateTime day) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _PlanDayDialog(
        controller: controller,
        day: day,
        stravaOn: stravaOn,
        isLunchOpen: controller.isLunchOpen,
        impactOf: impactOf,
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

  Future<void> showPlannedDialog(
    BuildContext context,
    Map<String, dynamic> entry,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entryLabel(entry)),
        content: Text('${entry['template'] ?? ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(Strings.get('cancel')),
          ),
          TextButton(
            onPressed: () {
              final ok = controller.unplanEntry(entry);
              Navigator.of(ctx).pop();
              appSnack(
                context,
                ok ? Strings.get('plan_removed') : Strings.get('save_failed'),
              );
            },
            child: Text(Strings.get('unplan')),
          ),
        ],
      ),
    );
  }

  Future<void> showCustomPlanDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _CustomPlanDialog(
        controller: controller,
        stravaOn: stravaOn,
        lessonsFor: lessonsFor ?? ((_) => const []),
        freeDays: freeDays?.call() ?? {},
        impactOfEntries: impactOfEntries,
      ),
    );
  }

  static String _cz(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Single-day plan dialog: template picker + lunch toggle + impact preview.
typedef _PlanDayDialog = PlanDayDialog;

/// Port of planner._plan_dialog (Flet dialog cases).
class PlanDayDialog extends StatefulWidget {
  final PlannerController controller;
  final DateTime day;
  final bool stravaOn;
  final bool Function(String dayLabel)? isLunchOpen;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;

  const PlanDayDialog({
    super.key,
    required this.controller,
    required this.day,
    required this.stravaOn,
    this.isLunchOpen,
    this.impactOf,
  });

  @override
  State<PlanDayDialog> createState() => _PlanDayDialogState();
}

class _PlanDayDialogState extends State<PlanDayDialog> {
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
    final dayIso =
        '${widget.day.year.toString().padLeft(4, '0')}-${widget.day.month.toString().padLeft(2, '0')}-${widget.day.day.toString().padLeft(2, '0')}';
    final cz =
        '${widget.day.day.toString().padLeft(2, '0')}.${widget.day.month.toString().padLeft(2, '0')}.${widget.day.year}';
    var orderOpen = true;
    if (widget.stravaOn) {
      try {
        orderOpen = widget.isLunchOpen?.call(cz) ?? true;
      } catch (_) {
        orderOpen = true;
      }
    }
    final impacts =
        widget.impactOf?.call({'start_date': dayIso, 'end_date': dayIso}) ??
        const [];
    return AlertDialog(
      title: Text(
        "${Strings.get('plan_skip')}: ${w.dayName(widget.day)} ${PlannerView._cz(widget.day)}",
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Strings.get('choose_template')),
            DropdownButton<int>(
              value: picked.clamp(0, options.length - 1),
              items: [
                for (var i = 0; i < labels.length; i++)
                  DropdownMenuItem(value: i, child: Text(labels[i].value)),
              ],
              onChanged: (v) => setState(() => picked = v ?? 0),
            ),
            Text(options[picked.clamp(0, options.length - 1)]),
            if (widget.stravaOn && orderOpen)
              CheckboxListTile(
                title: Text(Strings.get('plan_cancel_lunch')),
                value: cancelLunch,
                onChanged: (v) => setState(() => cancelLunch = v ?? true),
              ),
            if (widget.stravaOn && !orderOpen)
              Text(Strings.format('lunch_cannot_cancel', {'deadline': '—'})),
            ...impactWidgets(impacts),
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
            final ok = widget.controller.planSkip(
              dayIso,
              options[picked.clamp(0, options.length - 1)],
              cancelLunch: cancelLunch,
            );
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
    final listing = widget.days.map((d) => PlannerView._cz(d)).join(', ');
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
                for (final d in widget.days)
                  '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
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

/// Custom days-off picker: month calendar + picked days' lessons.
typedef _CustomPlanDialog = CustomPlanDialog;

/// Port of planner._custom_plan_dialog (simplified but functional).
class CustomPlanDialog extends StatefulWidget {
  final PlannerController controller;
  final bool stravaOn;
  final List<PickerSlot> Function(DateTime day) lessonsFor;
  final Set<DateTime> freeDays;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final DateTime? initialMonth;
  final DateTime? preselect;
  final DateTime? firstMonth;
  final DateTime? lastMonth;

  const CustomPlanDialog({
    super.key,
    required this.controller,
    required this.stravaOn,
    required this.lessonsFor,
    required this.freeDays,
    this.impactOfEntries,
    this.initialMonth,
    this.preselect,
    this.firstMonth,
    this.lastMonth,
  });

  @override
  State<CustomPlanDialog> createState() => _CustomPlanDialogState();
}

class _CustomPlanDialogState extends State<CustomPlanDialog> {
  final Map<DateTime, Set<int>> picked = {};
  late DateTime month;
  DateTime? openDay;
  int templateIdx = 0;
  bool cancelLunch = true;

  @override
  void initState() {
    super.initState();
    month = widget.initialMonth ?? clock.now();
    if (widget.preselect != null) {
      _tapDay(widget.preselect!);
    }
  }

  DateTime _norm(DateTime d) => DateTime(d.year, d.month, d.day);

  List<PickerSlot> _slots(DateTime day) {
    try {
      return widget.lessonsFor(day);
    } catch (_) {
      return const [];
    }
  }

  Set<int> _pickable(DateTime day) => {
    for (final s in _slots(day))
      if (s.pickable) s.period!,
  };

  bool _full(DateTime day) {
    final p = _pickable(day);
    return p.isNotEmpty && p.difference(picked[_norm(day)] ?? {}).isEmpty;
  }

  void _tapDay(DateTime day) {
    day = _norm(day);
    setState(() {
      if (_full(day)) {
        picked.remove(day);
        if (openDay == day) openDay = null;
      } else {
        picked[day] = _pickable(day);
        openDay = day;
      }
      picked.removeWhere((k, v) => v.isEmpty && k != openDay);
    });
  }

  List<Map<String, dynamic>> _entries(String template) {
    final chosen = <DateTime, Set<int>>{
      for (final e in picked.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    final lessons = <DateTime, Set<int>>{
      for (final day in chosen.keys)
        day: {
          for (final s in _slots(day))
            if (s.taught && s.period != null) s.period!,
        },
    };
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
    final entries = _entries(options[templateIdx.clamp(0, options.length - 1)]);
    final impacts = widget.impactOfEntries?.call(entries) ?? const [];
    final chosen = picked.keys.toList()..sort();
    return AlertDialog(
      title: Text(Strings.get('plan_custom')),
      content: SizedBox(
        width: w.dialogWidth(context, 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(Strings.get('pick_how')),
              _calendarHeader(),
              _calendarGrid(),
              for (final day in chosen) _dayBlock(day),
              Text(
                entries.isEmpty
                    ? Strings.get('pick_empty')
                    : Strings.format('pick_total', {
                        'days': daysText(
                          chosen
                              .where((d) => (picked[d] ?? {}).isNotEmpty)
                              .length,
                        ),
                        'lessons': picked.values.fold<int>(
                          0,
                          (n, s) => n + s.length,
                        ),
                      }),
              ),
              DropdownButton<int>(
                value: templateIdx.clamp(0, options.length - 1),
                items: [
                  for (var i = 0; i < options.length; i++)
                    DropdownMenuItem(value: i, child: Text(labels[i].value)),
                ],
                onChanged: (v) => setState(() => templateIdx = v ?? 0),
              ),
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
          onPressed: () => Navigator.of(context).pop(),
          child: Text(Strings.get('cancel')),
        ),
        FilledButton(
          onPressed: entries.isEmpty
              ? null
              : () {
                  final n = widget.controller.planEntries(entries);
                  Navigator.of(context).pop();
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

  Widget _calendarHeader() {
    final fm = widget.firstMonth != null
        ? DateTime(widget.firstMonth!.year, widget.firstMonth!.month, 1)
        : null;
    final lm = widget.lastMonth != null
        ? DateTime(widget.lastMonth!.year, widget.lastMonth!.month, 1)
        : null;
    final canPrev = fm == null || month.isAfter(fm);
    final canNext = lm == null || month.isBefore(lm);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: Strings.get('pick_prev_month'),
          onPressed: canPrev
              ? () => setState(() => month = monthAdd(month, -1))
              : null,
        ),
        Expanded(child: Center(child: Text('${month.month}/${month.year}'))),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: Strings.get('pick_next_month'),
          onPressed: canNext
              ? () => setState(() => month = monthAdd(month, 1))
              : null,
        ),
      ],
    );
  }

  Widget _calendarGrid() {
    final first = DateTime(month.year, month.month, 1);
    var monday = core.addDays(first, -(first.weekday - 1));
    final rows = <Widget>[];
    final end = monthAdd(month, 1);
    while (monday.isBefore(end)) {
      final week = [for (var i = 0; i < 5; i++) core.addDays(monday, i)];
      if (week.any((d) => d.month == month.month)) {
        rows.add(
          Row(
            children: [
              for (final d in week)
                Expanded(
                  child: d.month == month.month
                      ? _cell(d)
                      : const SizedBox(height: 44),
                ),
            ],
          ),
        );
      }
      monday = core.addDays(monday, 7);
    }
    return Column(children: rows);
  }

  Widget _cell(DateTime rawDay) {
    final day = _norm(rawDay);
    final sel = picked[day] ?? {};
    final pickable = _pickable(day);
    final full = pickable.isNotEmpty && pickable.difference(sel).isEmpty;
    final part = sel.isNotEmpty && !full;
    final free = widget.freeDays.contains(day);
    return InkWell(
      key: ValueKey('day_${day.year}_${day.month}_${day.day}'),
      onTap: (pickable.isEmpty || free) ? null : () => _tapDay(day),
      child: Container(
        height: 44,
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: full
              ? Theme.of(context).colorScheme.primary
              : part
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
              : null,
          borderRadius: BorderRadius.circular(8),
          border: free
              ? Border.all(color: Colors.grey)
              : day.year == clock.now().year &&
                    day.month == clock.now().month &&
                    day.day == clock.now().day
              ? Border.all(color: Theme.of(context).colorScheme.onSurface)
              : null,
        ),
        child: Text('${day.day}'),
      ),
    );
  }

  Widget _dayBlock(DateTime day) {
    final sel = picked[day] ?? {};
    final isOpen = openDay == day;
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(PlannerView._cz(day)),
            subtitle: Text(
              sel.isEmpty
                  ? Strings.get('pick_nothing')
                  : runsLabel([
                      for (final s in _slots(day))
                        if (s.period != null) s.period!,
                    ], sel),
            ),
            trailing: Checkbox(
              value: _full(day),
              tristate: true,
              onChanged: (_) {
                setState(() {
                  if (_full(day)) {
                    picked[day] = <int>{};
                  } else {
                    picked[day] = _pickable(day);
                  }
                  openDay = day;
                });
              },
            ),
            onTap: () => setState(() => openDay = isOpen ? null : day),
          ),
          if (isOpen)
            for (final slot in _slots(day))
              if (slot.period != null)
                CheckboxListTile(
                  title: Text('${slot.period}. ${slot.subject}'),
                  subtitle: slot.detail.isEmpty ? null : Text(slot.detail),
                  value: sel.contains(slot.period),
                  onChanged: !slot.pickable
                      ? null
                      : (v) => setState(() {
                          final s = picked.putIfAbsent(day, () => <int>{});
                          if (v == true) {
                            s.add(slot.period!);
                          } else {
                            s.remove(slot.period!);
                          }
                        }),
                ),
        ],
      ),
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
