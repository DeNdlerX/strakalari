import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/features/planner/planner_view.dart' show PlanDayDialog;
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/today/today_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
import 'package:app/widgets/app_widgets.dart' show EmptyState, Meter, StatCard;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_absences_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('absences controller snapshot mirrors the shared state', () {
    final s = AppState(
      data: {
        'absence': {'Matematika': 12.5, 'Fyzika': 30.0},
        'timetable': {
          '07.09.2026': [
            {
              'subject': 'Matematika',
              'time': '1 (8:00 - 8:45)',
              'absenceType': 'NoAbsent',
              'absencetext': '',
            },
            {
              'subject': 'Fyzika',
              'time': '2 (8:55 - 9:40)',
              'absenceType': 'NoAbsent',
              'absencetext': '',
            },
          ],
        },
      },
    );
    final c = absencesControllerFor(s);
    expect(c.demoMode, isFalse);
    expect(c.subjects, hasLength(2));
    expect(c.subjects.first.name, 'Fyzika');
    expect(c.subjects.first.status, 'critical');
    expect(c.critCount, 1);
  });

  testWidgets('live absences view renders subjects when state updates',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: LiveAbsencesView(tokens: AppTokens.dark(), narrow: false),
        ),
      ),
    ));
    final s = container.read(appStateProvider);
    expect(find.text('Matematika'), findsNothing);
    s.data = {
      'absence': {'Matematika': 8.0},
      'timetable': {
        '07.09.2026': [
          {
            'subject': 'Matematika',
            'time': '1 (8:00 - 8:45)',
            'absenceType': 'NoAbsent',
            'absencetext': '',
          },
        ],
      },
    };
    s.demoMode = false;
    s.onChanged();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('abs:subjects')),
      300,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('abs:subjects')),
        matching: find.text('Matematika'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('/planner redirects to /absences/plan', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = container.read(appStateProvider);
    s.wizardDismissed = true;
    s.setTutorialsEnabled(false);

    final router = buildRouter(initialLocation: '/planner');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTokens.dark().toThemeData(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/absences/plan',
    );
    expect(find.byType(LivePlannerPage), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(7));
    expect(rail.selectedIndex, shellRoutes.indexOf('absences'));
  });

  testWidgets('Today planner suggestion opens absences', (tester) async {
    String? navigated;
    final c = TodayController(onGo: (r) => navigated = r)
      ..plannerRecommended = [DateTime(2026, 9, 15)];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTokens.dark().toThemeData(),
        home: Scaffold(
          body: TodayView(
            controller: c,
            tokens: AppTokens.dark(),
            now: DateTime(2026, 9, 10, 10, 0),
          ),
        ),
      ),
    );
    await tester.pump();

    final tipButton = find.widgetWithText(
      TextButton,
      Strings.get('abs_planner_btn'),
    );
    expect(tipButton, findsOneWidget);
    await tester.tap(tipButton);
    await tester.pump();
    expect(navigated, 'absences/plan?from=today');
  });

  group('F1b real AppState data cases 1-3', () {
    testWidgets('case 1: no timetable shows no_data, planner_need_refresh, and need_credentials in demoMode',
        (tester) async {
      final s = AppState(
        configData: {'tutorials_enabled': false},
        data: const {},
      )..demoMode = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAbsState(s)),
          ],
          child: MaterialApp(
            theme: AppTokens.dark().toThemeData(),
            home: Scaffold(
              body: LiveAbsencesView(tokens: AppTokens.dark(), narrow: false),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(EmptyState),
          matching: find.text(Strings.get('no_data')),
        ),
        findsOneWidget,
      );
      expect(find.text(Strings.get('planner_need_refresh')), findsOneWidget);
      expect(find.text(Strings.get('need_credentials')), findsOneWidget);
    });

    testWidgets(
        'case 2: closed school year (term == null) shows 3 KPIs, Meter, term_nothing, footer, and unplannable planned entry',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final closedNow = DateTime(2027, 6, 15, 10, 0);
      await withClock(Clock.fixed(closedNow), () async {
        final s = AppState(
          configData: {
            'tutorials_enabled': false,
            'school_preset_id': 'custom',
            'sem1_close': '25.01.2027',
            'sem2_close': '26.04.2027',
          },
          data: {
            'absence': {'Matematika': 12.0},
            'timetable': {
              '11.09.2026': [
                {
                  'subject': 'Matematika',
                  'time': '1. 8:00 - 8:45',
                  'absenceType': 'NoAbsent',
                  'absencetext': '',
                },
              ],
            },
          },
        );
        s.demoMode = false;
        expect(s.planCustomSkip('2027-06-20', '2027-06-20', null, null, 'Lékař'),
            isTrue);
        expect(s.yearPlan(closedNow).defaultTerm, isNull);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider.overrideWith(() => _FixedAbsState(s)),
            ],
            child: MaterialApp(
              theme: AppTokens.dark().toThemeData(),
              home: Scaffold(
                body: LiveAbsencesView(
                  tokens: AppTokens.dark(),
                  narrow: false,
                  now: closedNow,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(StatCard), findsNWidgets(3));
        expect(find.byType(Meter), findsOneWidget);

        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('closed_planner'),
            overrides: [
              appStateProvider.overrideWith(() => _FixedAbsState(s)),
            ],
            child: MaterialApp(
              theme: AppTokens.dark().toThemeData(),
              home: Scaffold(
                body: LivePlannerPage(
                  tokens: AppTokens.dark(),
                  narrow: false,
                  now: closedNow,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text(Strings.get('term_nothing')), findsOneWidget);
        expect(find.text(Strings.get('cal_open_calendar')), findsOneWidget);
        expect(
          find.textContaining(Strings.get('planned_title').toUpperCase()),
          findsOneWidget,
        );
        expect(find.textContaining('20.06.2027'), findsWidgets);

        final unplan = find.text(Strings.get('unplan'));
        expect(unplan, findsOneWidget);
        await tester.tap(unplan);
        await tester.pump();
        expect(s.plannedSkips, isEmpty);
      });
    });

    testWidgets(
        'case 3: active term shows 3 KPIs, budget bars, projected %, and single subject card',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final activeNow = DateTime(2026, 9, 10, 10, 0);
      await withClock(Clock.fixed(activeNow), () async {
        final s = AppState(
          configData: {'tutorials_enabled': false},
          data: {
            'absence': {'Matematika': 8.0},
            'timetable': {
              '11.09.2026': [
                {
                  'subject': 'Matematika',
                  'time': '1. 8:00 - 8:45',
                  'absenceType': 'NoAbsent',
                  'absencetext': '',
                },
              ],
            },
          },
        );
        s.demoMode = false;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider.overrideWith(() => _FixedAbsState(s)),
            ],
            child: MaterialApp(
              theme: AppTokens.dark().toThemeData(),
              home: Scaffold(
                body: LiveAbsencesView(
                  tokens: AppTokens.dark(),
                  narrow: false,
                  now: activeNow,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(StatCard), findsNWidgets(3));
        expect(find.byKey(const Key('abs:next_plan_row')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('abs:subjects')),
            matching: find.text('Matematika'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('abs:subjects')),
            matching: find.text('8.0 %'),
          ),
          findsOneWidget,
        );
        expect(find.text(Strings.get('abs_subjects_section').toUpperCase()),
            findsOneWidget);
        expect(find.byType(Meter), findsNothing);
      });
    });
  });

  testWidgets('F1b custom calendar receives real lessons and plans a day (R3b code M2)',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final activeNow = DateTime(2026, 9, 10, 10, 0);
    await withClock(Clock.fixed(activeNow), () async {
      final week = <String, List<Map<String, Object?>>>{};
      for (final day in [7, 8, 9, 10, 11]) {
        final key = '${day.toString().padLeft(2, '0')}.09.2026';
        week[key] = [
          {
            'subject': 'Matematika',
            'time': '1 (8:00 - 8:45)',
            'teacher': 'Jan Novák',
            'room': '101',
            'absenceType': 'NoAbsent',
            'absencetext': '',
          },
          {
            'subject': 'Fyzika',
            'time': '2 (8:55 - 9:40)',
            'teacher': 'Eva Malá',
            'room': '102',
            'absenceType': 'NoAbsent',
            'absencetext': '',
          },
        ];
      }
      final s = AppState(
        configData: {
          'tutorials_enabled': false,
          'school_preset_id': 'custom',
          'sem1_close': '25.01.2027',
          'sem2_close': '26.04.2027',
          'user_free_days': ['15.09.2026'],
        },
        data: {
          'absence': {'Matematika': 8.0, 'Fyzika': 5.0},
          'timetable': week,
        },
      );
      s.demoMode = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAbsState(s)),
          ],
          child: MaterialApp(
            theme: AppTokens.dark().toThemeData(),
            home: Scaffold(
              body: LivePlannerPage(
                tokens: AppTokens.dark(),
                narrow: false,
                now: activeNow,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Past day (Sep 8) and free day (Sep 15) cannot be tapped.
      final pastCell = tester.widget<InkWell>(
        find.byKey(const ValueKey('day_2026_9_8')),
      );
      expect(pastCell.onTap, isNull);
      final freeCell = tester.widget<InkWell>(
        find.byKey(const ValueKey('day_2026_9_15')),
      );
      expect(freeCell.onTap, isNull);

      // Tapping a future school day (Mon Sep 14) opens PlanDayDialog and confirms.
      await tester.tap(find.byKey(const ValueKey('day_2026_9_14')));
      await tester.pumpAndSettle();
      expect(find.byType(PlanDayDialog), findsOneWidget);

      final confirmFinder = find.widgetWithText(
        FilledButton,
        Strings.get('confirm'),
      );
      expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNotNull);

      await tester.tap(confirmFinder);
      await tester.pumpAndSettle();

      expect(s.plannedSkips, hasLength(1));
      expect(s.plannedSkips.first['start_date'], '2026-09-14');
      expect(s.plannedSkips.first['end_date'], '2026-09-14');
    });
  });

  testWidgets(
      'S1 selecting sem2 in LivePlannerPage never switches LiveAbsencesView away from defaultTerm',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Strings.lang = 'cs';

    final now = DateTime(2026, 11, 10, 10, 0);
    await withClock(Clock.fixed(now), () async {
      final s = AppState(
        configData: {
          'tutorials_enabled': false,
          'school_preset_id': 'custom',
          'sem1_close': '25.01.2027',
          'sem2_close': '26.04.2027',
        },
        data: {
          'absence': {'Matematika': 8.0},
          'timetable': {
            '09.11.2026': [
              {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)'},
            ],
            '11.11.2026': [
              {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)'},
            ],
          },
        },
      )..demoMode = false;

      final sem1Default = s.yearPlan(now).defaultTerm!;
      expect(sem1Default.key, 'sem1');
      final sem1Next = sem1Default.recommended.first.day;

      // Switch Plánovač to sem2.
      s.selectPlannerTerm('sem2');
      expect(s.plannerTerm, 'sem2');

      // AbsencesController and LiveAbsencesView still stay on sem1 (defaultTerm).
      final absCtrl = absencesControllerFor(s, now);
      expect(
        absCtrl.budgets?['matematika']?.freeHours,
        sem1Default.budgetByCanon['matematika']?.freeHours,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAbsState(s)),
          ],
          child: MaterialApp(
            theme: AppTokens.dark().toThemeData(),
            home: Scaffold(
              body: LiveAbsencesView(
                tokens: AppTokens.dark(),
                narrow: false,
                now: now,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('abs:next_plan_row')),
          matching: find.textContaining('${sem1Next.day}. ${sem1Next.month}.'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets(
      'S11 pickerSlotsForMonth recomputes today live: lesson pickable at 7:50 becomes pick_started at 8:05 without refresh',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Strings.lang = 'cs';

    final t750 = DateTime(2026, 9, 10, 7, 50);
    final t805 = DateTime(2026, 9, 10, 8, 5);
    final s = AppState(
      configData: {
        'tutorials_enabled': false,
        'school_preset_id': 'custom',
        'sem1_close': '25.01.2027',
        'sem2_close': '26.04.2027',
      },
      data: {
        'absence': {'Matematika': 5.0, 'Fyzika': 5.0},
        'timetable': {
          '10.09.2026': [
            {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)'},
            {'subject': 'Fyzika', 'time': '2 (9:55 - 10:40)'},
          ],
        },
      },
    )..demoMode = false;

    final revBefore = s.dataRev;

    // 7:50 -> lesson 1 (8:00) is pickable.
    await withClock(Clock.fixed(t750), () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAbsState(s)),
          ],
          child: MaterialApp(
            theme: AppTokens.dark().toThemeData(),
            home: Scaffold(
              body: LivePlannerPage(
                tokens: AppTokens.dark(),
                narrow: false,
                now: t750,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('day_2026_9_10')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan:choose_lessons')));
      await tester.pumpAndSettle();

      final mat750 = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '1. Matematika'),
      );
      expect(mat750.onChanged, isNotNull);
      await tester.tap(find.text(Strings.get('cancel')));
      await tester.pumpAndSettle();
    });

    // 8:05, SAME AppState and dataRev (no refresh between) -> lesson 1 is locked with pick_started.
    expect(s.dataRev, revBefore);
    await withClock(Clock.fixed(t805), () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAbsState(s)),
          ],
          child: MaterialApp(
            theme: AppTokens.dark().toThemeData(),
            home: Scaffold(
              body: LivePlannerPage(
                tokens: AppTokens.dark(),
                narrow: false,
                now: t805,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('day_2026_9_10')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan:choose_lessons')));
      await tester.pumpAndSettle();

      final mat805 = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '1. Matematika'),
      );
      expect(mat805.onChanged, isNull);
      expect(find.textContaining(Strings.get('pick_started')), findsOneWidget);
    });
  });

  test('F1b pickerSlotsFor flags cancelled, event, substitution, past, planned, and off-days (R3b code M2)',
      () {
    final now = DateTime(2026, 9, 10, 9, 0); // Thu 9:00
    final s = AppState(
      configData: {
        'school_preset_id': 'custom',
        'sem1_close': '25.01.2027',
        'sem2_close': '26.04.2027',
        'user_free_days': ['15.09.2026'],
      },
      data: {
        'absence': {'Matematika': 5.0, 'Fyzika': 5.0, 'Chemie': 5.0},
        'timetable': {
          // Today (Thu 10.09): p1 already started (8:00), p2 ahead (9:55),
          // p3 cancelled, p4 class event, p5 substitution.
          '10.09.2026': [
            {
              'subject': 'Matematika',
              'time': '1 (8:00 - 8:45)',
              'teacher': 'Jan Novák',
              'room': '101',
            },
            {
              'subject': 'Fyzika',
              'time': '2 (9:55 - 10:40)',
              'teacher': 'Eva Malá',
              'room': '102',
            },
            {
              'subject': 'Chemie',
              'time': '3 (10:50 - 11:35)',
              'notice': 'Odpadá',
            },
            {
              'subject': 'Exkurze',
              'time': '4 (11:45 - 12:30)',
              'type': 'event',
            },
            {
              'subject': 'Matematika',
              'time': '5 (12:40 - 13:25)',
              'notice': 'Suplování',
              'changeBadgeChar': 'S',
            },
          ],
          // Tomorrow (Fri 11.09): p1 planned, p2 open.
          '11.09.2026': [
            {
              'subject': 'Matematika',
              'time': '1 (8:00 - 8:45)',
            },
            {
              'subject': 'Fyzika',
              'time': '2 (8:55 - 9:40)',
            },
          ],
        },
      },
    )..demoMode = false;

    expect(
      s.planCustomSkip('2026-09-11', '2026-09-11', 1, 1, 'Lékař'),
      isTrue,
    );

    final todaySlots = s.pickerSlotsFor(DateTime(2026, 9, 10), now);
    expect(todaySlots, hasLength(5));
    expect(todaySlots[0].past, isTrue);
    expect(todaySlots[0].pickable, isFalse);
    expect(todaySlots[1].past, isFalse);
    expect(todaySlots[1].pickable, isTrue);
    expect(todaySlots[2].taught, isFalse);
    expect(todaySlots[2].changed, isTrue);
    expect(todaySlots[2].pickable, isFalse);
    expect(todaySlots[3].taught, isFalse);
    expect(todaySlots[3].changed, isTrue);
    expect(todaySlots[3].pickable, isFalse);
    expect(todaySlots[4].taught, isTrue);
    expect(todaySlots[4].changed, isTrue);
    expect(todaySlots[4].pickable, isTrue);

    final tomorrowSlots = s.pickerSlotsFor(DateTime(2026, 9, 11), now);
    expect(tomorrowSlots, hasLength(2));
    expect(tomorrowSlots[0].planned, isTrue);
    expect(tomorrowSlots[0].pickable, isFalse);
    expect(tomorrowSlots[1].planned, isFalse);
    expect(tomorrowSlots[1].pickable, isTrue);

    // Weekend, free day, and after closure return empty.
    expect(s.pickerSlotsFor(DateTime(2026, 9, 12), now), isEmpty);
    expect(s.pickerSlotsFor(DateTime(2026, 9, 15), now), isEmpty);
    expect(s.pickerSlotsFor(DateTime(2027, 4, 27), now), isEmpty);
  });
}

class _FixedAbsState extends AppStateController {
  final AppState fixed;
  _FixedAbsState(this.fixed);

  @override
  AppState build() {
    fixed.onChanged = () {
      // ignore: avoid_self_assignment
      state = state;
    };
    fixed.onProgress = fixed.onChanged;
    return fixed;
  }
}
