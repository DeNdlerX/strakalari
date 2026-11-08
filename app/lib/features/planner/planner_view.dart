import 'package:flutter/material.dart';

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
  final List<String> tags; // bridge | long_weekend | light | free | final_week | late_week
  final int streak;
  final bool feasible;
  final Map<String, String> blockedNames;
  final List<String> blockedBy;
  final List<String> lessons;
  final bool finalWeek;

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
  });
}

/// One planned entry row with its computed cost.
class PlannedRowData {
  final Map<String, dynamic> entry;
  final List<DateTime> days;
  final int costHours;
  final bool over;
  final bool reserve;

  const PlannedRowData({
    required this.entry,
    required this.days,
    this.costHours = 0,
    this.over = false,
    this.reserve = false,
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
    this.planned = const [],
    this.hasData = false,
    this.active = false,
  });
}

class TightestData {
  final String name;
  final double free;
  final String status;

  const TightestData(
      {required this.name, required this.free, required this.status});
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

  bool get pickable =>
      taught && period != null && !past && !planned;
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

  @override
  Widget build(BuildContext context) {
    final reserve = controller.planReserve();
    final intro =
        '${Str.t('planner_desc')} ${Str.t('plan_buffer_note', {'reserve': reserve})}';
    if (plan == null || !hasData) {
      return ListView(
        children: [
          ListTile(title: Text(Str.t('planner_title')), subtitle: Text(updatedLabel)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(intro),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(Str.t('no_data')),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(!hasTimetable
                ? Str.t('planner_need_refresh')
                : Str.t('need_credentials')),
          ),
        ],
      );
    }
    final p = plan!;
    final term = p.term(controller.plannerTerm) ?? p.defaultTerm;
    return ListView(
      children: [
        ListTile(
          title: Text(Str.t('planner_title')),
          subtitle: Text(updatedLabel),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                  onPressed: onOpenAbsences,
                  child: Text(Str.t('see_absences'))),
              FilledButton(
                onPressed: () => showCustomPlanDialog(context),
                child: Text(Str.t('plan_custom')),
              ),
            ],
          ),
        ),
        Padding(padding: const EdgeInsets.all(12), child: Text(intro)),
        if (term != null) ...[
          if (p.terms.length > 1)
            Wrap(
              spacing: 8,
              children: [
                for (final other in p.terms)
                  ChoiceChip(
                    label: Text(
                        '${other.key == 'sem1' ? Str.t('term_sem1') : Str.t('term_sem2')} · ${Str.t('term_until', {'d': _cz(other.close)})}'),
                    selected: other.key == term.key,
                    onSelected: (_) =>
                        controller.selectPlannerTerm(other.key),
                  ),
              ],
            ),
          if (!term.hasData)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(Str.t('term_fresh')),
            ),
          _statsRow(term),
          ..._warnings(term),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(Str.t('section_overview'),
                style: Theme.of(context).textTheme.titleMedium),
          ),
          _calendarStrip(context, p, term),
          _recommended(context, p, term),
          ..._budgets(context, term),
        ],
        ..._planned(context, p),
        Padding(padding: const EdgeInsets.all(12), child: Text(calendarSummary)),
        TextButton(
            onPressed: onOpenCalendar,
            child: Text(Str.t('cal_open_calendar'))),
      ],
    );
  }

  Widget _statsRow(TermPlanData term) {
    final plannedDays =
        term.plannedDates.intersection(term.remainingDays.toSet()).length;
    final plannedHours =
        term.planned.fold(0, (sum, r) => sum + r.costHours);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _stat(Str.t('stat_can_afford'), daysText(term.capacity)),
        _stat(Str.t('stat_planned'),
            '${daysText(plannedDays)} · $plannedHours h'),
        _stat(
            '${Str.t('stat_tightest')} · ${Str.t('hours_free', {'n': hoursText(term.tightest?.free ?? 0)})}',
            term.tightest?.name ?? '—'),
        _stat(Str.t('planner_horizon'), '${term.remainingDays.length}'),
      ],
    );
  }

  Widget _stat(String label, String value) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [Text(label), Text(value)],
          ),
        ),
      );

  List<Widget> _warnings(TermPlanData term) {
    final out = <Widget>[];
    final over = term.planned
        .where((r) => r.over)
        .map((r) => entryLabel(r.entry))
        .toSet();
    final reserveW = term.planned
        .where((r) => r.reserve && !r.over)
        .map((r) => entryLabel(r.entry))
        .toSet();
    if (over.isNotEmpty) {
      out.add(Text(Str.t('warn_over', {'subjects': over.join(', ')}),
          style: const TextStyle(color: Colors.red)));
    }
    if (reserveW.isNotEmpty) {
      out.add(Text(
          Str.t('warn_reserve', {'subjects': reserveW.join(', ')}),
          style: const TextStyle(color: Colors.orange)));
    }
    if (term.fastPace.isNotEmpty) {
      out.add(Text(
          Str.t('warn_pace', {'subjects': term.fastPace.join(', ')}),
          style: const TextStyle(color: Colors.orange)));
    }
    return out;
  }

  Widget _calendarStrip(
      BuildContext context, YearPlanData p, TermPlanData term) {
    final recommended = {for (final o in term.recommended) o.day};
    final overDays = <DateTime>{};
    for (final row in term.planned) {
      if (row.over) overDays.addAll(row.days);
    }
    if (narrow) {
      // Phone: one row per week (Mon–Fri), numbered finger-sized cells.
      var monday = term.start
          .subtract(Duration(days: term.start.weekday - 1));
      final rows = <Widget>[];
      while (!monday.isAfter(term.close)) {
        final week = [
          for (var i = 0; i < 5; i++) monday.add(Duration(days: i))
        ];
        rows.add(Row(
          children: [
            for (final d in week)
              Expanded(
                  child: _cell(
                      context, p, term, d, recommended, overDays,
                      numbered: true)),
          ],
        ));
        monday = monday.add(const Duration(days: 7));
      }
      return Card(child: Column(children: rows));
    }
    var monday =
        term.start.subtract(Duration(days: term.start.weekday - 1));
    final columns = <Widget>[];
    while (!monday.isAfter(term.close)) {
      final week = [
        for (var i = 0; i < 5; i++) monday.add(Duration(days: i))
      ];
      columns.add(Expanded(
        child: Column(
          children: [
            for (final d in week)
              _cell(context, p, term, d, recommended, overDays),
          ],
        ),
      ));
      monday = monday.add(const Duration(days: 7));
    }
    return Card(child: Row(children: columns));
  }

  Widget _cell(BuildContext context, YearPlanData p, TermPlanData term,
      DateTime day, Set<DateTime> recommended, Set<DateTime> overDays,
      {bool numbered = false}) {
    final scheme = Theme.of(context).colorScheme;
    if (day.isBefore(term.start) || day.isAfter(term.close)) {
      return SizedBox(height: numbered ? 36 : 18);
    }
    final key = DateTime(day.year, day.month, day.day);
    Color? fill;
    if (p.holidays.contains(key)) {
      fill = null;
    } else if (term.plannedDates.contains(key)) {
      fill = overDays.contains(key) ? Colors.red : scheme.primary;
    } else if (recommended.contains(key)) {
      fill = Colors.green;
    } else {
      fill = scheme.surfaceContainerHighest;
    }
    final isPast = day.isBefore(p.firstDay);
    final label =
        '${_weekdayShort(day.weekday)} ${_cz(day)}';
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: term.plannedDates.contains(key)
            ? () => showPlannedDialog(
                context, controller.plannedFor(_iso(key)) ?? {'start_date': _iso(key), 'end_date': _iso(key)})
            : () => showPlanDayDialog(context, key),
        child: Container(
          height: numbered ? 36 : 18,
          margin: const EdgeInsets.all(1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(4),
            border: day.year == p.today.year &&
                    day.month == p.today.month &&
                    day.day == p.today.day
                ? Border.all(color: scheme.onSurface)
                : null,
          ),
          child: numbered
              ? Text('${day.day}',
                  style: TextStyle(
                      color: isPast ? Colors.grey : null, fontSize: 12))
              : null,
        ),
      ),
    );
  }

  Widget _recommended(
      BuildContext context, YearPlanData p, TermPlanData term) {
    final picks = term.recommended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                  '${Str.t('section_plan')} (${picks.length})',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            _targetDropdown(),
            if (picks.isNotEmpty)
              FilledButton(
                onPressed: () => showPlanAllDialog(
                    context, [for (final o in picks) o.day]),
                child: Text('${Str.t('plan_all')} (${picks.length})'),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(Str.t('plan_explain')),
        ),
        if (picks.isEmpty)
          Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(Str.t('plan_budget_empty')),
          )),
        for (final option in picks)
          Card(
            child: ListTile(
              title: Text(
                  '${_weekdayLong(option.day.weekday)} ${_cz(option.day)}'),
              subtitle: Text(_costText(option)),
              trailing: FilledButton(
                onPressed: () => showPlanDayDialog(context, option.day),
                child: Text(Str.t('plan_skip')),
              ),
            ),
          ),
      ],
    );
  }

  Widget _targetDropdown() {
    final already = 0;
    final maximum = already + 0;
    final current = controller.plannerTargetDays();
    final top = [maximum, current, 1].reduce((a, b) => a > b ? a : b);
    return DropdownButton<int>(
      value: current <= top ? current : 0,
      items: [
        DropdownMenuItem(
            value: 0,
            child: Text(Str.t('target_auto', {'n': maximum}))),
        for (var i = 1; i <= (top > 60 ? 60 : top); i++)
          DropdownMenuItem(value: i, child: Text(daysText(i))),
      ],
      onChanged: (v) {
        if (v != null) controller.setPlannerTarget(v);
      },
    );
  }

  List<Widget> _budgets(BuildContext context, TermPlanData term) {
    if (term.budgets.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(Str.t('section_budgets'),
            style: Theme.of(context).textTheme.titleMedium),
      ),
      Card(
        child: Column(
          children: [
            for (final b in term.budgets)
              ListTile(
                title: Text(b.name),
                subtitle: LinearProgressIndicator(
                  value: (b.projectedPct / 100).clamp(0.0, 1.0),
                ),
                trailing: Text(Str.t('budget_final',
                    {'p': b.projectedPct.toStringAsFixed(1), 'limit': b.limitPct})),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _planned(BuildContext context, YearPlanData p) {
    final planned = controller.plannedSkips;
    return [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text('${Str.t('planned_title')} (${planned.length})',
            style: Theme.of(context).textTheme.titleMedium),
      ),
      if (planned.isEmpty)
        Card(
            child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(Str.t('no_planned')),
        )),
      for (final entry in planned)
        Card(
          child: ListTile(
            title: Text(entryLabel(entry)),
            trailing: TextButton(
              onPressed: () {
                if (controller.unplanEntry(entry)) {
                  appSnack(context, Str.t('plan_removed'));
                } else {
                  appSnack(context, Str.t('save_failed'));
                }
              },
              child: Text(Str.t('unplan')),
            ),
            onTap: () => showPlannedDialog(context, entry),
          ),
        ),
    ];
  }

  String _costText(DayOptionData option) {
    if (option.cost == 0) {
      return '${option.lessonsCount} · ${Str.t('day_cost_free')}';
    }
    return '${option.lessonsCount} · ${Str.t('day_cost', {'n': option.budgetHours})}';
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
          stravaOn: stravaOn),
    );
  }

  Future<void> showPlannedDialog(
      BuildContext context, Map<String, dynamic> entry) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entryLabel(entry)),
        content: Text('${entry['template'] ?? ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(Str.t('cancel'))),
          TextButton(
            onPressed: () {
              final ok = controller.unplanEntry(entry);
              Navigator.of(ctx).pop();
              appSnack(context,
                  ok ? Str.t('plan_removed') : Str.t('save_failed'));
            },
            child: Text(Str.t('unplan')),
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

  static String _weekdayShort(int weekday) {
    const cs = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];
    const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return (Str.language == 'en' ? en : cs)[weekday - 1];
  }

  static String _weekdayLong(int weekday) {
    const cs = [
      'Pondělí',
      'Úterý',
      'Středa',
      'Čtvrtek',
      'Pátek',
      'Sobota',
      'Neděle'
    ];
    const en = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    return (Str.language == 'en' ? en : cs)[weekday - 1];
  }
}

