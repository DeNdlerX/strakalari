import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/planner/planner_controller.dart';
import 'package:app/features/planner/planner_view.dart';
import 'package:app/widgets/overlays.dart';

PlannerController _controller([Map<String, dynamic>? config]) {
  final c = PlannerController(
    config ??
        {
          'absence_plan_reserve_pct': 10.0,
          'planner_target_days': 0,
          'long_absence_excuses': ['Omluvte absenci.'],
        },
  );
  c.stravaEnabled = false;
  return c;
}

YearPlanData _plan() {
  final term = TermPlanData(
    key: 'sem1',
    start: DateTime(2026, 9, 1),
    close: DateTime(2027, 1, 25),
    capacity: 5,
    hasData: true,
    active: true,
    remainingDays: [DateTime(2026, 10, 5)],
    budgets: const [
      BudgetRowData(
          name: 'Matematika',
          missed: 2,
          planned: 1,
          free: 4,
          buffer: 2,
          schoolCap: 10,
          schoolLeft: 8,
          projectedPct: 20.0,
          limitPct: 25.0,
          status: 'ok'),
    ],
    recommended: [
      DayOptionData(
          day: DateTime(2026, 10, 5),
          lessonsCount: 5,
          cost: 5,
          budgetHours: 5,
          tags: const ['long_weekend']),
    ],
  );
  return YearPlanData(
    today: DateTime(2026, 9, 26),
    firstDay: DateTime(2026, 9, 28),
    terms: [term],
    lessonsOn: (_) => 5,
  );
}

void main() {
  group('planner_view', () {
    testWidgets('reserve dialog saves valid values only', (t) async {
      var saved = -1.0;
      SnackLog.clear();
      await t.pumpWidget(_w(ReserveDialog(
          current: 10.0, onSave: (v) => saved = v)));
      // Invalid: nothing saved, error toast.
      await t.enterText(find.byType(TextField), 'lots');
      await t.tap(find.text(Str.t('confirm')));
      await t.pump();
      expect(saved, -1.0);
      expect(SnackLog.last, Str.t('save_failed'));
      // Valid: saved and closed.
      await t.enterText(find.byType(TextField), '7,5');
      await t.tap(find.text(Str.t('confirm')));
      await t.pump();
      expect(saved, 7.5);
    });

    testWidgets('empty state without timetable', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: null,
        hasTimetable: false,
        updatedLabel: 'never',
      )));
      expect(find.text(Str.t('no_data')), findsOneWidget);
      expect(find.text(Str.t('planner_need_refresh')), findsOneWidget);
    });

    testWidgets('empty state asks for credentials when timetable exists',
        (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: null,
        hasTimetable: true,
      )));
      expect(find.text(Str.t('need_credentials')), findsOneWidget);
    });

    testWidgets('year plan renders stats, calendar, budgets, planned',
        (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
        updatedLabel: 'now',
      )));
      expect(find.text(Str.t('planner_title')), findsWidgets);
      expect(find.text(Str.t('section_overview')), findsOneWidget);
      // Below the fold: ListView builds lazily, so scroll first.
      await t.scrollUntilVisible(
          find.text(Str.t('section_budgets')), 300);
      expect(find.text(Str.t('section_budgets')), findsOneWidget);
      await t.scrollUntilVisible(
          find.textContaining(Str.t('section_plan')), 300);
      expect(find.textContaining(Str.t('section_plan')), findsOneWidget);
      // Intro carries the reserve note.
      expect(find.textContaining('10'), findsWidgets);
    });

    testWidgets('plan dialog confirm plans the day', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      // Open the recommend-row plan button.
      await t.tap(find.text(Str.t('plan_skip')).first);
      await t.pumpAndSettle();
      expect(find.text(Str.t('choose_template')), findsOneWidget);
      await t.tap(find.text(Str.t('confirm')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
      expect(SnackLog.last, Str.t('skip_planned'));
    });

    testWidgets('plan dialog cancel closes without planning', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      await t.tap(find.text(Str.t('plan_skip')).first);
      await t.pumpAndSettle();
      await t.tap(find.text(Str.t('cancel')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, isEmpty);
    });

    testWidgets('plan-all dialog plans recommended days', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      await t.tap(find.textContaining(Str.t('plan_all')).first);
      await t.pumpAndSettle();
      await t.tap(find.text(Str.t('confirm')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
    });

    testWidgets('planned entry can be unplanned', (t) async {
      final c = _controller();
      c.planSkip('2026-10-05', 'Omluvte absenci.');
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      expect(
          find.textContaining('05.10.2026'), findsWidgets);
      final unplan = find.text(Str.t('unplan'));
      await t.scrollUntilVisible(unplan, 300);
      await t.tap(unplan.first);
      await t.pump();
      expect(c.plannedSkips, isEmpty);
      expect(SnackLog.last, Str.t('plan_removed'));
    });

    testWidgets('custom picker taps a day whole and confirms', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerView(
        controller: c,
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
        lessonsFor: (_) => const [
          PickerSlot(period: 1, subject: 'M'),
          PickerSlot(period: 2, subject: 'F'),
        ],
      )));
      final view =
          t.widget<PlannerView>(find.byType(PlannerView));
      final ctx = t.element(find.byType(PlannerView));
      view.showCustomPlanDialog(ctx);
      await t.pumpAndSettle();
      // The dialog title shadows the view button: take the dialog one.
      expect(find.text(Str.t('plan_custom')), findsWidgets);
      // Confirm is disabled with nothing picked.
      final confirm = find.widgetWithText(FilledButton, Str.t('confirm'));
      expect(t.widget<FilledButton>(confirm).onPressed, isNull);
      // Tap the first visible weekday cell (day numbers vary by month;
      // weekends are not shown, so scan for an existing one).
      var tapped = false;
      for (var d = 10; d <= 28; d++) {
        final f = find.text('$d');
        if (f.evaluate().isNotEmpty) {
          await t.tap(f.first);
          tapped = true;
          break;
        }
      }
      expect(tapped, isTrue);
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(confirm).onPressed, isNotNull);
      await t.tap(confirm);
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
      expect(SnackLog.last, Str.t('skip_planned_keep_lunch'));
    });

    test('controller plan/unplan with failing persist rolls back', () {
      final c = PlannerController(
        {'absence_plan_reserve_pct': 10.0},
        persist: () => false,
      );
      expect(c.planSkip('2026-10-05', 'T'), isFalse);
      expect(c.plannedSkips, isEmpty);
      expect(c.plannerTargetDays(), 0);
      c.setPlannerTarget(7);
      expect(c.plannerTargetDays(), 7);
      c.setPlannerTarget(9999);
      expect(c.plannerTargetDays(), 200);
    });
  });
}

Widget _w(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget _app(Widget child) {
  SnackLog.clear();
  return MaterialApp(home: Scaffold(body: child));
}
