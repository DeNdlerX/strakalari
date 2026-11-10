import '../../l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../tutorial/tutorial_ui.dart';
import '../common/app_tokens.dart';
import '../common/format.dart' hide parseCzDate;
import 'package:strakalari_core/strakalari_core.dart';
import 'marks_controller.dart';

/// Marks (Známky) screen — port of `views/marks.py`.
///
/// Left: one card per subject (average, estimated final grade, trend,
/// newest marks). Right: an overview (latest and planned marks, the
/// percent → grade bands) or, once a subject is picked, its detail:
/// every mark with topic and weight, the running-average trend, a
/// "what do I need" solver and the predictor. Scales (1–5 vs percent)
/// are autodetected per subject and can be switched globally or per
/// subject. Stateless; state lives in [MarksController] via
/// [ListenableBuilder].
class MarksView extends StatelessWidget {
  final MarksController controller;
  final AppTokens tokens;
  final bool narrow;

  static const double panelWidth = 380;
  static const int maxChips = 14;

  const MarksView({
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

  Widget _body(BuildContext context) {
    final c = controller;
    final t = tokens;
final hasGrades = c.grades.isNotEmpty;
    if (!hasGrades) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _headerRow(context, false),
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
    final bands = c.marksBands();
    final items = c.summaries();
    final selected = c.selected();
    if (narrow) {
      // Phone: a picked subject replaces the list (its close button
      // returns to it) instead of a side panel.
      final blocks = <Widget>[_headerRow(context, true)];
      if (selected != null) {
        blocks.addAll(_detail(context, selected, bands));
      } else {
        blocks.add(_scaleToggle());
        blocks.add(_stats(items, bands));
        final banner = _predictionBanner(context);
        if (banner != null) blocks.add(banner);
        blocks.add(Wrap(
          spacing: t.gap,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(Strings.format('marks_subjects_n', {'n': items.length}),
                style: TextStyle(
                    color: t.text,
                    fontSize: t.fsSmall,
                    fontWeight: FontWeight.bold)),
            _sortToggle(),
          ],
        ));
        final sortedItems = c.sorted(items, c.marksSort(), bands);
        final cards = [
          for (var i = 0; i < sortedItems.length; i++)
            if (i == 0)
              TutorialAnchor(
                anchorKey: 'marks_subject',
                child: _subjectCard(context, sortedItems[i], bands),
              )
            else
              _subjectCard(context, sortedItems[i], bands),
        ];
        blocks.addAll(cards);
        blocks.addAll(_overview(context, items, bands));
      }
      blocks.add(const SizedBox(height: 24));
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            blocks[i],
            if (i != blocks.length - 1)
              SizedBox(height: t.gap / 2 + 2),
          ],
        ],
      );
    }
    final sortedItems = c.sorted(items, c.marksSort(), bands);
    final cards = [
      for (var i = 0; i < sortedItems.length; i++)
        if (i == 0)
          TutorialAnchor(
            anchorKey: 'marks_subject',
            child: _subjectCard(context, sortedItems[i], bands),
          )
        else
          _subjectCard(context, sortedItems[i], bands),
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headerRow(context, true),
          SizedBox(height: t.gap),
          _stats(items, bands),
          if (_predictionBanner(context) != null) ...[
            SizedBox(height: t.gap / 2),
            _predictionBanner(context)!,
          ],
          SizedBox(height: t.gap / 2),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                              Strings.format('marks_subjects_n',
                                  {'n': items.length}),
                              style: TextStyle(
                                  color: t.text,
                                  fontSize: t.fsSmall,
                                  fontWeight: FontWeight.bold)),
                          _sortToggle(),
                        ],
                      ),
                      SizedBox(height: t.gap / 2),
                      Expanded(
                        child: ListView(
                          children: [
                            ...cards,
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: t.gap),
                SizedBox(
                  width: panelWidth,
                  child: ListView(
                    children: [
                      ...(selected != null
                          ? _detail(context, selected, bands)
                          : _overview(context, items, bands)),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -- header ------------------------------------------------------------------

  Widget _headerRow(BuildContext context, bool hasGrades) {
    final t = tokens;
return Row(
      children: [
        Expanded(
            child: Text(Strings.get('marks_title'),
                style: TextStyle(
                    color: t.text,
                    fontSize: 20,
                    fontWeight: FontWeight.bold))),
        if (hasGrades && !narrow) _scaleToggle(),
      ],
    );
  }

  Widget _scaleToggle() {
    final c = controller;
    return TutorialAnchor(
      anchorKey: 'marks_scale',
      child: SegmentedButton<String>(
        segments: [
          ButtonSegment(
              value: 'auto', label: Text(Strings.get('marks_scale_auto'))),
          ButtonSegment(
              value: 'grade',
              label: Text(Strings.get('marks_scale_grade'))),
          ButtonSegment(
              value: 'percent',
              label: Text(Strings.get('marks_scale_percent'))),
        ],
        selected: {c.marksScale()},
        onSelectionChanged: (sel) =>
            c.setMarksScale(sel.first),
        showSelectedIcon: false,
      ),
    );
  }

  Widget _sortToggle() {
    final c = controller;
return SegmentedButton<String>(
      segments: [
        ButtonSegment(
            value: 'name', label: Text(Strings.get('marks_sort_name'))),
        ButtonSegment(
            value: 'average',
            label: Text(Strings.get('marks_sort_average'))),
        ButtonSegment(
            value: 'recent',
            label: Text(Strings.get('marks_sort_recent'))),
      ],
      selected: {c.marksSort()},
      onSelectionChanged: (sel) =>
          c.setMarksSort(sel.first),
      showSelectedIcon: false,
    );
  }

  Widget _stats(List<SubjectSummary> items, List<double> bands) {
    final c = controller;
final predicting = items.any((x) => x.predicting);
    final (avg, avgScale) = c.overall(items, bands);
    final report = c.reportEstimate(items, bands);
    final nMarks =
        items.map((x) => x.realCount).fold(0, (a, b) => a + b);
    final nNew = items.map((x) => x.newCount).fold(0, (a, b) => a + b);
    final suffix = predicting
        ? ' · ${Strings.get('marks_predicted_short')}'
        : '';
    return TutorialAnchor(
      anchorKey: 'marks_stats',
      child: Wrap(
        spacing: tokens.gap,
        runSpacing: 8,
        children: [
          _statCard('${Strings.get('marks_average')}$suffix',
              formatValue(avg, avgScale), kindFor(avg, avgScale, bands)),
          _statCard('${Strings.get('marks_report')}$suffix',
              report == null ? '—' : report.toStringAsFixed(2),
              kindFor(report, 'grade', bands)),
          _statCard(Strings.get('marks_total'), '$nMarks', 'info'),
          _statCard(Strings.get('marks_new'), '$nNew',
              nNew > 0 ? 'ok' : 'info'),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, String kind) {
    final t = tokens;
    final color =
        kind == 'info' ? t.text : statusColor(kind, t);
    return SizedBox(
      width: 150,
      child: Card(
        color: t.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radiusMd)),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: t.muted, fontSize: t.fsSmall)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _predictionBanner(BuildContext context) {
    final c = controller;
    final t = tokens;
final changed = [
      for (final x in c.summaries())
        if (x.predicting) x
    ];
    if (changed.isEmpty) return null;
    return Card(
      color: tintColor(t.accent, 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(color: tintColor(t.accent, 0.5)),
      ),
      child: Padding(
        padding:
            EdgeInsets.symmetric(horizontal: t.pad, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.science_outlined,
                color: t.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      Strings.format('marks_prediction_on',
                          {'n': changed.length}),
                      style: TextStyle(
                          color: t.text,
                          fontWeight: FontWeight.bold)),
                  Text(Strings.get('marks_prediction_hint'),
                      style: TextStyle(
                          color: t.muted,
                          fontSize: t.fsSmall)),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () => c.predictReset(),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(Strings.get('marks_reset_all')),
            ),
          ],
        ),
      ),
    );
  }

  // -- subject list ---------------------------------------------------------------

  Widget _subjectCard(BuildContext context, SubjectSummary summary,
      List<double> bands) {
    final c = controller;
    final t = tokens;
final selected = c.selectedSubject == summary.name;
    final avgKind = kindFor(summary.current, summary.scale, bands);

    final subParts = [
      Strings.format('marks_count', {'n': summary.realCount})
    ];
    if (summary.lastDate != null) {
      subParts.add(Strings.format(
          'marks_last', {'day': czDay(summary.lastDate)}));
    }
    if (summary.forced) {
      subParts.add(summary.scale == 'grade'
          ? Strings.get('marks_scale_grade')
          : '%');
    }
    final quarterly = _quarterlyBadge(summary);
    final titleRow = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(summary.name,
            style: TextStyle(
                color: t.text,
                fontWeight: FontWeight.bold,
                fontSize: t.fsBody)),
        ?quarterly,
        if (summary.newCount > 0)
          _badge(
              Strings.format('marks_new_badge', {'n': summary.newCount}),
              'ok'),
      ],
    );
    final titleCol = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleRow,
          Text(subParts.join(' · '),
              style:
                  TextStyle(color: t.faint, fontSize: t.fsSmall)),
        ],
      ),
    );

    final right = <Widget>[];
    final up = c.improving(summary);
    if (up != null) {
      right.add(Icon(
          up ? Icons.trending_up : Icons.trending_down,
          size: 18,
          color: up ? t.green : t.red));
    }
    if (summary.predicting && summary.average != null) {
      right.add(Text(formatValue(summary.average, summary.scale),
          style:
              TextStyle(color: t.faint, fontSize: t.fsSmall)));
      right.add(Icon(Icons.arrow_forward,
          size: 14, color: t.faint));
    }
    right.add(_badge(
        formatValue(summary.current, summary.scale), avgKind));
    right.add(Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: avgKind != 'info'
            ? tintColor(statusColor(avgKind, t), 0.14)
            : t.overlay,
      ),
      child: Text(c.finalText(summary, bands),
          style: TextStyle(
              fontSize: t.fsSection,
              fontWeight: FontWeight.bold,
              color: avgKind != 'info'
                  ? statusColor(avgKind, t)
                  : t.muted)),
    ));

    final hasPct = c.subjectHasPct(summary);
    final shown = [
      for (final r in summary.rows)
        if (r.state != 'removed') r
    ];
    final chips = <Widget>[];
    if (shown.length > maxChips) {
      chips.add(Text('+${shown.length - maxChips}',
          style:
              TextStyle(color: t.faint, fontSize: t.fsSmall)));
    }
    chips.addAll([
      for (final r in shown.skip(
          shown.length > maxChips ? shown.length - maxChips : 0))
        _chip(
            c.markLabel(r.mark, r.raw, summary.scale, hasPct),
            c.rowKind(summary, r, bands),
            c.rowKind(summary, r, bands) == 'info'
                ? null
                : _markTooltip(r),
            hypothetical:
                r.state == 'added' || r.state == 'edited'),
    ]);
    if (summary.planned.isNotEmpty) {
      chips.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event_outlined, size: 13, color: t.accent),
          const SizedBox(width: 3),
          Text(
              Strings.format('marks_planned_count',
                  {'n': summary.planned.length}),
              style:
                  TextStyle(color: t.accent, fontSize: t.fsTiny)),
        ],
      ));
    }

    return Card(
      color:
          selected ? tintColor(t.accent, 0.08) : t.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusMd),
        side: BorderSide(
            color: selected ? t.accent : t.border,
            width: selected ? 2 : 1),
      ),
      child: InkWell(
        onTap: () => c.selectSubject(summary.name),
        borderRadius: BorderRadius.circular(t.radiusMd),
        child: Padding(
          padding: EdgeInsets.all(t.pad - (selected ? 1 : 0)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [titleCol, ...right]),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: chips),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget? _quarterlyBadge(SubjectSummary summary) {
    final c = controller;
final entry = c.quarterlyMarks[summary.name];
    if (entry == null) return null;
    final grade = '${entry['Grade'] ?? ''}'.trim();
    if (grade.isEmpty) return null;
    final raw = parseRaw(grade);
    final kind = raw != null && raw.kind != 'percent'
        ? kindFor(raw.value, 'grade')
        : 'info';
    final note = '${entry['Note'] ?? ''}'.trim();
    return Tooltip(
      message:
          '${Strings.get('marks_quarterly_tooltip')}${note.isNotEmpty ? '\n$note' : ''}',
      child: _badge(
          Strings.format('marks_quarterly', {'mark': grade}), kind),
    );
  }

  String _markTooltip(MarkRow row) {
final mark = row.mark;
    final parts = [
      '${mark['Caption'] ?? ''}'.trim(),
      '${Strings.get('marks_weight')} ${formatWeight(row.weight)}',
      if ('${mark['Date'] ?? ''}'.isNotEmpty)
        czDayYear(mark['Date']),
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  Widget _chip(String text, String kind, String? tooltip,
      {bool hypothetical = false, bool faded = false}) {
    final t = tokens;
    final color =
        kind == 'info' ? t.muted : statusColor(kind, t);
    return Tooltip(
      message: tooltip ?? '',
      child: Opacity(
        opacity: faded ? 0.4 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: tintColor(
                hypothetical ? t.accent : color, 0.10),
            border: Border.all(
                color: tintColor(
                    hypothetical ? t.accent : color, 0.45)),
            borderRadius: BorderRadius.circular(t.radiusSm),
          ),
          child: Text(text,
              style: TextStyle(
                  color: color,
                  fontSize: t.fsSmall,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _badge(String text, String kind) {
    return _chip(text, kind, null);
  }

  // -- right panel: overview ----------------------------------------------------------

  List<Widget> _overview(BuildContext context,
      List<SubjectSummary> items, List<double> bands) {
final out = <Widget>[
      Row(
        children: [
          Icon(Icons.touch_app_outlined,
              size: 18, color: tokens.faint),
          const SizedBox(width: 8),
          Expanded(
              child: Text(Strings.get('marks_pick_hint'),
                  style: TextStyle(
                      color: tokens.muted,
                      fontSize: tokens.fsSmall))),
        ],
      ),
      _recentMarks(context, items, bands),
    ];
    final planned = _plannedMarks(context, items);
    if (planned != null) out.add(planned);
    out.add(_bandsCard(context));
    return out;
  }

  Widget _recentMarks(BuildContext context,
      List<SubjectSummary> items, List<double> bands) {
    final c = controller;
    final t = tokens;
final entries = <(DateTime, SubjectSummary, MarkRow)>[];
    for (final summary in items) {
      for (final r in summary.rows) {
        if ((r.state == 'real' ||
                r.state == 'edited' ||
                r.state == 'removed') &&
            r.date != null) {
          entries.add((r.date!, summary, r));
        }
      }
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    final rows = <Widget>[];
    for (final (day, summary, r) in entries.take(8)) {
      final source =
          r.state == 'edited' && r.original != null
              ? r.original!
              : r.mark;
      final raw = parseRaw(
          source['Grade'], source['Points']);
      final hasPct = c.subjectHasPct(summary);
      final value = resolve(
          raw, summary.scale, hasPct, bands);
      final caption = '${source['Caption'] ?? ''}'.trim();
      rows.add(InkWell(
        onTap: () => c.selectSubject(summary.name),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: _chip(
                    c.markLabel(source, raw, summary.scale, hasPct),
                    kindFor(value, summary.scale, bands),
                    null),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(summary.name,
                        style: TextStyle(
                            color: t.text,
                            fontSize: t.fsSmall,
                            fontWeight: FontWeight.bold)),
                    Text(
                        [
                          caption,
                          czDay(day),
                          '${Strings.get('marks_weight')} ${formatWeight(r.weight)}'
                        ].where((p) => p.isNotEmpty).join(' · '),
                        style: TextStyle(
                            color: t.faint,
                            fontSize: t.fsTiny)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    }
    if (rows.isEmpty) {
      rows.add(Text(Strings.get('marks_no_recent'),
          style: TextStyle(
              color: t.muted, fontSize: t.fsSmall)));
    }
    return _section(Strings.get('marks_recent'), rows,
        icon: Icons.history);
  }

  Widget? _plannedMarks(
      BuildContext context, List<SubjectSummary> items) {
    final c = controller;
    final t = tokens;
final entries = <(DateTime?, SubjectSummary, Map<String, Object?>)>[];
    for (final summary in items) {
      for (final m in summary.planned) {
        entries.add((_plannedDate(m), summary, m));
      }
    }
    if (entries.isEmpty) return null;
    entries.sort((a, b) {
      final da = a.$1 ?? DateTime(9999);
      final db = b.$1 ?? DateTime(9999);
      return da.compareTo(db);
    });
    return _section(
        Strings.get('marks_planned'),
        [
          for (final (day, summary, m) in entries)
            InkWell(
              onTap: () => c.selectSubject(summary.name),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 52,
                      child: Text(
                          day == null ? '?' : czDay(day),
                          style: TextStyle(
                              color: t.accent,
                              fontSize: t.fsSmall,
                              fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(summary.name,
                              style: TextStyle(
                                  color: t.text,
                                  fontSize: t.fsSmall,
                                  fontWeight: FontWeight.bold)),
                          Text(
                              '${'${m['Caption'] ?? ''}'.trim().isEmpty ? Strings.get('marks_planned_test') : '${m['Caption'] ?? ''}'.trim()} · ${Strings.get('marks_weight')} ${formatWeight(parseWeight(m['Weight']))}',
                              style: TextStyle(
                                  color: t.faint,
                                  fontSize: t.fsTiny)),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => c.usePlannedWeight(
                          summary.name,
                          formatWeight(
                              parseWeight(m['Weight']))),
                      child: Text(Strings.get('marks_use_weight'),
                          style: TextStyle(
                              color: t.accent,
                              fontSize: t.fsSmall)),
                    ),
                  ],
                ),
              ),
            ),
        ],
        icon: Icons.event_outlined);
  }

  DateTime? _plannedDate(Map<String, Object?> mark) =>
      parseCzDate(mark['TestDate'] ?? mark['Date']);

  Widget _bandsCard(BuildContext context) {
    final c = controller;
    final t = tokens;
final (bands, source) = c.marksBandsSource();
    final fields = <TextEditingController>[];
    final cells = <Widget>[];
    for (var i = 0; i < 4; i++) {
      final key = 'marks:band:${i + 1}';
      final field = TextEditingController(
          text: c.draft(key, gFormat(bands[i])));
      field.addListener(() =>
          c.setDraft(key, field.text));
      fields.add(field);
      cells.add(Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Strings.format('marks_band_label', {'grade': i + 2}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: t.muted, fontSize: t.fsTiny)),
            const SizedBox(height: 4),
            TextField(
              controller: field,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: t.surface,
                suffixText: '%',
              ),
            ),
          ],
        ),
      ));
    }

    void save() {
      List<double>? parsed;
      try {
        parsed = [
          for (final f in fields)
            double.parse(
                f.text.replaceAll(',', '.').trim())
        ];
      } catch (_) {
        parsed = null;
      }
      if (parsed != null && c.setMarksBands(parsed)) {
        c.clearDrafts('marks:band:');
        for (var i = 0; i < 4; i++) {
          fields[i].text = gFormat(c.marksBands()[i]);
        }
        _snack(context, Strings.get('marks_bands_saved'));
      } else {
        _snack(context, Strings.get('marks_bands_invalid'));
      }
    }

    void reset() {
      c.clearDrafts('marks:band:');
      c.setMarksBands(null);
    }

    final buttons = <Widget>[
      TextButton.icon(
          onPressed: save,
          icon: const Icon(Icons.check, size: 18),
          label: Text(Strings.get('marks_save'))),
    ];
    if (source == 'user') {
      buttons.add(TextButton(
          onPressed: reset,
          child: Text(
              c.presetBands != null
                  ? Strings.get('marks_bands_use_school')
                  : Strings.get('marks_bands_default'),
              style: TextStyle(color: t.muted))));
    }
    return _section(
        Strings.get('marks_bands'),
        [
          Row(
            children: [
              Icon(
                  source == 'preset'
                      ? Icons.school_outlined
                      : Icons.tune,
                  size: 14,
                  color: t.accent),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(c.bandsSourceText(source),
                      style: TextStyle(
                          color: t.accent,
                          fontSize: t.fsSmall))),
            ],
          ),
          Text(MarksController.bandsRanges(bands),
              style:
                  TextStyle(color: t.muted, fontSize: t.fsSmall)),
          Text(Strings.get('marks_bands_hint'),
              style:
                  TextStyle(color: t.muted, fontSize: t.fsSmall)),
          Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 4),
            child: Row(spacing: 8, children: cells),
          ),
          Wrap(spacing: 8, children: buttons),
        ],
        icon: Icons.percent);
  }

  Widget _section(String title, List<Widget> controls,
      {IconData? icon}) {
    final t = tokens;
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (icon != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(icon,
                    size: 16, color: t.faint),
              ),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: t.text,
                      fontSize: t.fsSection,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...controls,
      ],
    ));
  }

  // -- detail -------------------------------------------------------------------

  List<Widget> _detail(BuildContext context, SubjectSummary summary,
      List<double> bands) {
    final c = controller;
    final t = tokens;
final head = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary.name,
                  style: TextStyle(
                      color: t.text,
                      fontSize: t.fsSection,
                      fontWeight: FontWeight.bold)),
              Text(
                  Strings.format('marks_count',
                      {'n': summary.realCount}),
                  style: TextStyle(
                      color: t.faint, fontSize: t.fsSmall)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          tooltip: Strings.get('close'),
          onPressed: () => c.selectSubject(null),
        ),
      ],
    );
    final top = <Widget>[
      head,
      _scalePicker(summary),
      _detailStats(summary, bands)
    ];
    final chart = _trendChart(summary, bands);
    if (chart != null) top.add(chart);
    final out = <Widget>[
      _card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < top.length; i++) ...[
              top[i],
              if (i != top.length - 1)
                const SizedBox(height: 8),
            ],
          ])),
      TutorialAnchor(
        anchorKey: 'marks_need',
        child: _neededCard(context, summary, bands),
      ),
    ];

    final rows = [
      for (final r in summary.rows)
        if (r.state != 'added') r
    ].reversed.toList();
    final added = [
      for (final r in summary.rows)
        if (r.state == 'added') r
    ];
    final markControls = <Widget>[
      for (final r in [...added, ...rows])
        _markRow(context, summary, r, bands),
    ];
    if (markControls.isEmpty) {
      markControls.add(Text(Strings.get('marks_none_yet'),
          style: TextStyle(
              color: t.muted, fontSize: t.fsSmall)));
    }
    out.add(TutorialAnchor(
      anchorKey: 'marks_predict',
      child: _card(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined,
                  size: 16, color: t.faint),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(Strings.get('marks_predictor'),
                      style: TextStyle(
                          color: t.text,
                          fontSize: t.fsSection,
                          fontWeight: FontWeight.bold))),
              if (summary.predicting)
                TextButton(
                    onPressed: () =>
                        c.predictReset(summary.name),
                    child: Text(Strings.get('marks_reset'),
                        style: TextStyle(
                            color: t.accent,
                            fontSize: t.fsSmall))),
            ],
          ),
          Text(Strings.get('marks_predictor_hint'),
              style: TextStyle(
                  color: t.muted, fontSize: t.fsSmall)),
          const SizedBox(height: 8),
          _addForm(context, summary),
          const Divider(height: 16),
          ...markControls,
        ],
      )),
    ));
    final planned = _detailPlanned(summary);
    if (planned.isNotEmpty) {
      out.add(_section(Strings.get('marks_planned'), planned,
          icon: Icons.event_outlined));
    }
    return out;
  }

  Widget _scalePicker(SubjectSummary summary) {
    final c = controller;
    final t = tokens;
final current =
        c.marksSubjectScales()[summary.name] ?? 'auto';
    String name(String scale) => scale == 'grade'
        ? Strings.get('marks_scale_grade')
        : Strings.get('marks_scale_percent');
    final String hint;
    if (current == 'auto' && summary.forced) {
      hint = Strings.format('marks_scale_global',
          {'scale': name(summary.scale)});
    } else {
      hint = Strings.format('marks_detected',
          {'scale': name(summary.detected)});
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
                value: 'auto',
                label: Text(Strings.get('marks_scale_auto'))),
            ButtonSegment(
                value: 'grade',
                label: Text(Strings.get('marks_scale_grade'))),
            ButtonSegment(
                value: 'percent',
                label: Text(Strings.get('marks_scale_percent'))),
          ],
          selected: {current},
          onSelectionChanged: (sel) =>
              c.setSubjectScale(summary.name, sel.first),
          showSelectedIcon: false,
        ),
        Text(hint,
            style: TextStyle(
                color: t.faint, fontSize: t.fsTiny)),
      ],
    );
  }

  Widget _detailStats(SubjectSummary summary, List<double> bands) {
    final t = tokens;
Widget tile(String label, String value, String kind) {
      final color =
          kind == 'info' ? t.text : statusColor(kind, t);
      return Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(t.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: t.muted, fontSize: t.fsTiny)),
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: t.fsSection,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    }

    return Row(
      spacing: 6,
      children: [
        tile(
            Strings.get('marks_average'),
            formatValue(summary.average, summary.scale),
            kindFor(summary.average, summary.scale, bands)),
        if (summary.predicting)
          tile(
              Strings.get('marks_predicted'),
              formatValue(
                  summary.predicted, summary.scale),
              kindFor(summary.predicted, summary.scale, bands)),
        tile(
            Strings.get('marks_final'),
            controller.finalText(summary, bands),
            kindFor(summary.current, summary.scale, bands)),
      ],
    );
  }

  Widget? _trendChart(SubjectSummary summary, List<double> bands) {
    final t = tokens;
    final history = summary.history;
    if (history.length < 2) return null;
    final bars = <Widget>[];
    for (final (day, avg) in history.skip(
        history.length > 24 ? history.length - 24 : 0)) {
      final double ratio;
      if (summary.scale == 'percent') {
        ratio = avg / 100.0;
      } else {
        ratio = (5.0 - avg) / 4.0;
      }
      final clamped = ratio.clamp(0.06, 1.0);
      final color = statusColor(
          kindFor(avg, summary.scale, bands), t);
      bars.add(Expanded(
        child: Tooltip(
          message:
              '${day == null ? '?' : czDay(day)} · ${formatValue(avg, summary.scale)}',
          child: SizedBox(
            height: 64,
            child: Column(
              children: [
                const Spacer(),
                Container(
                  height: roundHalfEven(64 * clamped).toDouble(),
                  decoration: BoxDecoration(
                      color: color,
                      borderRadius:
                          BorderRadius.circular(3)),
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(Strings.get('marks_trend'),
            style: TextStyle(
                color: t.muted, fontSize: t.fsSmall)),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(t.radiusSm),
          ),
          padding: const EdgeInsets.all(6),
          child: Row(
              spacing: 3,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: bars),
        ),
      ],
    );
  }

  Widget _neededCard(BuildContext context, SubjectSummary summary,
      List<double> bands) {
    final c = controller;
    final t = tokens;
final target = c.needTarget(summary, bands);
    final fallbackWeight = defaultWeight(summary);
    final weightText =
        c.marksCalc(summary.name)['weight'] ??
            formatWeight(fallbackWeight);
    final weight = double.tryParse(
            weightText.replaceAll(',', '.').trim()) ??
        fallbackWeight;
    final w = weight > 0 ? weight : fallbackWeight;

    final need = neededFor(summary.rows, summary.scale, target, w, bands);
    final String msg;
    String kind;
    if (need.status == 'any') {
      msg = Strings.format('marks_need_any', {'grade': target});
      kind = 'ok';
    } else if (need.status == 'need') {
      final mark = summary.scale == 'percent'
          ? '${gFormat(need.value!)} %'
          : formatGradeStep(need.value!);
      final key = summary.scale == 'percent'
          ? 'marks_need_pct'
          : 'marks_need_grade';
      msg = Strings.format(key, {'mark': mark, 'grade': target});
      kind = 'warning';
      if ((summary.scale == 'grade' && need.value! >= 3) ||
          (summary.scale == 'percent' && need.value! <= bands[2])) {
        kind = 'ok';
      }
    } else if (need.count > 0) {
      final best =
          summary.scale == 'percent' ? '100 %' : '1';
      msg = Strings.format('marks_need_many', {
        'n': need.count,
        'mark': best,
        'weight': formatWeight(w),
        'grade': target,
      });
      kind = 'critical';
    } else {
      msg = Strings.format('marks_need_impossible', {'grade': target});
      kind = 'critical';
    }
    return _section(
        Strings.get('marks_need_title'),
        [
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: '$target',
                  decoration: InputDecoration(
                    labelText: Strings.get('marks_target'),
                    isDense: true,
                    filled: true,
                    fillColor: t.surface,
                  ),
                  items: [
                    for (final g in [1, 2, 3, 4])
                      DropdownMenuItem(
                          value: '$g',
                          child: Text(Strings.format(
                              'marks_target_option',
                              {'grade': g}))),
                  ],
                  onChanged: (v) => c.setMarksCalc(
                      summary.name,
                      target: v ?? '$target'),
                ),
              ),
              SizedBox(
                width: 90,
                child: TextFormField(
                  key: ValueKey(
                      'need-weight:${summary.name}:$weightText'),
                  initialValue: weightText,
                  decoration: InputDecoration(
                    labelText: Strings.get('marks_weight'),
                    isDense: true,
                    filled: true,
                    fillColor: t.surface,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(
                          decimal: true),
                  onFieldSubmitted: (v) =>
                      c.setMarksCalc(summary.name, weight: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: tintColor(statusColor(kind, t), 0.10),
              borderRadius: BorderRadius.circular(t.radiusSm),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 8),
            child: Text(msg,
                style: TextStyle(
                    color: statusColor(kind, t),
                    fontSize: t.fsSmall)),
          ),
        ],
        icon: Icons.flag_outlined);
  }

  Widget _markRow(BuildContext context, SubjectSummary summary,
      MarkRow row, List<double> bands) {
    final c = controller;
    final t = tokens;
if (c.editingKey == row.key) {
      return _editRow(context, summary, row);
    }
    final mark = row.mark;
    final hasPct = c.subjectHasPct(summary);
    final caption = '${mark['Caption'] ?? ''}'.trim();
    final note = '${mark['Note'] ?? ''}'.trim();

    final title = caption.isNotEmpty
        ? caption
        : (row.state == 'added'
            ? Strings.get('marks_hypothetical')
            : Strings.get('marks_no_topic'));
    final details = <String>[];
    if (row.state != 'added') {
      details.add(czDayYear(mark['Date']));
      if ('${mark['TestDate'] ?? ''}'.isNotEmpty) {
        details.add(Strings.format('marks_written',
            {'day': czDayYear(mark['TestDate'])}));
      }
    }
    details.add(
        '${Strings.get('marks_weight')} ${formatWeight(row.weight)}');
    if (row.raw != null && row.value != null) {
      final native = (row.raw!.kind == 'percent' ||
              (row.raw!.kind == 'small' &&
                  summary.scale == 'percent' &&
                  hasPct))
          ? 'percent'
          : 'grade';
      if (native != summary.scale) {
        details.add('≈ ${formatValue(row.value, summary.scale)}');
      }
    } else if (row.state != 'removed') {
      details.add(Strings.get('marks_not_counted'));
    }
    if (row.state == 'edited' && row.original != null) {
      final orig = row.original!;
      details.add(Strings.format('marks_was', {
        'mark': c.markLabel(
            orig,
            parseRaw(orig['Grade'], orig['Points']),
            summary.scale,
            hasPct),
        'weight': formatWeight(parseWeight(orig['Weight'])),
      }));
    }

    final actions = <Widget>[];
    if (row.state == 'removed') {
      actions.add(IconButton(
          icon: const Icon(Icons.restore, size: 18),
          tooltip: Strings.get('restore'),
          onPressed: () =>
              c.predictRestore(summary.name, row.key)));
    } else {
      if (row.state == 'edited') {
        actions.add(IconButton(
            icon: const Icon(Icons.restore, size: 18),
            tooltip: Strings.get('marks_restore_real'),
            onPressed: () =>
                c.predictRestore(summary.name, row.key)));
      }
      actions.add(IconButton(
          icon: const Icon(Icons.edit_outlined, size: 18),
          tooltip: Strings.get('marks_edit'),
          onPressed: () {
            c.clearDrafts('marks:edit:');
            c.setEditing(row.key);
          }));
      actions.add(IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: row.state == 'added'
              ? Strings.get('marks_delete')
              : Strings.get('marks_leave_out'),
          onPressed: () =>
              c.predictRemove(summary.name, row.key)));
    }
    return Opacity(
      opacity: row.state == 'removed' ? 0.45 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: _chip(
                  c.markLabel(
                      mark, row.raw, summary.scale, hasPct),
                  c.rowKind(summary, row, bands),
                  _markTooltip(row),
                  hypothetical: row.state == 'added' ||
                      row.state == 'edited'),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: row.state == 'added'
                              ? t.accent
                              : t.text,
                          fontSize: t.fsSmall,
                          fontWeight: caption.isNotEmpty ||
                                  row.state == 'added'
                              ? FontWeight.bold
                              : FontWeight.normal)),
                  Text(
                      details
                          .where((d) => d.isNotEmpty)
                          .join(' · '),
                      style: TextStyle(
                          color: t.faint,
                          fontSize: t.fsTiny)),
                  if (note.isNotEmpty)
                    Text(note,
                        style: TextStyle(
                            color: t.muted,
                            fontSize: t.fsTiny)),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }

  Widget _editRow(BuildContext context, SubjectSummary summary,
      MarkRow row) {
    final c = controller;
    final t = tokens;
const gKey = 'marks:edit:grade';
    const wKey = 'marks:edit:weight';
    final gradeCtrl = TextEditingController(
        text: c.draft(gKey, row.text));
    final weightCtrl = TextEditingController(
        text: c.draft(wKey, formatWeight(row.weight)));

    void save() {
      final typed = (gradeCtrl.text, weightCtrl.text);
      c.clearDrafts('marks:edit:');
      if (!c.predictEdit(
          summary.name, row.key, typed.$1, typed.$2)) {
        c.setDraft(gKey, typed.$1);
        c.setDraft(wKey, typed.$2);
        _snack(context, Strings.get('marks_invalid'));
      }
    }

    void cancel() {
      c.clearDrafts('marks:edit:');
      c.setEditing(null);
    }

    return Container(
      decoration: BoxDecoration(
        color: tintColor(t.accent, 0.08),
        borderRadius: BorderRadius.circular(t.radiusSm),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        children: [
          Expanded(
              child: TextField(
            controller: gradeCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: Strings.get('marks_mark'),
              isDense: true,
              filled: true,
              fillColor: t.surface,
            ),
            onSubmitted: (_) => save(),
          )),
          const SizedBox(width: 4),
          SizedBox(
              width: 80,
              child: TextField(
                controller: weightCtrl,
                decoration: InputDecoration(
                  labelText: Strings.get('marks_weight'),
                  isDense: true,
                  filled: true,
                  fillColor: t.surface,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                onSubmitted: (_) => save(),
              )),
          IconButton(
              icon: Icon(Icons.check,
                  color: t.green, size: 18),
              tooltip: Strings.get('marks_save'),
              onPressed: save),
          IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: Strings.get('cancel'),
              onPressed: cancel),
        ],
      ),
    );
  }

  Widget _addForm(
      BuildContext context, SubjectSummary summary) {
    final c = controller;
    final t = tokens;
final gKey = 'marks:add:grade:${summary.name}';
    final wKey = 'marks:add:weight:${summary.name}';
    final gradeCtrl =
        TextEditingController(text: c.draft(gKey));
    final weightCtrl = TextEditingController(
        text: c.draft(
            wKey, formatWeight(defaultWeight(summary))));

    void add() {
      final typed = gradeCtrl.text;
      // Cleared before the add re-renders, so the fresh field is empty.
      c.drafts.remove(gKey);
      if (!c.predictAdd(
          summary.name, typed, weightCtrl.text)) {
        c.setDraft(gKey, typed);
        _snack(context, Strings.get('marks_invalid'));
      }
    }

    return Row(
      children: [
        Expanded(
            child: TextField(
          controller: gradeCtrl,
          decoration: InputDecoration(
            labelText: Strings.get('marks_mark'),
            hintText: summary.scale == 'percent'
                ? '85 %'
                : '1, 2-, 3',
            isDense: true,
            filled: true,
            fillColor: t.surface,
          ),
          onSubmitted: (_) => add(),
        )),
        const SizedBox(width: 6),
        SizedBox(
            width: 80,
            child: TextField(
              controller: weightCtrl,
              decoration: InputDecoration(
                labelText: Strings.get('marks_weight'),
                isDense: true,
                filled: true,
                fillColor: t.surface,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(
                      decimal: true),
              onSubmitted: (_) => add(),
            )),
        const SizedBox(width: 6),
        ElevatedButton.icon(
            onPressed: add,
            icon: const Icon(Icons.add, size: 18),
            label: Text(Strings.get('marks_add'))),
      ],
    );
  }

  List<Widget> _detailPlanned(SubjectSummary summary) {
    final t = tokens;
final rows = <Widget>[];
    final sorted = summary.planned.toList()
      ..sort((a, b) {
        final da = _plannedDate(a) ?? DateTime(9999);
        final db = _plannedDate(b) ?? DateTime(9999);
        return da.compareTo(db);
      });
    for (final m in sorted) {
      final day = _plannedDate(m);
      final weight = formatWeight(parseWeight(m['Weight']));
      final caption = '${m['Caption'] ?? ''}'.trim().isEmpty
          ? Strings.get('marks_planned_test')
          : '${m['Caption'] ?? ''}'.trim();
      rows.add(Row(
        children: [
          Icon(Icons.event_outlined,
              size: 16, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(caption,
                    style: TextStyle(
                        color: t.text,
                        fontSize: t.fsSmall,
                        fontWeight: FontWeight.bold)),
                Text(
                    '${day == null ? '?' : czDay(day)} · ${Strings.get('marks_weight')} $weight',
                    style: TextStyle(
                        color: t.faint,
                        fontSize: t.fsTiny)),
              ],
            ),
          ),
          TextButton(
              onPressed: () => controller.usePlannedWeight(
                  summary.name, weight),
              child: Text(Strings.get('marks_use_weight'),
                  style: TextStyle(
                      color: t.accent,
                      fontSize: t.fsSmall))),
        ],
      ));
    }
    return rows;
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

  void _snack(BuildContext context, String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
