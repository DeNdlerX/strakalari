// Interactive tutorial tours: short guided tours shown the first time
// something appears (the first pending excuse, the first lunch menu, …).
//
// Port of strakalari/flet_ui/tutorial.py (data + placement vocabulary).
// Rendering (anchors, bubbles, the Shell layer) lands in phase 6; the
// progress bookkeeping already lives in controllers/tutorial.dart.
//
// Adding a tutorial for a new feature:
// 1. Add a [Tour] below (`route` = the screen it runs on).
// 2. Add its strings (`tut_<tour>_<n>_title` / `_body`) to strings.py.
// 3. In the view: `tutorialOffer(state, '<tour>')` when its content
//    exists, then wrap the relevant controls in anchors.
// 4. Optional: `tutorialEvent('<event>')` where the action succeeds.
import 'package:flutter/material.dart';

/// Where a step's bubble goes. `inline` = right below its anchor (the
/// Shell floats it bottom-right when the anchor is not on screen); the
/// rest float over the content area — `topLeft`/`topRight` under the
/// topbar, `headerRight` under a view header's actions.
enum TourPlace {
  inline,
  center,
  left,
  topLeft,
  topRight,
  headerRight,
  bottomRight,
}

const double bubbleWidth = 360;

/// Height of a view's header_row (title + "updated" line), for bubbles
/// pointing at its actions.
const double headerHeight = 46;

/// The welcome tour: offered by the Shell on every screen, and every
/// other tour waits until it was finished or skipped.
const String firstTourId = 'intro';

/// One callout bubble. `stringsKey` reads `tut_<key>_title` /
/// `tut_<key>_body` from the string table.
@immutable
class TourStep {
  final String stringsKey;
  final String anchor;
  final TourPlace place;
  final String until;
  final IconData icon;
  final bool welcome;

  const TourStep(
    this.stringsKey, {
    this.anchor = '',
    this.place = TourPlace.inline,
    this.until = '',
    this.icon = Icons.lightbulb_outline,
    this.welcome = false,
  });
}

@immutable
class Tour {
  final String id;
  final String? route;
  final List<TourStep> steps;

  const Tour(this.id, this.route, this.steps);
}

/// All tours, keyed by id. Port of `TOURS`.
const Map<String, Tour> tours = {
  'intro': Tour('intro', null, [
    TourStep('intro_welcome',
        place: TourPlace.center,
        icon: Icons.school_outlined,
        welcome: true),
    TourStep('intro_nav',
        place: TourPlace.left, icon: Icons.menu_outlined),
    TourStep('intro_refresh',
        anchor: 'refresh',
        place: TourPlace.topRight,
        icon: Icons.refresh),
    TourStep('intro_status',
        anchor: 'status',
        place: TourPlace.topLeft,
        icon: Icons.monitor_heart_outlined),
    TourStep('intro_done',
        place: TourPlace.bottomRight, icon: Icons.task_alt),
  ]),
  'excuse': Tour('excuse', 'today', [
    TourStep('excuse_pick',
        anchor: 'excuse_card', icon: Icons.event_busy_outlined),
    TourStep('excuse_send',
        anchor: 'excuse_card',
        until: 'excuse_done',
        icon: Icons.send_outlined),
    TourStep('excuse_done',
        place: TourPlace.bottomRight, icon: Icons.task_alt),
  ]),
  'timetable': Tour('timetable', 'timetable', [
    TourStep('tt_weeks',
        anchor: 'tt_nav', icon: Icons.date_range_outlined),
    TourStep('tt_colors',
        anchor: 'tt_legend', icon: Icons.palette_outlined),
  ]),
  'absences': Tour('absences', 'absences', [
    TourStep('abs_stats',
        anchor: 'abs_stats', icon: Icons.pie_chart_outline),
    TourStep('abs_subject', anchor: 'abs_first', icon: Icons.percent),
  ]),
  'planner': Tour('planner', 'planner', [
    TourStep('plan_strip',
        anchor: 'plan_strip', icon: Icons.calendar_month_outlined),
    TourStep('plan_pick',
        anchor: 'plan_first',
        until: 'day_planned',
        icon: Icons.beach_access_outlined),
    TourStep('plan_budget',
        anchor: 'plan_budget', icon: Icons.stacked_bar_chart),
  ]),
  'lunches': Tour('lunches', 'lunches', [
    TourStep('lunch_pick',
        anchor: 'lunch_day',
        until: 'lunch_picked',
        icon: Icons.restaurant_outlined),
    TourStep('lunch_send',
        anchor: 'lunch_send',
        until: 'orders_sent',
        icon: Icons.send_outlined),
    TourStep('lunch_tools',
        anchor: 'lunch_tools',
        place: TourPlace.headerRight,
        icon: Icons.tune_outlined),
  ]),
  'marks': Tour('marks', 'marks', [
    TourStep('marks_stats',
        anchor: 'marks_stats', icon: Icons.grade_outlined),
    TourStep('marks_subject',
        anchor: 'marks_subject',
        until: 'marks_subject_opened',
        icon: Icons.touch_app_outlined),
    TourStep('marks_need', anchor: 'marks_need', icon: Icons.flag_outlined),
    TourStep('marks_predict',
        anchor: 'marks_predict',
        until: 'marks_predicted',
        icon: Icons.science_outlined),
    TourStep('marks_scale',
        anchor: 'marks_scale',
        place: TourPlace.headerRight,
        icon: Icons.percent),
  ]),
  'settings': Tour('settings', 'settings', [
    TourStep('settings_intro',
        place: TourPlace.bottomRight, icon: Icons.settings_outlined),
  ]),
  'activity': Tour('activity', 'activity', [
    TourStep('activity_intro',
        place: TourPlace.bottomRight, icon: Icons.history_outlined),
  ]),
};

/// Lookup helpers used by controllers/tutorial.dart (kept here so the
/// controller library never imports Flutter widgets itself).
bool tourExists(String tourId) => tours.containsKey(tourId);

int tourStepCount(String tourId) => tours[tourId]?.steps.length ?? 0;

String tourStepUntil(String tourId, int index) {
  final steps = tours[tourId]?.steps ?? const <TourStep>[];
  if (index < 0 || index >= steps.length) return '';
  return steps[index].until;
}

/// Per-render bookkeeping: which tour (if any) a route offers.
/// Port of tutorial.begin()/offer() offer-side (no Flet).
String? tutorialForRoute(String route, Set<String> done) {
  for (final tour in tours.values) {
    if (tour.route == route && !done.contains(tour.id)) return tour.id;
  }
  return null;
}
