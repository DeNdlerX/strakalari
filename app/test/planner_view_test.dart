import 'package:app/features/common/app_tokens.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/features/planner/plan_reserve.dart' show daysText;
import 'package:clock/clock.dart';
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

YearPlanData _plan([Set<DateTime> planned = const {}]) {
  final term = TermPlanData(
    key: 'sem1',
    start: DateTime(2026, 9, 1),
    close: DateTime(2027, 1, 25),
    capacity: 5,
    hasData: true,
    active: true,
    remainingDays: [DateTime(2026, 10, 5)],
    plannedDates: planned,
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

YearPlanData _planWithPicks(List<DateTime> pickDays) {
  final term = TermPlanData(
    key: 'sem1',
    start: DateTime(2026, 9, 1),
    close: DateTime(2027, 1, 25),
    capacity: pickDays.length,
    hasData: true,
    active: true,
    remainingDays: pickDays,
    budgets: const [
      BudgetRowData(
        name: 'Matematika',
        missed: 2,
        planned: 0,
        free: 8,
        buffer: 2,
        schoolCap: 12,
        schoolLeft: 10,
        projectedPct: 16.0,
        limitPct: 25.0,
        status: 'ok',
      ),
    ],
    recommended: [
      for (final d in pickDays)
        DayOptionData(
          day: d,
          lessonsCount: 5,
          cost: 5,
          budgetHours: 5,
          lessons: const ['Matematika'],
        ),
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
      await t.tap(find.text(Strings.get('confirm')));
      await t.pump();
      expect(saved, -1.0);
      expect(SnackLog.last, Strings.get('save_failed'));
      // Valid: saved and closed.
      await t.enterText(find.byType(TextField), '7,5');
      await t.tap(find.text(Strings.get('confirm')));
      await t.pump();
      expect(saved, 7.5);
    });

    testWidgets('empty state without timetable', (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: null,
        hasTimetable: false,
        hasData: false,
      )));
      expect(find.text(Strings.get('no_data')), findsOneWidget);
      expect(find.text(Strings.get('planner_need_refresh')), findsOneWidget);
    });

    testWidgets('empty state asks for credentials when timetable exists',
        (t) async {
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: null,
        hasTimetable: true,
        hasData: false,
        demoMode: true,
      )));
      expect(find.text(Strings.get('need_credentials')), findsOneWidget);

      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: null,
        hasTimetable: true,
        hasData: false,
        demoMode: false,
      )));
      expect(find.text(Strings.get('no_data')), findsOneWidget);
      expect(find.text(Strings.get('need_credentials')), findsNothing);
    });

    testWidgets('year plan renders stats, calendar, budgets, planned',
        (t) async {
      _setViewport(t);
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      expect(find.text(Strings.get('planner_title')), findsOneWidget);
      expect(find.byKey(const Key('plan:summary')), findsOneWidget);
      expect(find.text(Strings.get('section_overview').toUpperCase()),
          findsOneWidget);
      // Below the fold: ListView builds lazily, so scroll first.
      await t.scrollUntilVisible(
          find.textContaining(Strings.get('section_plan').toUpperCase()), 300);
      expect(find.textContaining(Strings.get('section_plan').toUpperCase()),
          findsOneWidget);
    });

    // Checkpoint B BR-M4: planner.py `_target_dropdown`.
    for (final planned in [
      <DateTime>{},
      {DateTime(2026, 10, 5)},
    ]) {
      testWidgets('target dropdown offers the capacity (${planned.length} planned)',
          (t) async {
        _setViewport(t);
        final maximum = 5 + planned.length;
        final c = _controller();
        await t.pumpWidget(_app(PlannerPage(
          controller: c,
          tokens: AppTokens.dark(),
          plan: _plan(planned),
          hasTimetable: true,
          hasData: true,
        )));
        await t.scrollUntilVisible(
            find.textContaining(Strings.get('section_plan').toUpperCase()), 300);
        final auto = Strings.format('target_auto', {'n': maximum});
        expect(find.text(auto), findsOneWidget);
        await t.tap(find.text(auto));
        await t.pumpAndSettle();
        expect(find.text(daysText(maximum)), findsWidgets);
        expect(find.text(daysText(maximum + 1)), findsNothing);
      });
    }

    testWidgets('plan dialog confirm plans the day', (t) async {
      _setViewport(t);
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      // Open the recommend-row plan button.
      await t.scrollUntilVisible(find.text(Strings.get('plan_skip')).first, 300);
      await t.tap(find.text(Strings.get('plan_skip')).first);
      await t.pumpAndSettle();
      expect(find.text(Strings.get('choose_template')), findsOneWidget);
      await t.tap(find.text(Strings.get('confirm')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
      expect(SnackLog.last, Strings.get('skip_planned'));
    });

    testWidgets('plan dialog cancel closes without planning', (t) async {
      _setViewport(t);
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      await t.scrollUntilVisible(find.text(Strings.get('plan_skip')).first, 300);
      await t.tap(find.text(Strings.get('plan_skip')).first);
      await t.pumpAndSettle();
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, isEmpty);
    });

    testWidgets('plan-all dialog plans recommended days', (t) async {
      _setViewport(t);
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      await t.scrollUntilVisible(find.textContaining(Strings.get('plan_all')).first, 300);
      await t.tap(find.textContaining(Strings.get('plan_all')).first);
      await t.pumpAndSettle();
      await t.tap(find.text(Strings.get('confirm')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
    });

    testWidgets('planned entry can be unplanned', (t) async {
      // The entry is for 5 Oct 2026: before that day it can still be undone
      // (a past day shows the 'passed' badge instead, like planner.py).
      await withClock(Clock.fixed(DateTime(2026, 9, 20)), () async {
      _setViewport(t);
      final c = _controller();
      c.planSkip('2026-10-05', 'Omluvte absenci.');
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
      )));
      final unplan = find.text(Strings.get('unplan'));
      await t.scrollUntilVisible(unplan, 300);
      expect(find.textContaining('05.10.2026'), findsWidgets);
      await t.tap(unplan.first);
      await t.pump();
      expect(c.plannedSkips, isEmpty);
      expect(SnackLog.last, Strings.get('plan_removed'));
    });
    });

    testWidgets('a planned entry in the past shows the passed badge',
        (t) async {
      await withClock(Clock.fixed(DateTime(2026, 11, 11)), () async {
        _setViewport(t);
        final c = _controller();
        c.planSkip('2026-10-05', 'Omluvte absenci.');
        await t.pumpWidget(_app(PlannerPage(
          controller: c,
          tokens: AppTokens.dark(),
          plan: _plan(),
          hasTimetable: true,
          hasData: true,
        )));
        await t.scrollUntilVisible(find.text(Strings.get('day_passed')), 300);
        expect(find.text(Strings.get('day_passed')), findsOneWidget);
        expect(find.text(Strings.get('unplan')), findsNothing);
      });
    });

    testWidgets('custom picker taps a day whole and confirms', (t) async {
      _setViewport(t);
      final c = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _plan(),
        hasTimetable: true,
        hasData: true,
        lessonsFor: (_) => const [
          PickerSlot(period: 1, subject: 'M'),
          PickerSlot(period: 2, subject: 'F'),
        ],
      )));
      await t.tap(find.byKey(const Key('plan:multi_toggle')));
      await t.pumpAndSettle();
      // Multi-confirm is absent before any day is picked.
      expect(find.byKey(const Key('plan:multi_confirm')), findsNothing);
      // Tap a future weekday cell in September 2026 (Tue 29 Sep, after today 26 Sep).
      await t.tap(find.byKey(const ValueKey('day_2026_9_29')));
      await t.pumpAndSettle();
      final multiConfirm = find.byKey(const Key('plan:multi_confirm'));
      expect(multiConfirm, findsOneWidget);
      expect(t.widget<FilledButton>(multiConfirm).onPressed, isNotNull);
      await t.tap(multiConfirm);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
      await t.pumpAndSettle();
      expect(c.plannedSkips, hasLength(1));
      expect(SnackLog.last, Strings.get('skip_planned_keep_lunch'));
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

    testWidgets('recommended list shows the next 3 days and opens to all',
        (t) async {
      t.view.physicalSize = const Size(1280, 2000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final fiveDays = [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
      ];
      var hookCalls = 0;
      final c = _controller()
        ..toggleShowAllPicksHook = () => hookCalls++;

      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: _planWithPicks(fiveDays),
        hasTimetable: true,
        hasData: true,
      )));
      await t.pump();

      // Heading and Plan all cover all 5 picks; only 3 cards shown initially.
      expect(
        find.text('${Strings.get('section_plan')} (5)'.toUpperCase()),
        findsOneWidget,
      );
      expect(find.text('${Strings.get('plan_all')} (5)'), findsOneWidget);
      expect(find.text(Strings.get('plan_skip')), findsNWidgets(3));
      expect(
        find.text(Strings.format('plan_show_all', {'n': 5})),
        findsOneWidget,
      );
      // plan_explain is dropped from the screen.
      expect(
        find.textContaining('rozložené rovnoměrně až do uzávěrky'),
        findsNothing,
      );
      expect(
        find.textContaining('spread evenly up to the closure'),
        findsNothing,
      );

      // Plan all opens PlanAllDialog with all 5 days even when collapsed.
      await t.tap(find.text('${Strings.get('plan_all')} (5)'));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('02.11.2026'),
        ),
        findsOneWidget,
      );
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      // Tapping Show all (5) opens to all 5 cards through the controller hook.
      await t.tap(find.text(Strings.format('plan_show_all', {'n': 5})));
      await t.pumpAndSettle();
      expect(hookCalls, 1);
      expect(find.text(Strings.get('plan_skip')), findsNWidgets(5));
      expect(find.text(Strings.get('plan_show_less')), findsOneWidget);
      expect(
        find.text('${Strings.get('section_plan')} (5)'.toUpperCase()),
        findsOneWidget,
      );

      // Plan all still covers all 5 days when expanded.
      await t.tap(find.text('${Strings.get('plan_all')} (5)'));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('02.11.2026'),
        ),
        findsOneWidget,
      );
      await t.tap(find.text(Strings.get('cancel')));
      await t.pumpAndSettle();

      // With exactly 3 picks, all 3 cards show and there is no toggle button.
      final c3 = _controller();
      await t.pumpWidget(_app(PlannerPage(
        controller: c3,
        tokens: AppTokens.dark(),
        plan: _planWithPicks(fiveDays.take(3).toList()),
        hasTimetable: true,
        hasData: true,
      )));
      await t.pump();
      expect(find.text(Strings.get('plan_skip')), findsNWidgets(3));
      expect(
        find.text(Strings.format('plan_show_all', {'n': 3})),
        findsNothing,
      );
      expect(find.text(Strings.get('plan_show_less')), findsNothing);
    });

    testWidgets(
        'P9a+b narrow planner equalizes KPI card heights and keeps calendar visible on first screen',
        (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final savedLang = Strings.lang;
      addTearDown(() => Strings.lang = savedLang);
      Strings.lang = 'cs';

      final sem1 = TermPlanData(
        key: 'sem1',
        start: DateTime(2026, 9, 1),
        close: DateTime(2027, 1, 25),
        capacity: 13,
        hasData: true,
        active: true,
        remainingDays: [
          for (var i = 0; i < 41; i++)
            DateTime(2026, 11, 16).add(Duration(days: i)),
        ],
        fastPace: const ['Fyzika', 'Tělesná výchova'],
        tightest: const TightestData(
          name: 'Tělesná výchova',
          free: 4,
          status: 'warning',
        ),
      );
      final sem2 = TermPlanData(
        key: 'sem2',
        start: DateTime(2027, 1, 26),
        close: DateTime(2027, 4, 26),
        capacity: 10,
        hasData: true,
        active: false,
      );
      final yearPlan = YearPlanData(
        today: DateTime(2026, 11, 15),
        firstDay: DateTime(2026, 11, 16),
        terms: [sem1, sem2],
        lessonsOn: (_) => 6,
      );

      final tok = AppTokens.dark();
      final c = _controller();
      await t.pumpWidget(MaterialApp(
        theme: tok.toThemeData(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: PlannerPage(
              controller: c,
              tokens: tok,
              plan: yearPlan,
              hasTimetable: true,
              hasData: true,
              narrow: true,
            ),
          ),
        ),
      ));
      await t.pump();

      final sem1Btn = find.textContaining('1. pololetí');
      final sem2Btn = find.textContaining('2. pololetí');
      expect((t.getCenter(sem1Btn).dy - t.getCenter(sem2Btn).dy).abs(),
          lessThan(4));

      // Calendar section header fits well inside the ~708 px phone body.
      final calHeader = find.text(Strings.get('section_overview').toUpperCase());
      expect(calHeader, findsOneWidget);
      expect(t.getBottomLeft(calHeader).dy, lessThan(708));
    });

    testWidgets(
        'S2 cross-term calendar: paging back to December while sem2 is selected in November keeps sem1 days tappable',
        (t) async {
      _setViewport(t);
      final decDay = DateTime(2026, 12, 10);
      final sem1 = TermPlanData(
        key: 'sem1',
        start: DateTime(2026, 9, 1),
        close: DateTime(2027, 1, 25),
        capacity: 5,
        hasData: true,
        active: true,
        options: {
          decDay: DayOptionData(
            day: decDay,
            lessonsCount: 5,
            cost: 5,
            budgetHours: 5,
            feasible: true,
          ),
        },
      );
      final sem2 = TermPlanData(
        key: 'sem2',
        start: DateTime(2027, 1, 26),
        close: DateTime(2027, 4, 26),
        capacity: 8,
        hasData: true,
        active: false,
      );
      final yp = YearPlanData(
        today: DateTime(2026, 11, 15),
        firstDay: DateTime(2026, 11, 16),
        terms: [sem1, sem2],
        lessonsOn: (_) => 5,
      );
      final c = _controller()..plannerTerm = 'sem2';
      await t.pumpWidget(_app(PlannerPage(
        controller: c,
        tokens: AppTokens.dark(),
        plan: yp,
        hasTimetable: true,
        hasData: true,
      )));
      await t.pumpAndSettle();

      // sem2 opens in Jan 2027; tap prev_month once -> Dec 2026 (owned by sem1).
      await t.tap(find.byKey(const Key('cal:prev_month')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('day_2026_12_10')));
      await t.pumpAndSettle();
      expect(find.byType(PlanDayDialog), findsOneWidget);
    });
  });
}

Widget _w(Widget child) => MaterialApp(home: Scaffold(body: child));

void _setViewport(WidgetTester t) {
  t.view.physicalSize = const Size(1280, 1024);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Widget _app(Widget child) {
  SnackLog.clear();
  return MaterialApp(
    theme: AppTokens.dark().toThemeData(),
    home: Scaffold(body: child),
  );
}
