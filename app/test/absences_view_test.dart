import 'dart:io';

import 'package:app/controllers/app_state.dart' hide PlannerController;
import 'package:app/features/absences/absences_controller.dart';
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/absences/absences_view.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/planner/planner_controller.dart';
import 'package:app/features/planner/planner_view.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

/// Checkpoint B BR3-M2: Absences looks like `views/absences.py`:
/// the percentage right of every bar (`components.meter`, track 140 px),
/// the "updated" line under the title and stat values coloured by kind.
void main() {
  AbsencesController build() => AbsencesController()
    ..updatedLabel = 'Aktualizováno: dnes'
    ..subjects = const [
      SubjectAbsence(
          name: 'Matematika',
          currentPct: 21.43,
          status: 'warning',
          limitPct: 25,
          effectivePlanLimit: 25,
          effectivePlanSafe: 3),
      SubjectAbsence(
          name: 'Fyzika',
          currentPct: 5,
          status: 'ok',
          limitPct: 25,
          effectivePlanLimit: 25,
          effectivePlanSafe: 5),
    ];

  testWidgets('every row shows its percentage with one decimal',
      (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: AppTokens.dark()))));
    expect(find.text('21.4 %'), findsOneWidget);
    expect(find.text('5.0 %'), findsOneWidget);
    // The track is 140 px wide, like Python.
    final track = t.widgetList<SizedBox>(find.byType(SizedBox)).where(
        (b) => b.width == 140 && b.child is ClipRRect);
    expect(track, hasLength(2));
  });

  testWidgets('the updated line sits under the title', (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: AppTokens.dark()))));
    expect(find.text(Strings.get('absence_title')), findsOneWidget);
    expect(find.text('Aktualizováno: dnes'), findsOneWidget);
  });

  testWidgets('stat values are coloured by kind', (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final tok = AppTokens.dark();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AbsencesView(controller: build(), tokens: tok))));
    Color colorOf(String text) =>
        t.widget<Text>(find.text(text).first).style!.color!;
    // One warning subject, none critical: warning colour, then "ok" green.
    expect(colorOf('1'), statusColor('warning', tok));
    expect(colorOf('0'), statusColor('ok', tok));
    // The average is the accent colour (kind "info").
    expect(colorOf('13.2 %'), tok.accent);
  });

  testWidgets('P9a KPI stat cards in row share equal height on 390px phone',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final tok = AppTokens.dark();
    final savedLang = Strings.lang;
    addTearDown(() => Strings.lang = savedLang);
    Strings.lang = 'cs';

    await t.pumpWidget(MaterialApp(
      theme: tok.toThemeData(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: AbsencesView(controller: build(), tokens: tok),
        ),
      ),
    ));
    await t.pump();

    final cards = find.byType(StatCard);
    expect(cards, findsNWidgets(3));
    final heights = [
      for (var i = 0; i < 3; i++) t.getSize(cards.at(i)).height,
    ];
    expect(heights[0], greaterThan(0));
    expect(heights[1], heights[0]);
    expect(heights[2], heights[0]);
  });

  testWidgets(
      'F1 Absence tab shows no-limits hint and opens shared limits editor that saves to config',
      (t) async {
    final tmp = Directory.systemTemp.createTempSync('strakalari_abs_lim_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    core.setEnvironmentOverride(
        {'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
    Strings.lang = 'cs';

    final s = AppState(
      configData: {
        'language': 'cs',
        'tutorials_enabled': false,
        'subject_limits': <String, double>{},
        'absence_critical_pct': 25.0,
      },
      data: {
        'absence': {'Matematika': 10.0},
      },
    );

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => _SeededAbsAppState(s)),
        ],
        child: MaterialApp(
          theme: AppTokens.dark().toThemeData(),
          home: Scaffold(
            body: LiveAbsencesView(tokens: AppTokens.dark(), narrow: true),
          ),
        ),
      ),
    );
    await t.pump();

    expect(find.byKey(const Key('abs:limits_btn')), findsOneWidget);
    expect(find.byKey(const Key('abs:no_limits_banner')), findsOneWidget);
    expect(find.text('Všechny předměty mají výchozí limit 25 %.'),
        findsOneWidget);

    // Changing absence_critical_pct updates the displayed default limit.
    s.config.set('absence_critical_pct', 30.0);
    s.onChanged();
    await t.pump();
    expect(find.text('Všechny předměty mají výchozí limit 30 %.'),
        findsOneWidget);

    await t.tap(find.byKey(const Key('abs:no_limits_btn')));
    await t.pumpAndSettle();

    expect(find.byType(LimitsEditorContent), findsOneWidget);
    final matField = find.byKey(const Key('lim:subj:Matematika'));
    await t.ensureVisible(matField);
    await t.enterText(matField, '18');
    await t.tap(find.byKey(const Key('abs:limits_done')));
    await t.pumpAndSettle();

    expect(s.get('subject_limits'), {'Matematika': 18.0});
    expect(find.byKey(const Key('abs:no_limits_banner')), findsNothing);
    expect(find.byKey(const Key('abs:limits_btn')), findsOneWidget);
  });

  testWidgets(
      'F1b each subject renders once with badge precedence and Meter fallback without budget row',
      (t) async {
    t.view.physicalSize = const Size(1280, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final tok = AppTokens.dark();
    final abs = AbsencesController()
      ..subjects = const [
        // Absence critical beats budget ok -> state_critical.
        SubjectAbsence(
          name: 'Matematika',
          currentPct: 27.5,
          status: 'critical',
          limitPct: 25.0,
          effectivePlanLimit: 22.5,
          effectivePlanSafe: 0,
        ),
        // Tie warning (absence warning vs budget tight) -> budget_tight wins.
        SubjectAbsence(
          name: 'Fyzika',
          currentPct: 19.0,
          status: 'warning',
          limitPct: 25.0,
          effectivePlanLimit: 22.5,
          effectivePlanSafe: 2,
        ),
        // Subject without a budget row falls back to Meter + detail line.
        SubjectAbsence(
          name: 'Dějepis',
          currentPct: 10.0,
          status: 'ok',
          limitPct: 25.0,
          effectivePlanLimit: 22.5,
          effectivePlanSafe: 4,
        ),
      ];
    final term = TermPlanData(
      key: 'sem1',
      start: DateTime(2026, 9, 1),
      close: DateTime(2027, 1, 25),
      capacity: 4,
      hasData: true,
      active: true,
      remainingDays: [DateTime(2026, 10, 5)],
      budgets: const [
        BudgetRowData(
          name: '  matematika ',
          missed: 5,
          planned: 0,
          free: 3,
          buffer: 1,
          schoolCap: 10,
          schoolLeft: 5,
          projectedPct: 24.0,
          limitPct: 25.0,
          status: 'ok',
        ),
        BudgetRowData(
          name: 'Fyzika',
          missed: 4,
          planned: 1,
          free: 1,
          buffer: 1,
          schoolCap: 8,
          schoolLeft: 3,
          projectedPct: 22.0,
          limitPct: 25.0,
          status: 'tight',
        ),
      ],
    );
    final plan = YearPlanData(
      today: DateTime(2026, 9, 26),
      firstDay: DateTime(2026, 9, 28),
      terms: [term],
      lessonsOn: (_) => 5,
    );

    await t.pumpWidget(MaterialApp(
      theme: tok.toThemeData(),
      home: Scaffold(
        body: AbsencesView(
          controller: abs,
          tokens: tok,
          planner: PlannerController({}),
          plan: plan,
          hasTimetable: true,
        ),
      ),
    ));
    await t.pump();

    // 4 KPI cards in active term.
    expect(find.byType(StatCard), findsNWidgets(4));

    // Each subject appears exactly once (no duplicate budget/absence lists).
    expect(find.text('Matematika'), findsOneWidget);
    expect(find.text('Fyzika'), findsOneWidget);
    expect(find.text('Dějepis'), findsOneWidget);

    // Budget rows render projected % + budget lines + badge precedence.
    expect(find.text('27.5 %'), findsOneWidget);
    expect(find.text(Strings.get('state_critical')), findsOneWidget);
    expect(find.text(Strings.get('budget_tight')), findsOneWidget);
    expect(
      find.text(Strings.format('budget_final', {'p': '24.0', 'limit': 25.0})),
      findsOneWidget,
    );

    // Subject missing from term.budgets falls back to Meter (exactly 1 Meter).
    expect(find.byType(Meter), findsOneWidget);
    expect(find.text('10.0 %'), findsOneWidget);
  });

  testWidgets('F1b budget bar segments are drawn (R3b code M1)', (t) async {
    t.view.physicalSize = const Size(1280, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final tok = AppTokens.dark();
    final abs = AbsencesController()
      ..subjects = const [
        SubjectAbsence(
          name: 'Matematika',
          currentPct: 12.0,
          status: 'ok',
          limitPct: 25.0,
          effectivePlanLimit: 22.5,
          effectivePlanSafe: 4,
        ),
      ];
    final term = TermPlanData(
      key: 'sem1',
      start: DateTime(2026, 9, 1),
      close: DateTime(2027, 1, 25),
      capacity: 4,
      hasData: true,
      active: true,
      remainingDays: [DateTime(2026, 10, 5)],
      budgets: const [
        BudgetRowData(
          name: 'Matematika',
          missed: 4,
          planned: 2,
          free: 3,
          buffer: 1,
          schoolCap: 10,
          schoolLeft: 5,
          projectedPct: 20.0,
          limitPct: 25.0,
          status: 'ok',
        ),
      ],
    );
    await t.pumpWidget(MaterialApp(
      theme: tok.toThemeData(),
      home: Scaffold(
        body: AbsencesView(
          controller: abs,
          tokens: tok,
          planner: PlannerController({}),
          plan: YearPlanData(
            today: DateTime(2026, 9, 26),
            firstDay: DateTime(2026, 9, 28),
            terms: [term],
            lessonsOn: (_) => 5,
          ),
          hasTimetable: true,
        ),
      ),
    ));
    await t.pump();
    final segments = find.descendant(
      of: find.byKey(const Key('abs:subjects')),
      matching: find.byType(ColoredBox),
    );
    // missed, planned, free, reserve
    expect(segments, findsNWidgets(4));
    for (final e in segments.evaluate()) {
      final size = (e.renderObject! as RenderBox).size;
      expect(size.height, 8);
      expect(size.width, greaterThan(0));
    }
  });
}

class _SeededAbsAppState extends AppStateController {
  final AppState seeded;
  _SeededAbsAppState(this.seeded);

  @override
  AppState build() {
    seeded.onChanged = () {
      // ignore: avoid_self_assignment
      state = state;
    };
    seeded.onProgress = seeded.onChanged;
    return seeded;
  }
}
