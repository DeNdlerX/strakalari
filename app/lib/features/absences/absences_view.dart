import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../tutorial/tutorial_ui.dart';
import '../../widgets/app_widgets.dart' as w;
import '../common/app_tokens.dart';
import '../planner/plan_reserve.dart' show daysText, hoursText;
import '../planner/planner_controller.dart';
import '../planner/planner_view.dart';
import 'absences_controller.dart';

/// Unified Absences & Planner (Absence) screen.
///
/// Combines per-subject absence percentages, limits editing, semester calendar
/// overview, recommended days off, unified subject + hour-budget cards, and
/// planned-entry management in a single scrollable view.
class AbsencesView extends StatelessWidget {
  final AbsencesController controller;
  final AppTokens tokens;
  final bool narrow;
  final PlannerController? planner;
  final YearPlanData? plan;
  final bool hasTimetable;
  final String calendarSummary;
  final bool stravaOn;
  final List<ImpactTerm> Function(Map<String, dynamic> entry)? impactOf;
  final List<ImpactTerm> Function(List<Map<String, dynamic>> entries)?
  impactOfEntries;
  final List<PickerSlot> Function(DateTime day)? lessonsFor;
  final Set<DateTime> Function()? freeDays;
  final VoidCallback? onOpenCalendar;
  final VoidCallback? onOpenLimits;
  final void Function(String template)? tutorialEvent;

