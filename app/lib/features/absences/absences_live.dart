// Live wiring of the Absences screen to the shared AppState.
//
// Port of the glue in strakalari/flet_ui/views/absences.py (`build`):
// reads `subjectStates()` and `yearPlan().defaultTerm.budgetByCanon`
// from `AppState` and passes them into `AbsencesView`.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/app_state.dart';

import '../common/app_tokens.dart';
import 'absences_controller.dart';
import 'absences_view.dart';

/// Builds a snapshot [AbsencesController] from the shared [AppState].
AbsencesController absencesControllerFor(AppState s) {
  final c = AbsencesController();
  c.demoMode = s.demoMode;
  c.updatedLabel = s.updatedLabel;
  final (states, _) = s.subjectStates();
  c.subjects = [
    for (final st in states)
      SubjectAbsence(
        name: st.name,
        currentPct: st.currentPct,
        status: st.status,
        limitPct: st.limitPct,
        effectivePlanLimit: st.effectivePlanLimit,
        effectivePlanSafe: st.effectivePlanSafe,
      ),
  ];
  try {
    final term = s.yearPlan().defaultTerm;
    if (term != null && term.hasData) {
      c.budgets = {
        for (final e in term.budgetByCanon.entries)
          e.key: SubjectBudget(
            freeHours: e.value.freeHours,
            planned: e.value.planned,
            projectedPct: e.value.projectedPct,
          ),
      };
    }
  } catch (_) {
    c.budgets = null;
  }
  return c;
}

/// The Absences route: rebuilds whenever the shared state emits.
class LiveAbsencesView extends ConsumerWidget {
  final AppTokens? tokens;
  final bool narrow;

  const LiveAbsencesView({
    super.key,
    this.tokens,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    final tok = tokens ?? s.appTokens;
    s.tutorialOffer('absences');
    return AbsencesView(
      controller: absencesControllerFor(s),
      tokens: tok,
      narrow: narrow,
    );
  }
}
