import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/common/app_tokens.dart';
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

  testWidgets('/planner redirects to /absences', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = container.read(appStateProvider);
    s.wizardDismissed = true;
    s.setTutorialsEnabled(false);

    final router = buildRouter(initialLocation: '/planner');
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

    expect(router.routerDelegate.currentConfiguration.uri.path, '/absences');
    expect(find.byType(LiveAbsencesView), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(7));
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
      Strings.get('nav_absences'),
    );
    expect(tipButton, findsOneWidget);
    await tester.tap(tipButton);
    await tester.pump();
    expect(navigated, 'absences');
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
        'case 3: active term shows 4 KPIs, budget bars, projected %, and single subject card',
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

        expect(find.byType(StatCard), findsNWidgets(4));
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