  const AbsencesView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
    this.planner,
    this.plan,
    this.hasTimetable = true,
    this.calendarSummary = '',
    this.stravaOn = false,
    this.impactOf,
    this.impactOfEntries,
    this.lessonsFor,
    this.freeDays,
    this.onOpenCalendar,
    this.onOpenLimits,
    this.tutorialEvent,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PlannerListener(
        controller: planner,
        builder: (context) => _body(context),
      ),
    );
  }

  Widget? _noLimitsBanner(BuildContext context) {
    final c = controller;
    if (c.hasSubjectLimits || onOpenLimits == null) return null;
    final t = tokens;
    return Card(
      key: const Key('abs:no_limits_banner'),
      color: t.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(color: t.border),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.pad, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                Strings.format('abs_no_limits', {'pct': c.defaultLimitPct}),
                style: TextStyle(color: t.muted, fontSize: t.fsSmall),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('abs:no_limits_btn'),
              onPressed: onOpenLimits,
              child: Text(Strings.get('abs_limits_btn')),
            ),
          ],
        ),
      ),
    );
  }

  static String _termTitle(TermPlanData t) =>
      t.key == 'sem1' ? Strings.get('term_sem1') : Strings.get('term_sem2');

  Widget _body(BuildContext context) {
    final c = controller;
    final t = tokens;
    final hasPlan = planner != null && plan != null;
    final hasData = c.subjects.isNotEmpty;
    final term = hasPlan && hasData
        ? (plan!.term(planner!.plannerTerm) ?? plan!.defaultTerm)
        : null;

    final plannerSections = hasPlan && hasData
        ? PlannerSections(
            controller: planner!,
            plan: plan,
            hasTimetable: hasTimetable,
            hasData: hasData,
            calendarSummary: calendarSummary,
            stravaOn: stravaOn,
            narrow: narrow,
            impactOf: impactOf,
            impactOfEntries: impactOfEntries,
            lessonsFor: lessonsFor,
            freeDays: freeDays,
            onOpenCalendar: onOpenCalendar,
            tutorialEvent: tutorialEvent,
            subjectsSection: term != null ? _subjectsSection(term) : null,
            embedded: true,
          )
        : null;

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
    final compactTextStyle = narrow ? TextStyle(fontSize: t.fsSmall) : null;

    final actions = <Widget>[
      if (onOpenLimits != null)
        OutlinedButton.icon(
          key: const Key('abs:limits_btn'),
          style: compactStyle,
          onPressed: onOpenLimits,
          icon: Icon(Icons.tune, size: narrow ? 16 : 18),
          label: Text(
            Strings.get('abs_limits_btn'),
            style: compactTextStyle,
            textAlign: narrow ? TextAlign.center : null,
            maxLines: narrow ? 2 : null,
          ),
        ),
      if (plannerSections != null)
        Tooltip(
          message: Strings.get('plan_custom_hint'),
          child: ElevatedButton.icon(
            style: compactStyle,
            onPressed: () => plannerSections.showCustomPlanDialog(context),
            icon: Icon(Icons.edit_calendar_outlined, size: narrow ? 16 : 18),
            label: Text(
              Strings.get('plan_custom'),
              style: compactTextStyle,
              textAlign: narrow ? TextAlign.center : null,
              maxLines: narrow ? 2 : null,
            ),
          ),
        ),
    ];

    final header = w.HeaderRow(
      heading: Strings.get('absence_title'),
      updated: c.updatedLabel,
      tok: t,
      actions: narrow ? const [] : actions,
    );
    final noLimits = _noLimitsBanner(context);
    final gap = narrow ? t.gap * 0.75 : t.gap;

    final blocks = <Widget>[header];
    if (narrow && actions.isNotEmpty) {
      blocks.add(
        actions.length == 1
            ? Align(alignment: Alignment.centerLeft, child: actions.first)
            : Row(
                spacing: 8,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [for (final a in actions) Expanded(child: a)],
              ),
      );
    }
    if (noLimits != null) blocks.add(noLimits);

    // Case 1: no subjects (no timetable or no absence data).
    if (!hasData) {
      blocks.add(w.EmptyState(text: Strings.get('no_data'), tok: t));
      if (!hasTimetable) {
        blocks.add(
          Text(
            Strings.get('planner_need_refresh'),
            style: TextStyle(color: t.faint, fontSize: t.fsSmall),
          ),
        );
      }
      if (c.demoMode) {
        blocks.add(
          Text(
            Strings.get('need_credentials'),
            style: TextStyle(color: t.faint, fontSize: t.fsSmall),
          ),
        );
      }
      return _scroll(blocks, gap);
    }

    // Case 2: subjects present, no active term (closed year or standalone view).
    if (term == null) {
      blocks.add(_threeCardStats());
      blocks.add(_subjectCardsList(null));
      if (plannerSections != null) {
        blocks.add(plannerSections);
      } else if (!hasTimetable) {
        blocks.add(
          Text(
            Strings.get('planner_need_refresh'),
            style: TextStyle(color: t.faint, fontSize: t.fsSmall),
          ),
        );
      }
      return _scroll(blocks, gap);
    }

    // Case 3: active term — full merged screen.
    if (plan!.terms.length >= 2) {
      final termButtons = [
        for (final other in plan!.terms)
          () {
            final label =
                '${_termTitle(other)} · ${Strings.format('term_until', {'d': w.czDay(other.close)})}';
            void pick() => planner!.selectPlannerTerm(other.key);
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
                spacing: t.gap / 2,
                children: [for (final b in termButtons) Expanded(child: b)],
              )
            : Wrap(
                spacing: t.gap / 2,
                runSpacing: t.gap / 2,
                children: termButtons,
              ),
      );
    }
    if (!term.hasData) {
      blocks.add(
        Text(
          Strings.get('term_fresh'),
          style: TextStyle(color: t.accent, fontSize: t.fsSmall),
        ),
      );
    }
    blocks.add(_fourCardStats(term));
    blocks.add(plannerSections!);
    return _scroll(blocks, gap);
  }

  Widget _scroll(List<Widget> blocks, double gap) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          blocks[i],
          if (i != blocks.length - 1) SizedBox(height: gap),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _threeCardStats() {
    final c = controller;
    final t = tokens;
    return TutorialAnchor(
      anchorKey: 'abs_stats',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: t.gap,
          children: [
            w.StatCard(
              label: Strings.get('avg_absence'),
              value: '${c.average.toStringAsFixed(1)} %',
              tok: t,
            ),
            w.StatCard(
              label: Strings.get('warn_subjects'),
              value: '${c.warnCount}',
              tok: t,
              kind: c.warnCount > 0 ? 'warning' : 'ok',
            ),
            w.StatCard(
              label: Strings.get('crit_subjects'),
              value: '${c.critCount}',
              tok: t,
              kind: c.critCount > 0 ? 'critical' : 'ok',
            ),
          ],
        ),
      ),
    );
  }

  Widget _fourCardStats(TermPlanData term) {
    final c = controller;
    final t = tokens;
    final remaining = term.remainingDays.toSet();
    final plannedDays = term.plannedDates.intersection(remaining).length;
    final plannedHours = term.planned.fold(0, (sum, r) => sum + r.costHours);
    final warnCritKind = c.critCount > 0
        ? 'critical'
        : (c.warnCount > 0 ? 'warning' : 'ok');

    final cards = <Widget>[
      w.StatCard(
        label: Strings.get('avg_absence'),
        value: '${c.average.toStringAsFixed(1)} %',
        tok: t,
      ),
      w.StatCard(
        label: Strings.get('stat_warn_crit'),
        value: '${c.warnCount} / ${c.critCount}',
        tok: t,
        kind: warnCritKind,
      ),
      w.StatCard(
        label: Strings.get('stat_can_afford'),
        value: daysText(term.capacity),
        tok: t,
        kind: term.capacity > 0 ? 'ok' : 'warning',
      ),
      w.StatCard(
        label: Strings.get('stat_planned'),
        value: '${daysText(plannedDays)} · $plannedHours h',
        tok: t,
        kind: plannedDays > 0 ? 'sent' : 'info',
      ),
    ];

    final Widget grid;
    if (!narrow) {
      grid = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: t.gap,
          children: cards,
        ),
      );
    } else {
      final half = t.gap / 2;
      grid = Column(
        spacing: half,
        children: [
          for (var i = 0; i < cards.length; i += 2)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: half,
                children: cards.sublist(i, i + 2),
              ),
            ),
        ],
      );
    }

    final tight = term.tightest;
    final summary = [
      '${Strings.get('planner_horizon')}: ${term.remainingDays.length}',
      if (tight != null)
        '${Strings.get('stat_tightest')}: ${tight.name} (${Strings.format('hours_free', {'n': hoursText(tight.free)})})',
    ].join(' · ');

    return TutorialAnchor(
      anchorKey: 'abs_stats',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: narrow ? 4 : 6,
        children: [
          grid,
          Text(
            summary,
            style: TextStyle(color: t.muted, fontSize: t.fsSmall),
          ),
        ],
      ),
    );
  }

  Widget _subjectsSection(TermPlanData term) {
    final t = tokens;
    final hasBudgets = term.budgets.isNotEmpty;
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
          style: TextStyle(color: t.muted, fontSize: t.fsTiny),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: narrow ? t.gap * 0.5 : t.gap * 0.75,
      children: [
        w.SectionHeader(Strings.get('abs_subjects_section'), tok: t),
        if (hasBudgets)
          Wrap(
            spacing: t.gap,
            runSpacing: 4,
            children: [
              legend(t.muted, Strings.get('legend_missed')),
              legend(t.accent, Strings.get('legend_planned')),
              legend(t.green, Strings.get('legend_free_h')),
              legend(
                tintColor(t.yellow, 0.55),
                Strings.get('legend_buffer'),
              ),
            ],
          ),
        _subjectCardsList(term),
      ],
    );
  }

  Widget _subjectCardsList(TermPlanData? term) {
    final c = controller;
    final t = tokens;
    final budgetByCanon = <String, BudgetRowData>{
      if (term != null)
        for (final b in term.budgets)
          AbsencesController.canonSubject(b.name): b,
    };
    final rowGap = (t.gap ~/ 2) + (narrow ? 2.0 : 0.0);
    return Column(
      key: const Key('abs:subjects'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < c.subjects.length; i++) ...[
          if (i > 0) SizedBox(height: rowGap),
          if (i == 0)
            TutorialAnchor(
              anchorKey: 'abs_first',
              child: _subjectRow(
                c.subjects[i],
                budgetByCanon[AbsencesController.canonSubject(c.subjects[i].name)],
              ),
            )
          else
            _subjectRow(
              c.subjects[i],
              budgetByCanon[AbsencesController.canonSubject(c.subjects[i].name)],
            ),
        ],
      ],
    );
  }

  Widget _subjectRow(SubjectAbsence subject, BudgetRowData? budget) {
    if (budget == null) return _meterRow(subject);
    final t = tokens;
    final absTier = switch (subject.status) {
      'critical' => 3,
      'warning' => 2,
      _ => 1,
    };
    final budTier = switch (budget.status) {
      'over' => 3,
      'reserve' || 'tight' => 2,
      _ => 1,
    };
    final String badgeKind;
    final String badgeText;
    if (absTier > budTier) {
      badgeKind = subject.status;
      badgeText = Strings.get(
        const {
              'critical': 'state_critical',
              'warning': 'state_warning',
            }[subject.status] ??
            'state_ok',
      );
    } else {
      badgeKind =
          const {
            'over': 'critical',
            'reserve': 'warning',
            'tight': 'warning',
          }[budget.status] ??
          'ok';
      badgeText = Strings.get(
        const {
              'over': 'budget_over',
              'reserve': 'budget_reserve',
              'tight': 'budget_tight',
            }[budget.status] ??
            'budget_ok',
      );
    }

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 8,
            children: [
              Expanded(
                child: Text(
                  subject.name,
                  style: TextStyle(
                    color: t.text,
                    fontSize: t.fsBody,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${subject.currentPct.toStringAsFixed(1)} %',
                style: TextStyle(color: t.muted, fontSize: t.fsSmall),
              ),
              w.Badge(text: badgeText, tok: t, kind: badgeKind),
            ],
          ),
          plannerBudgetBar(t, budget),
          Text(
            Strings.format('budget_final', {
              'p': budget.projectedPct.toStringAsFixed(1),
              'limit': budget.limitPct,
            }),
            style: TextStyle(color: t.faint, fontSize: t.fsSmall),
          ),
          Text(
            Strings.format('budget_line', {
              'free': hoursText(budget.free),
              'planned': budget.planned.toInt(),
              'buffer': hoursText(budget.buffer),
            }),
            style: TextStyle(color: t.muted, fontSize: t.fsSmall),
          ),
        ],
      ),
    );
  }

  Widget _meterRow(SubjectAbsence subject) {
    final c = controller;
    final t = tokens;
    const badgeLabels = {
      'ok': 'state_ok',
      'warning': 'state_warning',
      'critical': 'state_critical',
    };
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          subject.name,
          style: TextStyle(
            color: t.text,
            fontSize: t.fsBody,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          c.detail(subject),
          style: TextStyle(color: t.muted, fontSize: t.fsSmall),
        ),
      ],
    );
    final gauge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        w.Meter(valuePct: subject.currentPct, tok: t, kind: subject.status),
        const SizedBox(width: 8),
        // Fixed slot for the badge, so a shorter label doesn't shift
        // the meter sideways.
        SizedBox(
          width: t.fsTiny * 8,
          child: Align(
            alignment: Alignment.centerRight,
            child: w.Badge(
              text: Strings.get(badgeLabels[subject.status] ?? 'state_ok'),
              tok: t,
              kind: subject.status,
            ),
          ),
        ),
      ],
    );
    final body = narrow
        // Phone: the meter goes under the name, which needs the width.
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [info, const SizedBox(height: 8), gauge],
          )
        : Row(children: [Expanded(child: info), gauge]);
    return _card(body);
  }

  Widget _card(Widget child) {
    final t = tokens;
    return Card(
      color: t.card,
      // `components.card`: a 1 px outline in the border colour.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(color: t.border),
      ),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }
}
