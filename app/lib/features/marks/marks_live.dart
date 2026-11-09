// Bridges [AppState] (Riverpod) to [MarksController] / [MarksView].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart' hide MarksController;
import '../common/app_strings.dart';
import '../common/app_tokens.dart';
import 'marks_controller.dart';
import 'marks_view.dart';

Map<String, Map<String, Object?>> _clonePredictions(
    Map<String, Map<String, Object?>> src) {
  final out = <String, Map<String, Object?>>{};
  src.forEach((subject, ops) {
    final added = ops['added'];
    final edits = ops['edits'];
    final removed = ops['removed'];
    out[subject] = {
      'added': [
        if (added is List)
          for (final m in added)
            if (m is Map) Map<String, Object?>.of(m.cast<String, Object?>()),
      ],
      'edits': <String, Map<String, Object?>>{
        if (edits is Map)
          for (final e in edits.entries)
            if (e.value is Map)
              '${e.key}': Map<String, Object?>.of(
                  (e.value as Map).cast<String, Object?>()),
      },
      'removed': [
        if (removed is List)
          for (final k in removed) '$k',
      ],
    };
  });
  return out;
}

/// Builds a [MarksController] populated from [s] and wired so
/// scale/sort/band changes, selection, calculator inputs and
/// predictions stay in sync with [s].
MarksController marksControllerFor(AppState s, {DateTime? todayOverride}) {
  final lang = '${s.get('language', 'cs')}' == 'en' ? 'en' : 'cs';
  final c = MarksController(
    s: AppStrings(lang),
    config: Map<String, Object?>.of(s.config.data),
    onSave: s.save,
  );
  c.todayOverride = todayOverride;
  c.grades = {
    for (final e in s.grades().entries)
      if (e.value is List) e.key: List<Object?>.of(e.value as List),
  };
  c.quarterlyMarks = s.quarterlyMarks();
  final presetId = '${s.get('school_preset_id', '')}';
  c.presetBands = core.presetMarksBands(presetId);
  final preset = core.getPreset(presetId);
  c.presetTitle = preset != null ? core.presetTitle(preset, lang) : '';
  c.demoMode = s.demoMode;
  c.selectedSubject = s.marksSelected;
  c.editingKey = s.marksEditing;
  c.predictions.addAll(_clonePredictions(s.marksPredictions));
  c.calcInputs.addAll({
    for (final e in s.marksCalcStore.entries)
      e.key: Map<String, String>.of(e.value),
  });
  c.drafts.addAll(s.drafts);

  c.onDraftsChanged = () {
    s.drafts
      ..clear()
      ..addAll(c.drafts);
  };

  c.addListener(() {
    final prevSelected = s.marksSelected;
    final prevPreds = s.marksPredictions.toString();
    s.marksSelected = c.selectedSubject;
    s.marksEditing = c.editingKey;
    s.marksPredictions
      ..clear()
      ..addAll(_clonePredictions(c.predictions));
    s.marksCalcStore
      ..clear()
      ..addAll({
        for (final e in c.calcInputs.entries)
          e.key: Map<String, String>.of(e.value),
      });
    s.drafts
      ..clear()
      ..addAll(c.drafts);
    if (c.selectedSubject != null && c.selectedSubject != prevSelected) {
      s.tutorialEvent('marks_subject_opened');
    }
    if (s.marksPredictions.isNotEmpty &&
        s.marksPredictions.toString() != prevPreds) {
      s.tutorialEvent('marks_predicted');
    }
    s.onChanged();
  });

  return c;
}

/// Live Riverpod-backed Marks screen.
class LiveMarksView extends ConsumerWidget {
  final AppTokens tokens;
  final bool narrow;

  const LiveMarksView({
    super.key,
    required this.tokens,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final controller = marksControllerFor(s);
    if (controller.grades.isNotEmpty) {
      s.tutorialOffer('marks');
    }
    return MarksView(
      controller: controller,
      tokens: tokens,
      narrow: narrow,
    );
  }
}
