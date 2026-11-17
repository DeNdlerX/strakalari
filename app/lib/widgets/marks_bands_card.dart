import 'package:flutter/material.dart';

import '../features/common/app_tokens.dart';
import '../features/common/format.dart';
import '../features/marks/marks_controller.dart';
import '../l10n/strings.dart';

/// Shared percent → grade boundary editor card used in Známky (for custom
/// schools) and Settings → Škola.
class MarksBandsCard extends StatefulWidget {
  final AppTokens tokens;
  final List<double> bands;
  final String source;
  final List<double>? presetBands;
  final String presetTitle;
  final String Function(String key, [String fallback]) readDraft;
  final void Function(String key, String value) writeDraft;
  final void Function(String prefix) clearDrafts;
  final bool Function(List<double>? bands) onSaveBands;
  final List<double> Function() currentBands;
  final void Function(BuildContext context, String message) onSnack;
  final Widget Function(
      String title, List<Widget> controls, {IconData? icon})? sectionBuilder;

  const MarksBandsCard({
    super.key,
    required this.tokens,
    required this.bands,
    required this.source,
    required this.presetBands,
    required this.presetTitle,
    required this.readDraft,
    required this.writeDraft,
    required this.clearDrafts,
    required this.onSaveBands,
    required this.currentBands,
    required this.onSnack,
    this.sectionBuilder,
  });

  @override
  State<MarksBandsCard> createState() => _MarksBandsCardState();
}

class _MarksBandsCardState extends State<MarksBandsCard> {
  late final List<TextEditingController> _fields;
  late final List<FocusNode> _focusNodes;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _focusNodes = List.generate(4, (_) => FocusNode());
    _fields = List.generate(4, (i) {
      final key = 'marks:band:${i + 1}';
      final ctrl = TextEditingController(
        text: widget.readDraft(key, gFormat(widget.bands[i])),
      );
      ctrl.addListener(() {
        if (!_syncing) {
          widget.writeDraft(key, ctrl.text);
        }
      });
      return ctrl;
    });
  }

  void _syncField(int index, String value) {
    _syncing = true;
    try {
      _fields[index].text = value;
    } finally {
      _syncing = false;
    }
  }

  @override
  void didUpdateWidget(covariant MarksBandsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (var i = 0; i < 4; i++) {
      if (_focusNodes[i].hasFocus) continue;
      final key = 'marks:band:${i + 1}';
      final desired = widget.readDraft(key, gFormat(widget.bands[i]));
      if (_fields[i].text != desired) {
        _syncField(i, desired);
      }
    }
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _save(BuildContext context) {
    List<double>? parsed;
    try {
      parsed = [
        for (final f in _fields)
          double.parse(f.text.replaceAll(',', '.').trim())
      ];
    } catch (_) {
      parsed = null;
    }
    if (parsed != null && widget.onSaveBands(parsed)) {
      widget.clearDrafts('marks:band:');
      final updated = widget.currentBands();
      for (var i = 0; i < 4; i++) {
        _syncField(i, gFormat(updated[i]));
      }
      widget.onSnack(context, Strings.get('marks_bands_saved'));
    } else {
      widget.onSnack(context, Strings.get('marks_bands_invalid'));
    }
  }

  void _reset() {
    widget.clearDrafts('marks:band:');
    widget.onSaveBands(null);
    final updated = widget.currentBands();
    for (var i = 0; i < 4; i++) {
      _syncField(i, gFormat(updated[i]));
    }
  }

  String _sourceText() {
    if (widget.source == 'user') return Strings.get('marks_bands_src_user');
    if (widget.source == 'preset') {
      return Strings.format(
          'marks_bands_src_preset', {'school': widget.presetTitle});
    }
    return Strings.get('marks_bands_src_default');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final bands = widget.bands;
    final source = widget.source;

    final cells = <Widget>[
      for (var i = 0; i < 4; i++)
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.format('marks_band_label', {'grade': i + 2}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: t.fsTiny)),
              const SizedBox(height: 4),
              TextField(
                key: Key('marks:band:${i + 1}'),
                controller: _fields[i],
                focusNode: _focusNodes[i],
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: t.surface,
                  suffixText: '%',
                ),
              ),
            ],
          ),
        ),
    ];

    final buttons = <Widget>[
      TextButton.icon(
          key: const Key('marks:bands_save'),
          onPressed: () => _save(context),
          icon: const Icon(Icons.check, size: 18),
          label: Text(Strings.get('marks_save'))),
    ];
    if (source == 'user') {
      buttons.add(TextButton(
          key: const Key('marks:bands_reset'),
          onPressed: _reset,
          child: Text(
              widget.presetBands != null
                  ? Strings.get('marks_bands_use_school')
                  : Strings.get('marks_bands_default'),
              style: TextStyle(color: t.muted))));
    }

    final controls = <Widget>[
      Row(
        children: [
          Icon(
              source == 'preset' ? Icons.school_outlined : Icons.tune,
              size: 14,
              color: t.accent),
          const SizedBox(width: 6),
          Expanded(
              child: Text(_sourceText(),
                  style: TextStyle(color: t.accent, fontSize: t.fsSmall))),
        ],
      ),
      Text(MarksController.bandsRanges(bands),
          style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
      Text(Strings.get('marks_bands_hint'),
          style: TextStyle(color: t.muted, fontSize: t.fsSmall)),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(spacing: 8, children: cells),
      ),
      Wrap(spacing: 8, children: buttons),
    ];

    if (widget.sectionBuilder != null) {
      return widget.sectionBuilder!(
        Strings.get('marks_bands'),
        controls,
        icon: Icons.percent,
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Row(
              children: [
                Icon(Icons.percent, size: 16, color: t.faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    Strings.get('marks_bands'),
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            ...controls,
          ],
        ),
      ),
    );
  }
}
