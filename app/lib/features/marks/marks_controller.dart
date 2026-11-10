import 'package:flutter/foundation.dart';

import '../../l10n/strings.dart';
import '../common/format.dart';
import 'grades_logic.dart';

/// Marks screen state + logic — a `ChangeNotifier` port of
/// `views/marks.py` helpers and the `MarksMixin` in `state_marks.py`.
///
/// Predictions live in memory only ([predictions]): what-ifs for this
/// session, never written to disk, so a hypothetical mark can not
/// linger next to the real one once the teacher enters it.
class MarksController extends ChangeNotifier {
/// Reads config values (same keys as Python: `marks_scale`,
  /// `marks_subject_scales`, `marks_sort`, `marks_percent_bands`).
  final Map<String, Object?> config;

  /// Persists config updates. Returns false when the write failed.
  final bool Function(Map<String, Object?> updates) onSave;

  MarksController({
    Map<String, Object?>? config,
    bool Function(Map<String, Object?> updates)? onSave,
  })  : config = config ?? {},
        onSave = onSave ?? ((_) => false);

  // -- inputs (set by the shell) --------------------------------------------------

  /// `{subject: [markDict, ...]}` (`grades()`).
  Map<String, List<Object?>> grades = {};

  /// `{subject: {Grade, Note}}` (`quarterly_marks()`).
  Map<String, Map<String, Object?>> quarterlyMarks = {};

  /// School preset bands (`preset_marks_bands()`), null when none.
  List<double>? presetBands;

  /// Preset title for the bands source line.
  String presetTitle = '';

  bool demoMode = false;

  /// Fixed clock for tests/screenshots (defaults to `DateTime.now()`).
  DateTime? todayOverride;

  // -- in-memory UI state (like AppState fields) ------------------------------------

  /// `{subject: {added, edits, removed}}`.
  final Map<String, Map<String, Object?>> predictions = {};

  String? selectedSubject;
  String? editingKey;

  /// `{subject: {target, weight}}` calculator inputs.
  final Map<String, Map<String, String>> calcInputs = {};

  /// Unsaved field text surviving re-renders (`drafts`).
  final Map<String, String> drafts = {};

  /// Optional live-state callback when drafts change.
  void Function()? onDraftsChanged;

  // -- persisted preferences ----------------------------------------------------------

  String marksScale() {
    final value = '${config['marks_scale'] ?? 'auto'}';
    return scaleChoices.contains(value) ? value : 'auto';
  }

