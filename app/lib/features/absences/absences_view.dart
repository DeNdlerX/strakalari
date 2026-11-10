import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../tutorial/tutorial_ui.dart';
import '../common/app_tokens.dart';
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
      builder: (context, _) => _body(),
    );
  }

  Widget _body() {
    final c = controller;
    final t = tokens;
final header = Row(
      children: [
        Expanded(
            child: Text(Strings.get('absence_title'),
                style: TextStyle(
                    color: t.text,
                    fontSize: 20,
                    fontWeight: FontWeight.bold))),
      ],
    );
    if (c.subjects.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          header,
          SizedBox(height: t.gap),
          _card(Text(Strings.get('no_data'),
              style:
                  TextStyle(color: t.faint, fontSize: t.fsBody))),
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
      child: Row(
        spacing: t.gap,
        children: [
          Expanded(
              child: _statCard(Strings.get('avg_absence'),
                  '${c.average.toStringAsFixed(1)} %', 'ok')),
          Expanded(
              child: _statCard(Strings.get('warn_subjects'),
                  '${c.warnCount}', c.warnCount > 0 ? 'warning' : 'ok')),
          Expanded(
              child: _statCard(Strings.get('crit_subjects'),
                  '${c.critCount}', c.critCount > 0 ? 'critical' : 'ok')),
        ],
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
        padding: const EdgeInsets.all(16),
        children: [
          header,
          SizedBox(height: t.gap / 2 + 2),
          stats,
          SizedBox(height: t.gap / 2 + 2),
          ...rows,
          const SizedBox(height: 24),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          SizedBox(height: t.gap),
          stats,
          SizedBox(height: t.gap),
          Expanded(
            child: ListView(
              children: [
                ...rows,
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, String kind) {
    final t = tokens;
    final color = statusColor(kind, t);
    return Card(
      color: t.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: t.muted, fontSize: t.fsSmall)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: kind == 'ok' ? t.text : color,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
          ],
        ),
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
        _meter(subject.currentPct, subject.status),
        const SizedBox(width: 8),
        // Fixed slot for the badge, so a shorter label doesn't shift
        // the meter sideways.
        SizedBox(
          width: t.fsTiny * 8,
          child: Align(
            alignment: Alignment.centerRight,
            child: _badge(
                Strings.get(badgeLabels[subject.status] ?? 'state_ok'),
                subject.status),
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

  Widget _meter(double pct, String status) {
    final t = tokens;
    final color = statusColor(status, t);
    final ratio = (pct / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: 120,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: ratio,
          minHeight: 8,
          backgroundColor: t.overlay,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }

  Widget _badge(String label, String kind) {
    final t = tokens;
    final color = statusColor(kind, t);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tintColor(color, 0.12),
        borderRadius: BorderRadius.circular(t.radiusSm),
        border: Border.all(color: tintColor(color, 0.45)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontSize: t.fsSmall,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _card(Widget child) {
    final t = tokens;
    return Card(
      color: t.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusMd)),
      child: Padding(padding: EdgeInsets.all(t.pad), child: child),
    );
  }
}
