// Interactive tutorial progress (which tour, which step).
//
// Port of strakalari/flet_ui/state_tutorial.py (`TutorialMixin`). The
// tours themselves live in `tutorial/tours.dart`; this file only tracks
// progress: the active `(tour id, step)` in memory and the finished ids
// in config (`tutorials_done`), plus the global `tutorials_enabled`
// switch.
//
// Every method is null-safe on partially-initialized doubles: test
// stand-ins that bypass the constructor keep working, mirroring the
// `getattr`-safe Python original.
part of 'app_state.dart';

/// Tutorial progress logic. Port of `TutorialMixin`.
extension TutorialLogic on AppState {
  // -- config ------------------------------------------------------------
  bool tutorialsEnabled() {
    try {
      return get('tutorials_enabled', true) != false;
    } catch (_) {
      return true;
    }
  }

  Set<String> tutorialsDone() {
    final done = Set<String>.of(tutorialsDoneSession);
    try {
      final stored = get('tutorials_done', []);
      if (stored is List) {
        done.addAll([
          for (final t in stored)
            if ('$t'.trim().isNotEmpty) '$t',
        ]);
      }
    } catch (_) {
      // Stored progress unreadable: session set stands.
    }
    return done;
  }

  /// Marks a tour finished/skipped for good (this session even when the
  /// config write fails, so a failed save never loops the tour).
  /// Port of `_remember_tutorial_done()`.
  void rememberTutorialDone(String tourId, bool quiet) {
    tutorialsDoneSession.add(tourId);
    final stored = tutorialsDone()..add(tourId);
    final update = {
      'tutorials_done': stored.toList()..sort(),
    };
    try {
      if (quiet) {
        saveQuiet(update);
      } else {
        save(update);
      }
    } catch (_) {
      // Progress only, never fatal.
    }
  }

  bool setTutorialsEnabled(bool enabled) {
    if (!enabled) tutorial = null;
    return save({'tutorials_enabled': enabled});
  }

  /// Replays every tour (each shows again when its moment comes).
  bool resetTutorials() {
    tutorialsDoneSession = {};
    tutorial = null;
    return save({
      'tutorials_done': <String>[],
      'tutorials_enabled': true,
    });
  }

  // -- progress ------------------------------------------------------------
  /// `(tour, index, step)` of the active tour, or null. A stale id clears itself.
  /// Port of `tutorial_current()`.
  (Tour, int, TourStep)? tutorialCurrent() {
    final active = tutorial;
    if (active == null) return null;
    final (tourId, index) = active;
    final tour = tours[tourId];
    if (tour == null || index < 0 || index >= tour.steps.length) {
      tutorial = null;
      return null;
    }
    return (tour, index, tour.steps[index]);
  }

  /// Called by the Shell before building a screen.
  ///
  /// Suspends a tour that belongs to another screen (it restarts when its
  /// moment comes again) and offers the first-run tour.
  /// Port of `tutorial.begin()`.
  void tutorialBegin(String route) {
    tutorialAnchored = false;
    final current = tutorialCurrent();
    if (current != null && current.$1.route != null && current.$1.route != route) {
      tutorialSuspend();
    }
    tutorialOffer(firstTourId);
  }

  bool _plannerStripUnavailable() {
    if (timetable().isEmpty) return true;
    try {
      final yp = yearPlan();
      final term = yp.term(plannerTerm) ?? yp.defaultTerm;
      return term == null;
    } catch (_) {
      return true;
    }
  }

  bool tutorialStepSkipped(TourStep step) {
    if (step.key == 'marks_scale') return hasPresetScale;
    if (step.key == 'plan_strip') return _plannerStripUnavailable();
    if (step.key == 'plan_pick') {
      if (_plannerStripUnavailable()) return true;
      try {
        final yp = yearPlan();
        final term = yp.term(plannerTerm) ?? yp.defaultTerm;
        return term == null || term.recommended.isEmpty;
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  List<int> tutorialVisibleStepIndices(Tour tour) => [
        for (var i = 0; i < tour.steps.length; i++)
          if (!tutorialStepSkipped(tour.steps[i])) i,
      ];

  /// Starts [tourId] when nothing else runs and it was never done.
  /// Views call it while rendering (the moment the tour's content is
  /// on screen), so it never emits. Port of `tutorial_offer()`.
  bool tutorialOffer(String tourId) {
    final active = tutorial;
    if (active != null) return active.$1 == tourId;
    if (!tutorialsEnabled()) return false;
    if (tutorialsDone().contains(tourId) || !tourExists(tourId)) {
      return false;
    }
    if (tourId != firstTourId && !tutorialsDone().contains(firstTourId)) {
      return false; // the welcome tour always comes first
    }
    final tour = tours[tourId]!;
    var start = 0;
    while (start < tour.steps.length &&
        tutorialStepSkipped(tour.steps[start])) {
      start++;
    }
    if (start >= tour.steps.length) return false;
    tutorial = (tourId, start);
    return true;
  }

  /// Drops the active tour WITHOUT marking it done (it is offered
  /// again, from its first step, the next time its moment comes).
  void tutorialSuspend() {
    tutorial = null;
  }

  void tutorialGoto(int index, [bool quiet = false]) {
    final current = tutorialCurrent();
    if (current == null) return;
    final (tour, _, _) = current;
    var next = index < 0 ? 0 : index;
    while (next < tour.steps.length &&
        tutorialStepSkipped(tour.steps[next])) {
      next++;
    }
    if (next >= tour.steps.length) {
      tutorial = null;
      rememberTutorialDone(tour.id, quiet);
      if (!quiet) _emit();
      return;
    }
    tutorial = (tour.id, next);
    if (!quiet) _emit();
  }

  void tutorialNext() {
    final current = tutorialCurrent();
    if (current != null) tutorialGoto(current.$2 + 1);
  }

  void tutorialBack() {
    final current = tutorialCurrent();
    if (current == null) return;
    final (tour, idx, _) = current;
    var prev = idx - 1;
    while (prev >= 0 && tutorialStepSkipped(tour.steps[prev])) {
      prev--;
    }
    if (prev >= 0) tutorialGoto(prev);
  }

  /// Ends the active tour for good ("Skip tutorial").
  void tutorialSkip() {
    final current = tutorialCurrent();
    if (current == null) return;
    tutorial = null;
    rememberTutorialDone(current.$1.id, false);
    _emit();
  }

  /// The user just did [name] (e.g. sent an excuse). Advances the active
  /// tour past the first remaining step waiting for it. Never emits:
  /// the state action firing it repaints anyway. Port of
  /// `tutorial_event()`.
  void tutorialEvent(String name) {
    (Tour, int, TourStep)? current;
    try {
      current = tutorialCurrent();
    } catch (_) {
      return;
    }
    if (current == null) return;
    final (tour, index, _) = current;
    for (var later = index; later < tour.steps.length; later++) {
      if (tour.steps[later].until == name) {
        tutorialGoto(later + 1, true);
        return;
      }
    }
  }
}

/// Riverpod facade for tutorial UI (phase 6 bubbles read these).
class TutorialController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final tutorialControllerProvider =
    NotifierProvider<TutorialController, AppState>(TutorialController.new);