/// Single-day plan dialog: template picker + lunch toggle + impact preview.
/// Port of planner._plan_dialog (Flet dialog cases).
class _PlanDayDialog extends StatefulWidget {
  final PlannerController controller;
  final DateTime day;
  final bool stravaOn;
  final bool Function(String dayLabel)? isLunchOpen;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;

  const _PlanDayDialog({
    required this.controller,
    required this.day,
    required this.stravaOn,
    this.isLunchOpen,
    this.impactOf,
  });

  @override
  State<_PlanDayDialog> createState() => _PlanDayDialogState();
}

class _PlanDayDialogState extends State<_PlanDayDialog> {
  int picked = 0;
  bool cancelLunch = true;

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(widget.controller.config,
        kind: 'day',
        signature: '${widget.controller.get('your_signature', '')}');
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
    final impacts = widget.impactOf?.call({
          'start_date': dayIso,
          'end_date': dayIso,
        }) ??
        const [];
    return AlertDialog(
      title: Text(
          "${Str.t('plan_skip')}: ${PlannerView._weekdayLong(widget.day.weekday)} ${PlannerView._cz(widget.day)}"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Str.t('choose_template')),
            DropdownButton<int>(
              value: picked.clamp(0, options.length - 1),
              items: [
                for (var i = 0; i < labels.length; i++)
                  DropdownMenuItem(
                      value: i, child: Text(labels[i].value)),
              ],
              onChanged: (v) =>
                  setState(() => picked = v ?? 0),
            ),
            Text(options[picked.clamp(0, options.length - 1)]),
            if (widget.stravaOn && orderOpen)
              CheckboxListTile(
                title: Text(Str.t('plan_cancel_lunch')),
                value: cancelLunch,
                onChanged: (v) =>
                    setState(() => cancelLunch = v ?? true),
              ),
            if (widget.stravaOn && !orderOpen)
              Text(Str.t('lunch_cannot_cancel', {'deadline': '—'})),
            ...impactWidgets(impacts),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(Str.t('cancel'))),
        FilledButton(
          onPressed: () {
            final ok = widget.controller.planSkip(
                dayIso, options[picked.clamp(0, options.length - 1)],
                cancelLunch: cancelLunch);
            Navigator.of(context).pop();
            appSnack(context,
                ok ? Str.t('skip_planned') : Str.t('skip_not_planned'));
          },
          child: Text(Str.t('confirm')),
        ),
      ],
    );
  }

  List<Widget> impactWidgets(List<ImpactTerm> impacts) {
    if (impacts.isEmpty) return [];
    final out = <Widget>[Text(Str.t('impact_title'))];
    var worst = 'ok';
    var anyRows = false;
    for (final term in impacts) {
      if (impacts.length > 1) out.add(Text(term.label));
      for (final row in term.rows) {
        anyRows = true;
        if (row.level == 'over' ||
            (row.level == 'reserve' && worst == 'ok')) {
          worst = row.level;
        }
        out.add(Text(Str.t('impact_row', {
          'name': row.name,
          'cost': row.cost,
          'left': hoursText(row.freeAfter),
          'p': row.projectedAfter.toStringAsFixed(1),
        })));
      }
    }
    if (!anyRows) {
      out.add(Text(Str.t('impact_none')));
      return out;
    }
    out.add(Text(Str.t(
        worst == 'over'
            ? 'impact_over'
            : worst == 'reserve'
                ? 'impact_reserve'
                : 'impact_ok')));
    return out;
  }
}

