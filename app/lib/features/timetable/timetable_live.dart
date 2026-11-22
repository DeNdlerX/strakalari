// Bridges [AppState] (Riverpod) to [TimetableController] / [TimetableView].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/app_state.dart';

import '../common/app_tokens.dart';
import 'timetable_controller.dart';
import 'timetable_view.dart';

/// Builds a [TimetableController] populated from [s] and wired so
/// week navigation, view toggles and expanded day cards mutate [s].
TimetableController timetableControllerFor(AppState s) {
  final c = TimetableController();
  c.timetable = {
    for (final e in s.timetable().entries)
      e.key: List<Object?>.of(e.value),
  };
  c.stableBaseline = s.stableBaseline();
  c.stableComplete = s.stableComplete();
  c.demoMode = s.demoMode;
  c.timetableMondayIso = s.timetableMondayIso;
  c.timetableView = s.timetableView == 'list' ? 'list' : 'table';
  c.showStableTimetable = s.showStableTimetable;
  c.expandedDays.addAll(s.expandedDays);

  c.goTimetableWeekHook = s.goTimetableWeek;
  c.setTimetableViewHook = s.setTimetableView;
  c.setShowStableHook = s.setShowStable;
  c.setDayExpandedHook = s.setDayExpanded;
  return c;
}

/// Live Riverpod-backed Timetable screen.
class LiveTimetableView extends ConsumerWidget {
  final AppTokens? tokens;
  final bool narrow;
  final DateTime? now;

  const LiveTimetableView({
    super.key,
    this.tokens,
    this.narrow = false,
    this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final tok = tokens ?? s.appTokens;
    final controller = timetableControllerFor(s);
    if (controller.weeks().isNotEmpty) {
      s.tutorialOffer('timetable');
    }
    return TimetableView(
      controller: controller,
      tokens: tok,
      narrow: narrow,
      now: now,
      updatedLabel: s.updatedLabelFor('timetable'),
    );
  }
}
