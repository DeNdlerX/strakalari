// Marks state: scale choice, sorting, selection and the predictor.
//
// Port of strakalari/flet_ui/state_marks.py (`MarksMixin`). Pure logic is
// implemented as an extension on [AppState] so unit tests need no
// provider container; [MarksController] is the Riverpod facade the
// phase-6 marks screen talks to.
//
// Predictions live in memory only (what-ifs for this session, never
// written to disk). All timestamps use package:clock.
part of 'app_state.dart';

const List<String> marksSorts = ['name', 'average', 'recent'];

/// Pure marks logic. Port of `MarksMixin` (Flet bits dropped).
extension MarksLogic on AppState {
  // -- persisted preferences ------------------------------------------------
  String marksScale() {
    final value = '${get('marks_scale', 'auto')}';
    return scaleChoices.contains(value) ? value : 'auto';
  }

  Map<String, String> marksSubjectScales() {
    final raw = get('marks_subject_scales', {});
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (scales.contains('${e.value}')) '${e.key}': '${e.value}',
    };
  }

  List<double> marksBands() => marksBandsSource().$1;

  (List<double>, String) marksBandsSource() {
    try {
      final resolved = resolveMarksBands(config.data);
      return (resolved.bands, resolved.source);
    } catch (_) {
      return (List<double>.of(defaultBands), 'default');
    }
  }

  String marksSort() {
    final value = '${get('marks_sort', 'name')}';
    return marksSorts.contains(value) ? value : 'name';
  }

  /// Global scale; picking one clears per-subject overrides. Port of
  /// `set_marks_scale()`.
  bool setMarksScale(String scale) {
    if (!scaleChoices.contains(scale)) return false;
    return save({'marks_scale': scale, 'marks_subject_scales': {}});
  }

  /// Per-subject override; unknown scales drop it. Port of
  /// `set_subject_scale()`.
  bool setSubjectScale(String subject, String scale) {
    final current = marksSubjectScales();
    if (scales.contains(scale)) {
      current[subject] = scale;
    } else {
      current.remove(subject);
    }
    return save({'marks_subject_scales': current});
  }

  /// Own bands; null drops them (school preset / default applies).
  /// Port of `set_marks_bands()`.
  bool setMarksBands(List<Object?>? bands) {
    if (bands == null) return save({'marks_percent_bands': <double>[]});
    if (!bandsValid(bands)) return false;
    return save({
      'marks_percent_bands': [for (final b in bands) (b as num).toDouble()],
    });
  }

  bool setMarksSort(String sort) {
    if (!marksSorts.contains(sort)) return false;
    return save({'marks_sort': sort});
  }

  // -- summaries --------------------------------------------------------------
  List<SubjectSummary> marksSummaries() {
    try {
      return summarizeAll(
        grades().cast<dynamic, dynamic>(),
        scalePref: marksScale(),
        subjectScales: marksSubjectScales().cast<dynamic, dynamic>(),
        predictions: marksPredictions.cast<dynamic, dynamic>(),
        bands: marksBands(),
      );
    } catch (err) {
      // A bad mark must not blank the tab.
      return [];
    }
  }

  // -- selection -----------------------------------------------------------------
  void selectMarksSubject(String? subject) {
    if (marksSelected == subject) subject = null;
    marksSelected = subject;
    marksEditing = null;
    if (subject != null) tutorialEvent('marks_subject_opened');
    _emit();
  }

  void setMarksEditing(String? key) {
    marksEditing = key;
    _emit();
  }

  // -- "what do I need" calculator inputs (per subject, in memory) --------------
  Map<String, String> marksCalc(String subject) =>
      marksCalcStore.putIfAbsent(subject, () => <String, String>{});

  void setMarksCalc(String subject, Map<String, String> values) {
    final calc = marksCalc(subject);
    var changed = false;
    values.forEach((key, value) {
      value = value.trim();
      if (calc[key] != value) {
        calc[key] = value;
        changed = true;
      }
    });
    if (changed) _emit();
  }

  void usePlannedWeight(String subject, String weight) {
    setDraft('marks:add:weight:$subject', weight);
    _emit();
  }

  // -- predictor -------------------------------------------------------------------
  Map<String, Object?> _ops(String subject) {
    var ops = marksPredictions[subject];
    if (ops is! Map<String, Object?>) {
      ops = Map<String, Object?>.of(emptyPrediction());
      marksPredictions[subject] = ops;
    }
    return ops;
  }

  void _dropIfEmpty(String subject) {
    if (!predictionActive(marksPredictions[subject])) {
      marksPredictions.remove(subject);
    }
  }

  /// Validated hypothetical mark, or null. Port of `_clean_mark()`.
  static Map<String, Object?>? cleanMark(String grade, Object? weight) {
    final text = grade.trim();
    if (!validMarkText(text)) return null;
    final w =
        double.tryParse('${weight ?? ''}'.replaceAll(',', '.').trim());
    if (w == null || w <= 0 || w > 100) return null;
    return {'Grade': text, 'Weight': w};
  }

  /// Adds a hypothetical mark. False (nothing changes) when invalid.
  bool predictAdd(String subject, String grade, Object? weight) {
    final mark = cleanMark(grade, weight);
    if (mark == null) return false;
    (_ops(subject)['added'] as List).add(mark);
    tutorialEvent('marks_predicted');
    _emit();
    return true;
  }

  /// Changes a real or hypothetical mark in the prediction.
  bool predictEdit(String subject, String key, String grade, Object? weight) {
    final mark = cleanMark(grade, weight);
    if (mark == null) return false;
    final ops = _ops(subject);
    if (key.startsWith('add:')) {
      final index = int.tryParse(key.substring(4));
      final added = ops['added'] as List;
      if (index == null || index < 0 || index >= added.length) return false;
      added[index] = mark;
    } else if (_sameAsReal(subject, key, mark)) {
      (ops['edits'] as Map).remove(key);
    } else {
      (ops['edits'] as Map)[key] = mark;
    }
    marksEditing = null;
    _dropIfEmpty(subject);
    tutorialEvent('marks_predicted');
    _emit();
    return true;
  }

  bool _sameAsReal(
      String subject, String key, Map<String, Object?> mark) {
    final given = grades()[subject];
    final rawList = given is List ? given : const [];
    final real = [
      for (final m in rawList)
        if (m is Map && !isPlanned(m)) strObjMap(m),
    ];
    for (var i = 0; i < real.length; i++) {
      final keys = markKeys(real);
      if (i >= keys.length) break;
      if (keys[i] == key) {
        final original = real[i];
        return '${original['Grade'] ?? ''}'.trim() == mark['Grade'] &&
            parseWeight(original['Weight']) == mark['Weight'];
      }
    }
    return false;
  }

  /// Deletes a hypothetical mark, or leaves a real one out of the prediction.
  void predictRemove(String subject, String key) {
    final ops = _ops(subject);
    if (key.startsWith('add:')) {
      final index = int.tryParse(key.substring(4));
      final added = ops['added'] as List;
      if (index != null && index >= 0 && index < added.length) {
        added.removeAt(index);
      }
    } else {
      (ops['edits'] as Map).remove(key);
      if (!(ops['removed'] as List).contains(key)) {
        (ops['removed'] as List).add(key);
      }
    }
    if (marksEditing == key ||
        (marksEditing ?? '').startsWith('add:')) {
      // Hypothetical keys are positional: any open editor may now
      // point at a different mark.
      marksEditing = null;
    }
    _dropIfEmpty(subject);
    tutorialEvent('marks_predicted');
    _emit();
  }

  /// Brings a real mark back to its real value.
  void predictRestore(String subject, String key) {
    final ops = _ops(subject);
    (ops['edits'] as Map).remove(key);
    ops['removed'] =
        (ops['removed'] as List).where((k) => k != key).toList();
    _dropIfEmpty(subject);
    _emit();
  }

  void predictReset([String? subject]) {
    if (subject == null) {
      marksPredictions.clear();
    } else {
      marksPredictions.remove(subject);
    }
    marksEditing = null;
    _emit();
  }
}

/// Riverpod facade for the marks screen (phase 6).
class MarksController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);

  List<SubjectSummary> summaries() => state.marksSummaries();
}

final marksControllerProvider =
    NotifierProvider<MarksController, AppState>(MarksController.new);