/// Plan-all dialog: one template for every recommended day.
class _PlanAllDialog extends StatefulWidget {
  final PlannerController controller;
  final List<DateTime> days;
  final bool stravaOn;

  const _PlanAllDialog(
      {required this.controller, required this.days, required this.stravaOn});

  @override
  State<_PlanAllDialog> createState() => _PlanAllDialogState();
}

class _PlanAllDialogState extends State<_PlanAllDialog> {
  int picked = 0;
  bool cancelLunch = true;

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(widget.controller.config,
        kind: 'day',
        signature: '${widget.controller.get('your_signature', '')}');
    final options = [for (final e in named) e.value];
    final listing = widget.days
        .map((d) => PlannerView._cz(d))
        .join(', ');
    return AlertDialog(
      title: Text(Str.t('plan_all_title')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Str.t('plan_all_body', {'days': listing})),
            DropdownButton<int>(
              value: picked.clamp(0, options.length - 1),
              items: [
                for (var i = 0; i < options.length; i++)
                  DropdownMenuItem(value: i, child: Text('Šablona ${i + 1}')),
              ],
              onChanged: (v) =>
                  setState(() => picked = v ?? 0),
            ),
            Text(options[picked.clamp(0, options.length - 1)]),
            if (widget.stravaOn)
              CheckboxListTile(
                title: Text(Str.t('plan_cancel_lunch')),
                value: cancelLunch,
                onChanged: (v) =>
                    setState(() => cancelLunch = v ?? true),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(Str.t('cancel'))),
        FilledButton(
          onPressed: () {
            final n = widget.controller.planDays(
              [
                for (final d in widget.days)
                  '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
              ],
              options[picked.clamp(0, options.length - 1)],
              cancelLunch: cancelLunch,
            );
            Navigator.of(context).pop();
            appSnack(
                context,
                n > 0
                    ? Str.t('plan_all_done', {'n': n})
                    : Str.t('skip_not_planned'));
          },
          child: Text(Str.t('confirm')),
        ),
      ],
    );
  }
}

