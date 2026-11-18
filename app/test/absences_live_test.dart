import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/today/today_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
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
    expect(find.text('Matematika'), findsOneWidget);
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
}
