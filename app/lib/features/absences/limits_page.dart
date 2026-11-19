import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import '../../widgets/overlays.dart' show appSnack;
import '../common/app_tokens.dart';
import '../common/format.dart';
import '../settings/settings_controller.dart';
import '../settings/settings_live.dart';
import '../settings/settings_view.dart' show AutosaveField;

/// Full-page attendance limits editor (`/absences/limits`).
///
/// Hosts the three global absence thresholds at the top and a tappable list of
/// per-subject rows whose inline editor offers quick-pick chips for the default
/// and every value already used in `subject_limits`.
class LimitsPage extends StatefulWidget {
  final SettingsController controller;
  final AppTokens tokens;
  final bool narrow;
  final VoidCallback? onBack;
  final VoidCallback? onLeave;

  const LimitsPage({
    super.key,
    required this.controller,
    required this.tokens,
    this.narrow = false,
    this.onBack,
    this.onLeave,
  });

  @override
  State<LimitsPage> createState() => _LimitsPageState();
}

class _LimitsPageState extends State<LimitsPage> {
  String? _expandedSubject;
  TextEditingController? _subjectText;
  FocusNode? _subjectFocus;

  SettingsController get c => widget.controller;
  AppTokens get tok => widget.tokens;

  static double? _parseNum(String raw) {
    final cleaned = raw.trim().replaceAll(',', '.');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  static double? _toDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw == null) return null;
    return double.tryParse('$raw'.trim().replaceAll(',', '.'));
  }

  double _defaultPct() =>
      _toDouble(c.get('absence_critical_pct', 25.0)) ?? 25.0;

  Map<String, dynamic> _subjectLimits() {
    final raw = c.get('subject_limits', {});
    if (raw is Map) {
      return {for (final e in raw.entries) '${e.key}': e.value};
    }
    return {};
  }

  List<double> _usedValues(Map<String, dynamic> limits, double defaultPct) {
    final out = <double>[];
    for (final raw in limits.values) {
      final v = _toDouble(raw);
      if (v == null) continue;
      if ((v - defaultPct).abs() < 1e-9) continue;
      if (out.any((e) => (e - v).abs() < 1e-9)) continue;
      out.add(v);
    }
    out.sort();
    return out;
  }

  void _disposeSubjectEditor() {
    _subjectText?.dispose();
    _subjectText = null;
    _subjectFocus?.dispose();
    _subjectFocus = null;
  }

  void _openSubject(String subject) {
    if (_expandedSubject == subject) {
      _commitExpanded(collapse: true);
      return;
    }
    if (_expandedSubject != null) {
      _commitExpanded(notify: false, collapse: false);
    }
    _disposeSubjectEditor();
    final own = _toDouble(_subjectLimits()[subject]);
    final text = TextEditingController(text: own == null ? '' : gFormat(own));
    final focus = FocusNode();
    focus.addListener(() {
      if (!focus.hasFocus && _expandedSubject == subject && mounted) {
        _commitExpanded(notify: true, collapse: false);
      }
    });
    setState(() {
      _expandedSubject = subject;
      _subjectText = text;
      _subjectFocus = focus;
    });
  }

  void _commitExpanded({
    bool notify = true,
    bool collapse = false,
    bool allowSnack = true,
  }) {
    final subject = _expandedSubject;
    final ctrl = _subjectText;
    if (subject != null && ctrl != null) {
      final raw = ctrl.text.trim();
      final current = _subjectLimits();
      final prev = _toDouble(current[subject]);
      if (raw.isEmpty) {
        if (current.containsKey(subject)) {
          current.remove(subject);
          c.saveQuiet({'subject_limits': current});
        }
      } else {
        final parsed = _parseNum(raw);
        if (parsed == null) {
          if (allowSnack && mounted) {
            appSnack(context, Strings.get('save_failed'));
          }
        } else if (prev == null || (prev - parsed).abs() >= 1e-9) {
          current[subject] = parsed;
          c.saveQuiet({'subject_limits': current});
        }
      }
    }
    if (collapse) {
      _expandedSubject = null;
      _disposeSubjectEditor();
    }
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _applyDefaultChip(String subject) {
    final current = _subjectLimits();
    if (current.containsKey(subject)) {
      current.remove(subject);
      c.saveQuiet({'subject_limits': current});
    }
    _expandedSubject = null;
    _subjectText?.text = '';
    _disposeSubjectEditor();
    if (mounted) setState(() {});
  }

  void _applyValueChip(String subject, double value) {
    final current = _subjectLimits();
    final prev = _toDouble(current[subject]);
    if (prev == null || (prev - value).abs() >= 1e-9) {
      current[subject] = value;
      c.saveQuiet({'subject_limits': current});
    }
    _expandedSubject = null;
    _subjectText?.text = gFormat(value);
    _disposeSubjectEditor();
    if (mounted) setState(() {});
  }

  void _handleBack() {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onBack?.call();
  }

  @override
  void dispose() {
    _commitExpanded(notify: false, collapse: false, allowSnack: false);
    _disposeSubjectEditor();
    final leave = widget.onLeave;
    if (leave != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => leave());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final defaultPct = _defaultPct();
    final limits = _subjectLimits();
    final usedValues = _usedValues(limits, defaultPct);
    final subjects = () {
      final raw = c.get('absence', {});
      if (raw is Map) return raw.keys.map((k) => '$k').toList()..sort();
      return <String>[];
    }();

    final globalFields = [
      AutosaveField(
        controller: c,
        label: Strings.get('default_limit'),
        draftKey: 'lim:default',
        configKey: 'absence_critical_pct',
        fallback: '${c.get('absence_critical_pct', 25.0)}',
        parse: (raw) => _parseNum(raw) ?? 25.0,
        saveOnDispose: true,
        onSaved: (_) {
          if (mounted) setState(() {});
        },
      ),
      AutosaveField(
        controller: c,
        label: Strings.get('warn_limit'),
        draftKey: 'lim:warn',
        configKey: 'absence_warn_pct',
        fallback: '${c.get('absence_warn_pct', 15.0)}',
        parse: (raw) => _parseNum(raw) ?? 15.0,
        saveOnDispose: true,
      ),
      AutosaveField(
        controller: c,
        label: Strings.get('reserve_limit'),
        draftKey: 'lim:reserve',
        configKey: 'absence_plan_reserve_pct',
        fallback: '${c.get('absence_plan_reserve_pct', 10.0)}',
        parse: (raw) {
          final v = _parseNum(raw) ?? 10.0;
          return v.clamp(0.0, 99.9);
        },
        saveOnDispose: true,
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('lim:back_btn'),
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _handleBack,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                Strings.get('sec_limits'),
                style: TextStyle(
                  color: tok.text,
                  fontSize: tok.fsTitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          color: tok.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tok.radiusMd),
            side: BorderSide(color: tok.border),
          ),
          child: Padding(
            padding: EdgeInsets.all(tok.pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 14,
              children: [
                if (widget.narrow)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 14,
                    children: globalFields,
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 12,
                    children: [
                      for (final field in globalFields) Expanded(child: field),
                    ],
                  ),
                Text(
                  Strings.get('reserve_hint'),
                  style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (subjects.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Text(
              Strings.get('no_data'),
              style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
            ),
          )
        else
          for (final subject in subjects)
            _subjectRow(
              subject: subject,
              own: _toDouble(limits[subject]),
              defaultPct: defaultPct,
              usedValues: usedValues,
            ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            Strings.get('limit_subject_hint'),
            style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
          ),
        ),
      ],
    );
  }

  Widget _subjectRow({
    required String subject,
    required double? own,
    required double defaultPct,
    required List<double> usedValues,
  }) {
    final isExpanded = _expandedSubject == subject;
    return Card(
      color: tok.card,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tok.radiusMd),
        side: BorderSide(color: isExpanded ? tok.accent : tok.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('lim:row:$subject'),
            onTap: () => _openSubject(subject),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tok.pad,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      subject,
                      style: TextStyle(
                        color: tok.text,
                        fontSize: tok.fsBody,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (own == null) ...[
                    Text(
                      '${gFormat(defaultPct)} %',
                      style: TextStyle(
                        color: tok.muted,
                        fontSize: tok.fsSmall,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: tok.overlay,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        Strings.get('limit_default_tag'),
                        style: TextStyle(
                          color: tok.muted,
                          fontSize: tok.fsSmall - 1,
                        ),
                      ),
                    ),
                  ] else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: tintColor(tok.accent, 0.16),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: tintColor(tok.accent, 0.4),
                        ),
                      ),
                      child: Text(
                        '${gFormat(own)} %',
                        style: TextStyle(
                          color: tok.accent,
                          fontSize: tok.fsSmall,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.edit_outlined,
                    size: 20,
                    color: tok.muted,
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded && _subjectText != null && _subjectFocus != null)
            Padding(
              padding: EdgeInsets.fromLTRB(tok.pad, 0, tok.pad, tok.pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  Divider(height: 1, color: tok.border),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: Key('lim:subj:$subject'),
                          controller: _subjectText,
                          focusNode: _subjectFocus,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: TextStyle(
                            color: tok.text,
                            fontSize: tok.fsBody,
                          ),
                          decoration: InputDecoration(
                            hintText: '${gFormat(defaultPct)} %',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _commitExpanded(collapse: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        key: Key('lim:done:$subject'),
                        icon: const Icon(Icons.check),
                        tooltip: Strings.get('confirm'),
                        onPressed: () => _commitExpanded(collapse: true),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        key: const Key('lim:chip:default'),
                        label: Text(
                          Strings.format(
                            'limit_use_default',
                            {'pct': defaultPct},
                          ),
                        ),
                        onPressed: () => _applyDefaultChip(subject),
                      ),
                      for (final v in usedValues)
                        ActionChip(
                          key: Key('lim:chip:${gFormat(v)}'),
                          label: Text('${gFormat(v)} %'),
                          onPressed: () => _applyValueChip(subject, v),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Live limits page wired to [appStateProvider].
class LiveLimitsPage extends ConsumerWidget {
  final AppTokens? tokens;
  final bool narrow;
  final VoidCallback? onBack;

  const LiveLimitsPage({
    super.key,
    this.tokens,
    this.narrow = false,
    this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    final tok = tokens ?? s.appTokens;
    return LimitsPage(
      controller: settingsControllerFor(s),
      tokens: tok,
      narrow: narrow,
      onBack: onBack,
      onLeave: () {
        if (!notifier.isMounted) return;
        s.save(const {});
      },
    );
  }
}