  Map<String, String> marksSubjectScales() {
    final raw = config['marks_subject_scales'];
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (scales.contains('${e.value}')) '${e.key}': '${e.value}',
    };
  }

  /// `(bands, 'user' | 'preset' | 'default')` — like
  /// `school_presets.resolve_marks_bands`.
  (List<double>, String) marksBandsSource() {
    final user = config['marks_percent_bands'];
    if (bandsValid(user)) return (normalizeBands(user), 'user');
    if (presetBands != null && bandsValid(presetBands)) {
      return (List<double>.of(presetBands!), 'preset');
    }
    return (List<double>.of(defaultBands), 'default');
  }

  List<double> marksBands() => marksBandsSource().$1;

  String marksSort() {
    const sorts = ['name', 'average', 'recent'];
    final value = '${config['marks_sort'] ?? 'name'}';
    return sorts.contains(value) ? value : 'name';
  }

  /// Global scale; picking one clears the per-subject overrides so the
  /// switch visibly applies everywhere.
  bool setMarksScale(String scale) {
    if (!scaleChoices.contains(scale)) return false;
    return _save({'marks_scale': scale, 'marks_subject_scales': {}});
  }

  /// Per-subject override; `auto` drops it (the global choice applies).
  bool setSubjectScale(String subject, String scale) {
    final current = marksSubjectScales();
    if (scales.contains(scale)) {
      current[subject] = scale;
    } else {
      current.remove(subject);
    }
    return _save({'marks_subject_scales': current});
  }

  /// Own bands; null drops them (back to the school preset / default).
  bool setMarksBands(List<double>? bands) {
    if (bands == null) return _save({'marks_percent_bands': []});
    if (!bandsValid(bands)) return false;
    return _save({'marks_percent_bands': List<double>.of(bands)});
  }

  bool setMarksSort(String sort) {
    const sorts = ['name', 'average', 'recent'];
    if (!sorts.contains(sort)) return false;
    return _save({'marks_sort': sort});
  }

  bool _save(Map<String, Object?> updates) {
    final ok = onSave(updates);
    if (ok) {
      config.addAll(updates);
      notifyListeners();
    }
    return ok;
  }

  // -- summaries --------------------------------------------------------------------------

  List<SubjectSummary> summaries() {
    try {
      return summarizeAll(grades,
          scalePref: marksScale(),
          subjectScales: marksSubjectScales(),
          predictions: predictions,
          bands: marksBands(),
          today: todayOverride);
    } catch (_) {
      // A bad mark must not blank the tab.
      return [];
    }
  }

  SubjectSummary? selected() {
    final name = selectedSubject;
    if (name == null) return null;
    for (final summary in summaries()) {
      if (summary.name == name) return summary;
    }
    return null;
  }

  // -- selection ------------------------------------------------------------------------------

  /// Clicking the open subject again closes it.
  void selectSubject(String? subject) {
    if (selectedSubject == subject) subject = null;
    selectedSubject = subject;
    editingKey = null;
    notifyListeners();
  }

  void setEditing(String? key) {
    editingKey = key;
    notifyListeners();
  }

  // -- calculator inputs (per subject, in memory) -----------------------------------------------

  Map<String, String> marksCalc(String subject) =>
      calcInputs.putIfAbsent(subject, () => {});

  void setMarksCalc(String subject, {String? target, String? weight}) {
    final calc = marksCalc(subject);
    var changed = false;
    if (target != null && calc['target'] != target) {
      calc['target'] = target;
      changed = true;
    }
    if (weight != null && calc['weight'] != weight) {
      calc['weight'] = weight;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Pre-fills the predictor's weight with an announced test's weight.
  void usePlannedWeight(String subject, String weight) {
    setDraft('marks:add:weight:$subject', weight);
  }

  // -- drafts ----------------------------------------------------------------------------------------

  String draft(String key, [String fallback = '']) =>
      drafts[key] ?? fallback;

  void setDraft(String key, String value) {
    drafts[key] = value;
    onDraftsChanged?.call();
  }

  void clearDrafts([String prefix = '']) {
    if (prefix.isEmpty) {
      drafts.clear();
    } else {
      drafts.removeWhere((k, _) => k.startsWith(prefix));
    }
    onDraftsChanged?.call();
  }

  // -- predictor ---------------------------------------------------------------------------------------

  Map<String, Object?> _ops(String subject) {
    var ops = predictions[subject];
    if (ops is! Map<String, Object?>) {
      ops = {
        'added': <Map<String, Object?>>[],
        'edits': <String, Map<String, Object?>>{},
        'removed': <String>[],
      };
      predictions[subject] = ops;
    }
    return ops;
  }

  void _dropIfEmpty(String subject) {
    if (!predictionActive(predictions[subject])) {
      predictions.remove(subject);
    }
  }

  /// `{Grade, Weight}` or null when invalid — like `_clean_mark`.
  /// Weight: comma decimal, `0 < w <= 100`.
  static Map<String, Object?>? cleanMark(String grade, Object? weight) {
    final text = grade.trim();
    if (!validMarkText(text)) return null;
    final w =
        double.tryParse('${weight ?? ''}'.replaceAll(',', '.').trim());
    if (w == null || !(w > 0 && w <= 100)) return null;
    return {'Grade': text, 'Weight': w};
  }

  /// Adds a hypothetical mark. False (nothing changes) when invalid.
  bool predictAdd(String subject, String grade, Object? weight) {
    final mark = cleanMark(grade, weight);
    if (mark == null) return false;
    final ops = _ops(subject);
    (ops['added'] as List).add(mark);
    notifyListeners();
    return true;
  }

  /// Changes a real or hypothetical mark in the prediction.
  bool predictEdit(
      String subject, String key, String grade, Object? weight) {
    final mark = cleanMark(grade, weight);
    if (mark == null) return false;
    final ops = _ops(subject);
    if (key.startsWith('add:')) {
      final added = ops['added'] as List;
      final i = int.tryParse(key.substring(4));
      if (i == null || i < 0 || i >= added.length) return false;
      added[i] = mark;
    } else if (_sameAsReal(subject, key, mark)) {
      // Saved back unchanged: not an edit.
      (ops['edits'] as Map).remove(key);
    } else {
      (ops['edits'] as Map)[key] = mark;
    }
    editingKey = null;
    _dropIfEmpty(subject);
    notifyListeners();
    return true;
  }

  bool _sameAsReal(
      String subject, String key, Map<String, Object?> mark) {
    final real = [
      for (final m in (grades[subject] ?? const []))
        if (m is Map && !isPlanned(m.cast<String, Object?>()))
          m.cast<String, Object?>(),
    ];
    final keys = markKeys(real);
    for (var i = 0; i < keys.length; i++) {
      if (keys[i] == key) {
        final original = real[i];
        return '${original['Grade'] ?? ''}'.trim() ==
                '${mark['Grade'] ?? ''}'.trim() &&
            parseWeight(original['Weight']) ==
                (mark['Weight'] as num).toDouble();
      }
    }
    return false;
  }

  /// Deletes a hypothetical mark, or leaves a real one out.
  void predictRemove(String subject, String key) {
    final ops = _ops(subject);
    if (key.startsWith('add:')) {
      final added = ops['added'] as List;
      final i = int.tryParse(key.substring(4));
      if (i != null && i >= 0 && i < added.length) {
        added.removeAt(i);
      }
    } else {
      (ops['edits'] as Map).remove(key);
      final removed = ops['removed'] as List;
      if (!removed.contains(key)) removed.add(key);
    }
    if (editingKey == key ||
        (editingKey ?? '').startsWith('add:')) {
      // Hypothetical keys are positional: any open editor may now
      // point at a different mark.
      editingKey = null;
    }
    _dropIfEmpty(subject);
    notifyListeners();
  }

  /// Brings a real mark back to its real value.
  void predictRestore(String subject, String key) {
    final ops = _ops(subject);
    (ops['edits'] as Map).remove(key);
    (ops['removed'] as List)
        .removeWhere((k) => '$k' == key);
    _dropIfEmpty(subject);
    notifyListeners();
  }

  void predictReset([String? subject]) {
    if (subject == null) {
      predictions.clear();
    } else {
      predictions.remove(subject);
    }
    editingKey = null;
    notifyListeners();
  }

  // -- aggregates (view-side) -----------------------------------------------------------------------------

  /// Mean of subject averages: in percent when every subject is
  /// percent, else on the 1–5 axis (percent subjects via their grade).
  (double?, String) overall(
      List<SubjectSummary> items, List<double> bands) {
    final withAvg = [
      for (final x in items)
        if (x.current != null) x
    ];
    if (withAvg.isEmpty) return (null, 'grade');
    if (withAvg.every((x) => x.scale == 'percent')) {
      final sum = withAvg.map((x) => x.current!).reduce((a, b) => a + b);
      return (sum / withAvg.length, 'percent');
    }
    final vals = [
      for (final x in withAvg) gradeEquivalent(x.current, x.scale, bands)!,
    ];
    return (
      vals.reduce((a, b) => a + b) / vals.length,
      'grade'
    );
  }

  double? reportEstimate(
      List<SubjectSummary> items, List<double> bands) {
    final finals = [
      for (final x in items) finalGrade(x.current, x.scale, bands),
    ].whereType<int>();
    if (finals.isEmpty) return null;
    return finals.reduce((a, b) => a + b) / finals.length;
  }

  /// Worst first for `average` (subjects needing attention lead).
  List<SubjectSummary> sorted(
      List<SubjectSummary> items, String sort, List<double> bands) {
    final out = List<SubjectSummary>.of(items);
    if (sort == 'average') {
      out.sort((a, b) {
        final ac = a.current;
        final bc = b.current;
        if ((ac == null) != (bc == null)) {
          return ac == null ? -1 : 1;
        }
        final ag = ac == null
            ? 0.0
            : (gradeEquivalent(ac, a.scale, bands) ?? 0.0);
        final bg = bc == null
            ? 0.0
            : (gradeEquivalent(bc, b.scale, bands) ?? 0.0);
        final c = bg.compareTo(ag);
        if (c != 0) return c;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return out;
    }
    if (sort == 'recent') {
      out.sort((a, b) {
        final ad = a.lastDate ?? DateTime(1, 1, 1);
        final bd = b.lastDate ?? DateTime(1, 1, 1);
        return bd.compareTo(ad);
      });
      return out;
    }
    return out; // already by name
  }

  /// True/False when the newest mark moved the average; null when flat.
  bool? improving(SubjectSummary summary) {
    final trend = summary.trend;
    if (trend == null) return null;
    final eps = summary.scale == 'percent' ? 0.5 : 0.01;
    if (trend.abs() < eps) return null;
    return summary.scale == 'percent' ? trend > 0 : trend < 0;
  }

  /// The mark as written, with `%` added to bare percentages.
  String markLabel(Map<String, Object?> mark, RawMark? raw,
      String scale, bool hasPct) {
    final text = '${mark['Grade'] ?? '?'}'.trim().isEmpty
        ? '?'
        : '${mark['Grade'] ?? '?'}'.trim();
    if (raw == null) return text;
    final asPct = raw.kind == 'percent' ||
        (raw.kind == 'small' && scale == 'percent' && hasPct);
    if (asPct && !text.contains('%') && !text.contains('/')) {
      return '$text %';
    }
    return text;
  }

  bool subjectHasPct(SubjectSummary summary) =>
      summary.rows.any((r) => r.raw != null && r.raw!.kind == 'percent');

  String rowKind(
          SubjectSummary summary, MarkRow row, List<double> bands) =>
      kindFor(row.value, summary.scale, bands);

  String finalText(SubjectSummary summary, List<double> bands) {
    final final_ = finalGrade(summary.current, summary.scale, bands);
    return final_ == null ? '—' : '$final_';
  }

  /// Bands source line — like `marks._bands_source_text`.
  String bandsSourceText(String source) {
    if (source == 'user') return Strings.get('marks_bands_src_user');
    if (source == 'preset') {
      return Strings.format('marks_bands_src_preset', {'school': presetTitle});
    }
    return Strings.get('marks_bands_src_default');
  }

  /// `1: 100–87 · 2: 87–72 · … · 5: 40–0` (the Bakaláři table layout).
  static String bandsRanges(List<double> bands) {
    final tops = [100.0, ...bands];
    final parts = [
      for (var g = 1; g <= 4; g++)
        '$g: ${gFormat(tops[g - 1])}–${gFormat(tops[g])}',
      '5: ${gFormat(tops[4])}–0',
    ];
    return '${parts.join(' · ')} %';
  }

  /// Target goal for the "what do I need" calculator: one grade better
  /// than where the subject is heading (default), clamped to 1–4.
  int needTarget(SubjectSummary summary, List<double> bands) {
    final currentFinal =
        finalGrade(summary.current, summary.scale, bands);
    final stored =
        int.tryParse(marksCalc(summary.name)['target'] ?? '');
    final target = stored ?? ((currentFinal ?? 2) - 1);
    return target.clamp(1, 4);
  }

  double needWeight(SubjectSummary summary) {
    final fallback = defaultWeight(summary);
    final text =
        marksCalc(summary.name)['weight'] ?? formatWeight(fallback);
    final weight =
        double.tryParse(text.replaceAll(',', '.').trim()) ?? fallback;
    return weight > 0 ? weight : fallback;
  }
}
