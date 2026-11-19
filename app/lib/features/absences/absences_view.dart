import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../tutorial/tutorial_ui.dart';
import '../../widgets/app_widgets.dart' as w;
import '../common/app_tokens.dart';
import '../planner/plan_reserve.dart' show hoursText;
import '../planner/planner_view.dart'
    show BudgetRowData, TermPlanData, YearPlanData, plannerBudgetBar;
import 'absences_controller.dart';

/// Short, focused Absences (Absence) screen (O3).
///
/// Shows the header with *Limity* and *Plánovač* buttons, optional no-limits
/// banner, 3 KPI cards, optional 1-line next-recommended-day shortcut, and the
/// unified subject + stacked hour-budget list for the active term.
class AbsencesView extends StatelessWidget {
  final AbsencesController controller;
  final AppTokens tokens;
  final bool narrow;
  final YearPlanData? plan;
  final TermPlanData? term;
  final bool hasTimetable;
  final VoidCallback? onOpenLimits;
  final VoidCallback? onOpenPlanner;

  const AbsencesView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
    this.plan,
    this.term,
    this.hasTimetable = true,
    this.onOpenLimits,
    this.onOpenPlanner,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context),
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

  Widget _body(BuildContext context) {
    final c = controller;
    final t = tokens;
    final activeTerm = term ?? plan?.defaultTerm;

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
      if (onOpenPlanner != null)
        FilledButton.icon(
          key: const Key('abs:planner_btn'),
          style: compactStyle,
          onPressed: onOpenPlanner,
          icon: Icon(Icons.event_available_outlined, size: narrow ? 16 : 18),
          label: Text(
            Strings.get('abs_planner_btn'),
            style: compactTextStyle,
            textAlign: narrow ? TextAlign.center : null,
            maxLines: narrow ? 2 : null,
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
        Row(
          spacing: t.gap / 2,
          children: [for (final a in actions) Expanded(child: a)],
        ),
      );
    }
    if (noLimits != null) blocks.add(noLimits);

    // Case 1: no subjects.
    if (c.subjects.isEmpty) {
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

    // Case 2 & 3: subjects present.
    blocks.add(_threeCardStats());
    if (activeTerm != null &&
        activeTerm.recommended.isNotEmpty &&
        onOpenPlanner != null) {
      final next = activeTerm.recommended.first.day;
      blocks.add(
        Card(
          key: const Key('abs:next_plan_row'),
          color: t.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusMd),
            side: BorderSide(color: t.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpenPlanner,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: t.pad, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.beach_access_outlined, color: t.green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      Strings.format('planner_next', {
                        'day': '${w.dayName(next, true)} ${w.czDay(next)}',
                      }),
                      style: TextStyle(
                        color: t.text,
                        fontSize: t.fsSmall,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: t.muted, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
    }
    blocks.add(_subjectsSection(activeTerm));
    if (activeTerm == null && !hasTimetable) {
      blocks.add(
        Text(
          Strings.get('planner_need_refresh'),
          style: TextStyle(color: t.faint, fontSize: t.fsSmall),
        ),
      );
    }
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

  Widget _subjectsSection(TermPlanData? term) {
    final t = tokens;
    final hasBudgets = term != null && term.budgets.isNotEmpty;
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(color: t.border),
      ),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }
}
