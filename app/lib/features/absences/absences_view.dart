import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../tutorial/tutorial_ui.dart';
import '../../widgets/app_widgets.dart' as w;
import '../common/app_tokens.dart';
import '../settings/settings_view.dart' show LimitsEditorContent;
import 'absences_controller.dart';

/// Absences (Absence) screen — port of `views/absences.py`.
///
/// Per-subject meters against their own limits: a stats row (average,
/// warning count, critical count) plus one card per subject with a
/// meter and a status badge. On narrow screens the meter goes under
/// the name; on wide screens it sits beside it. Stateless; state lives
/// in [AbsencesController] via [ListenableBuilder].
class AbsencesView extends StatelessWidget {
  final AbsencesController controller;
  final AppTokens tokens;
  final bool narrow;

  const AbsencesView({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context),
    );
  }

  Future<void> _openLimitsDialog(BuildContext context) async {
    final builder = controller.createLimitsController;
    if (builder == null) return;
    final limitsCtrl = builder();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Strings.get('sec_limits')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: LimitsEditorContent(controller: limitsCtrl),
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('abs:limits_done'),
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.of(ctx).pop();
            },
            child: Text(Strings.get('close')),
          ),
        ],
      ),
    );
    controller.onLimitsUpdated?.call();
  }

  Widget? _noLimitsBanner(BuildContext context) {
    final c = controller;
    if (c.hasSubjectLimits || c.createLimitsController == null) return null;
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
              child: Text(Strings.get('abs_no_limits'),
                  style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('abs:no_limits_btn'),
              onPressed: () => _openLimitsDialog(context),
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
    final header = w.HeaderRow(
      heading: Strings.get('absence_title'),
      updated: c.updatedLabel,
      tok: t,
      actions: [
        if (c.createLimitsController != null)
          OutlinedButton.icon(
            key: const Key('abs:limits_btn'),
            onPressed: () => _openLimitsDialog(context),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(Strings.get('abs_limits_btn')),
          ),
      ],
    );
    final noLimits = _noLimitsBanner(context);
    if (c.subjects.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          header,
          if (noLimits != null) ...[
            SizedBox(height: t.gap),
            noLimits,
          ],
          SizedBox(height: t.gap),
          w.EmptyState(text: Strings.get('no_data'), tok: t),
          if (c.demoMode)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(Strings.get('need_credentials'),
                  style: TextStyle(
                      color: t.faint, fontSize: t.fsSmall)),
            ),
        ],
      );
    }
    final stats = TutorialAnchor(
      anchorKey: 'abs_stats',
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: t.gap,
          children: [
            w.StatCard(
                label: Strings.get('avg_absence'),
                value: '${c.average.toStringAsFixed(1)} %',
                tok: t),
            w.StatCard(
                label: Strings.get('warn_subjects'),
                value: '${c.warnCount}',
                tok: t,
                kind: c.warnCount > 0 ? 'warning' : 'ok'),
            w.StatCard(
                label: Strings.get('crit_subjects'),
                value: '${c.critCount}',
                tok: t,
                kind: c.critCount > 0 ? 'critical' : 'ok'),
          ],
        ),
      ),
    );
    final rows = [
      for (var i = 0; i < c.subjects.length; i++)
        if (i == 0)
          TutorialAnchor(
            anchorKey: 'abs_first',
            child: _row(c.subjects[i]),
          )
        else
          _row(c.subjects[i]),
    ];
    if (narrow) {
      // Phone: header and stats scroll away with the list (landscape).
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          header,
          if (noLimits != null) ...[
            SizedBox(height: (t.gap ~/ 2) + 2.0),
            noLimits,
          ],
          SizedBox(height: (t.gap ~/ 2) + 2.0),
          stats,
          // `absences.py`: every block and row `tok.gap // 2 + 2` apart.
          for (final row in rows) ...[
            SizedBox(height: (t.gap ~/ 2) + 2.0),
            row,
          ],
          const SizedBox(height: 24),
        ],
      );
    }
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (noLimits != null) ...[
            SizedBox(height: t.gap),
            noLimits,
          ],
          SizedBox(height: t.gap),
          stats,
          SizedBox(height: t.gap),
          Expanded(
            child: ListView(
              children: [
                // `absences.py`: rows `tok.gap // 2` apart.
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) SizedBox(height: (t.gap ~/ 2).toDouble()),
                  rows[i],
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(SubjectAbsence subject) {
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
        Text(subject.name,
            style: TextStyle(
                color: t.text,
                fontSize: t.fsBody,
                fontWeight: FontWeight.bold)),
        Text(c.detail(subject),
            style: TextStyle(
                color: t.muted, fontSize: t.fsSmall)),
      ],
    );
    final gauge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        w.Meter(
            valuePct: subject.currentPct, tok: t, kind: subject.status),
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
                kind: subject.status),
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
        : Row(
            children: [Expanded(child: info), gauge],
          );
    return _card(body);
  }

  Widget _card(Widget child) {
    final t = tokens;
    return Card(
      color: t.card,
      // `components.card`: a 1 px outline in the border colour.
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd),
          side: BorderSide(color: t.border)),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }
}