/// Custom days-off picker: month calendar + picked days' lessons.
/// Port of planner._custom_plan_dialog (simplified but functional).
class _CustomPlanDialog extends StatefulWidget {
  final PlannerController controller;
  final bool stravaOn;
  final List<PickerSlot> Function(DateTime day) lessonsFor;
  final Set<DateTime> freeDays;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
      impactOfEntries;

  const _CustomPlanDialog({
    required this.controller,
    required this.stravaOn,
    required this.lessonsFor,
    required this.freeDays,
    this.impactOfEntries,
  });

  @override
  State<_CustomPlanDialog> createState() => _CustomPlanDialogState();
}

class _CustomPlanDialogState extends State<_CustomPlanDialog> {
  final Map<DateTime, Set<int>> picked = {};
  DateTime month = DateTime.now();
  DateTime? openDay;
  int templateIdx = 0;
  bool cancelLunch = true;

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
    final out = <Map<String, dynamic>>[];
    for (final day in picked.keys) {
      final sel = picked[day] ?? {};
      if (sel.isEmpty) continue;
      final taught = [
        for (final s in _slots(day))
          if (s.taught && s.period != null) s.period!,
      ];
      // Fewest entries covering exactly the picked lessons: whole day
      // when everything taught is picked, else one partial-day entry.
      final whole = taught.isNotEmpty &&
          sel.containsAll(taught) &&
          taught.toSet().containsAll(sel);
      out.add({
        'start_date':
            '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        'end_date':
            '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        'start_period': whole ? null : sel.reduce((a, b) => a < b ? a : b),
        'end_period': whole ? null : sel.reduce((a, b) => a > b ? a : b),
        'template': template,
        'cancel_lunch': cancelLunch,
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final named = templateOptions(widget.controller.config,
        kind: 'day',
        signature: '${widget.controller.get('your_signature', '')}');
    final options = [for (final e in named) e.value];
    final entries = _entries(options[templateIdx.clamp(0, options.length - 1)]);
    final impacts = widget.impactOfEntries?.call(entries) ?? const [];
    final chosen = picked.keys.toList()..sort();
    return AlertDialog(
      title: Text(Str.t('plan_custom')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(Str.t('pick_how')),
              _calendarHeader(),
              _calendarGrid(),
              for (final day in chosen) _dayBlock(day),
              Text(entries.isEmpty
                  ? Str.t('pick_empty')
                  : Str.t('pick_total', {
                      'days': daysText(chosen
                          .where((d) => (picked[d] ?? {}).isNotEmpty)
                          .length),
                      'lessons': picked.values.fold<int>(
                          0, (n, s) => n + s.length),
                    })),
              DropdownButton<int>(
                value: templateIdx.clamp(0, options.length - 1),
                items: [
                  for (var i = 0; i < options.length; i++)
                    DropdownMenuItem(
                        value: i, child: Text('Šablona ${i + 1}')),
                ],
                onChanged: (v) =>
                    setState(() => templateIdx = v ?? 0),
              ),
              if (widget.stravaOn)
                CheckboxListTile(
                  title: Text(Str.t('plan_cancel_lunch')),
                  value: cancelLunch,
                  onChanged: (v) =>
                      setState(() => cancelLunch = v ?? true),
                ),
              _PlanDayDialogStaticImpact(impacts: impacts),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(Str.t('cancel'))),
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
                              ? Str.t('skip_planned')
                              : Str.t('skip_planned_keep_lunch'))
                          : Str.t('skip_not_planned'));
                },
          child: Text(Str.t('confirm')),
        ),
      ],
    );
  }

  Widget _calendarHeader() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: Str.t('pick_prev_month'),
          onPressed: () =>
              setState(() => month = monthAdd(month, -1)),
        ),
        Expanded(child: Center(child: Text('${month.month}/${month.year}'))),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: Str.t('pick_next_month'),
          onPressed: () =>
              setState(() => month = monthAdd(month, 1)),
        ),
      ],
    );
  }

  Widget _calendarGrid() {
    final first = DateTime(month.year, month.month, 1);
    var monday = first.subtract(Duration(days: first.weekday - 1));
    final rows = <Widget>[];
    final end = monthAdd(month, 1);
    while (monday.isBefore(end)) {
      final week = [
        for (var i = 0; i < 5; i++) monday.add(Duration(days: i))
      ];
      if (week.any((d) => d.month == month.month)) {
        rows.add(Row(
          children: [
            for (final d in week)
              Expanded(
                  child: d.month == month.month
                      ? _cell(d)
                      : const SizedBox(height: 44)),
          ],
        ));
      }
      monday = monday.add(const Duration(days: 7));
    }
    return Column(children: rows);
  }

  Widget _cell(DateTime rawDay) {
    final day = _norm(rawDay);
    final sel = picked[day] ?? {};
    final pickable = _pickable(day);
    final full = pickable.isNotEmpty &&
        pickable.difference(sel).isEmpty;
    final part = sel.isNotEmpty && !full;
    final free = widget.freeDays.contains(day);
    return InkWell(
      onTap: (pickable.isEmpty || free) ? null : () => _tapDay(day),
      child: Container(
        height: 44,
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: full
              ? Theme.of(context).colorScheme.primary
              : part
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.3)
                  : null,
          borderRadius: BorderRadius.circular(8),
          border: free
              ? Border.all(color: Colors.grey)
              : day.year == DateTime.now().year &&
                      day.month == DateTime.now().month &&
                      day.day == DateTime.now().day
                  ? Border.all(
                      color: Theme.of(context).colorScheme.onSurface)
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
            subtitle: Text(sel.isEmpty
                ? Str.t('pick_nothing')
                : runsLabel(
                    [for (final s in _slots(day)) if (s.period != null) s.period!],
                    sel)),
            trailing: Checkbox(
              value: _full(day),
              tristate: true,
              onChanged: (_) => _tapDay(day),
            ),
            onTap: () => setState(
                () => openDay = isOpen ? null : day),
          ),
          if (isOpen)
            for (final slot in _slots(day))
              if (slot.period != null)
                CheckboxListTile(
                  title: Text('${slot.period}. ${slot.subject}'),
                  subtitle:
                      slot.detail.isEmpty ? null : Text(slot.detail),
                  value: sel.contains(slot.period),
                  onChanged: !slot.pickable
                      ? null
                      : (v) => setState(() {
                            final s = picked
                                .putIfAbsent(day, () => <int>{});
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
        Text(Str.t('impact_title')),
        for (final term in impacts)
          for (final row in term.rows)
            Text(Str.t('impact_row', {
              'name': row.name,
              'cost': row.cost,
              'left': hoursText(row.freeAfter),
              'p': row.projectedAfter.toStringAsFixed(1),
            })),
      ],
    );
  }
}

/// Reserve editor dialog (the planner's reserve entry point).
class ReserveDialog extends StatefulWidget {
  final double current;
  final void Function(double value) onSave;

  const ReserveDialog(
      {super.key, required this.current, required this.onSave});

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
      title: Text(Str.t('reserve_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Str.t('reserve_body')),
          TextField(
              controller: text,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(Str.t('cancel'))),
        FilledButton(
          onPressed: () {
            final v = double.tryParse(text.text.replaceAll(',', '.'));
            if (v == null || v < 0 || v > 99.9) {
              appSnack(context, Str.t('save_failed'));
              return;
            }
            widget.onSave(v);
            Navigator.of(context).pop();
          },
          child: Text(Str.t('confirm')),
        ),
      ],
    );
  }
}
