import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
import 'package:app/shell/scaffold.dart';
import 'package:app/shell/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

Widget buildShellHarness({
  required ProviderContainer container,
  String initialLocation = '/today',
}) {
  final router = buildRouter(initialLocation: initialLocation);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      theme: tokensFor('dark').toThemeData(),
    ),
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_narrow_shell_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void setViewport(WidgetTester tester, double w, double h) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('TestNarrowShell', () {
    testWidgets('bottomBarInsteadOfRail', (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(buildShellHarness(container: container));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('widePageKeepsTheRail', (tester) async {
      setViewport(tester, 1240, 800);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(buildShellHarness(container: container));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('moreScreensSelectMore', (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(
        buildShellHarness(container: container, initialLocation: '/settings'),
      );
      await tester.pumpAndSettle();

      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 4); // 'more' is index 4 in narrowTabs
    });

    testWidgets('landscapePhoneGetsSideRail', (tester) async {
      setViewport(tester, 915, 411);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(buildShellHarness(container: container));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(layoutForSize(915, 411), ShellLayout.side);
    });

    testWidgets('rotatingSwapsBarAndSideRail', (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(buildShellHarness(container: container));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);

      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    test('layoutBySize', () {
      expect(layoutForSize(390, 844), ShellLayout.bar);
      expect(layoutForSize(844, 390), ShellLayout.side);
      expect(layoutForSize(600, 960), ShellLayout.bar);
      expect(layoutForSize(960, 600), ShellLayout.wide);
      expect(layoutForSize(768, 1024), ShellLayout.wide);
      expect(layoutForSize(1024, 768), ShellLayout.wide);
      expect(layoutForSize(1240, 800), ShellLayout.wide);
    });

    testWidgets('wideningLeavesMore', (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;

      await tester.pumpWidget(
        buildShellHarness(container: container, initialLocation: '/more'),
      );
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1240, 800);
      await tester.pumpAndSettle();

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 0); // redirected to today
    });

    // test_mobile.py::test_every_screen_builds: phone page 390x844, no
    // `report_error` for any of the live routes; `/planner` redirects to `/absences/plan`.
    testWidgets('everyScreenBuilds', (tester) async {
      setViewport(tester, 390, 844);
      for (final route in [
        '/today',
        '/timetable',
        '/absences',
        '/absences/plan',
        '/absences/limits',
        '/marks',
        '/lunches',
        '/activity',
        '/settings',
        '/more',
      ]) {
        final container = ProviderContainer();
        final state = container.read(appStateProvider);
        state.wizardDismissed = true;

        await tester.pumpWidget(
          buildShellHarness(container: container, initialLocation: route),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(state.lastError, isNull, reason: route);
        container.dispose();
      }
      // Compatibility redirect: `/planner` lands on `/absences/plan`.
      expect(routeForLocation('/planner'), 'absences/plan');
      final container = ProviderContainer();
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      await tester.pumpWidget(
        buildShellHarness(container: container, initialLocation: '/planner'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(state.lastError, isNull);
      final router = GoRouter.of(tester.element(find.byType(NavigationBar)));
      expect(router.routerDelegate.currentConfiguration.uri.path, '/absences/plan');
      container.dispose();
    });

    test('backStepsUp', () {
      expect(
        backTarget(route: 'today', narrow: true, wizardShown: false),
        isNull,
      );
      expect(
        backTarget(route: 'absences', narrow: true, wizardShown: false),
        'more',
      );
      expect(
        backTarget(route: 'more', narrow: true, wizardShown: false),
        'today',
      );
      expect(
        backTarget(route: 'marks', narrow: true, wizardShown: false),
        'today',
      );
      expect(
        backTarget(route: 'absences', narrow: false, wizardShown: false),
        'today',
      );
      expect(
        backTarget(route: 'absences', narrow: true, wizardShown: true),
        isNull,
      );
    });

    test('backClosesOpenSettingsSectionFirst', () {
      final state = AppState();
      state.setSettingsSection('accounts');
      expect(state.settingsOpen, isTrue);
      expect(
        subpageOpen(route: 'settings', narrow: true, state: state),
        'settings',
      );

      closeSubpage(route: 'settings', narrow: true, state: state);
      expect(state.settingsOpen, isFalse);
      expect(
        subpageOpen(route: 'settings', narrow: true, state: state),
        isEmpty,
      );

      // Marks subpage
      state.marksSelected = 'Matematika';
      expect(
        subpageOpen(route: 'marks', narrow: true, state: state),
        'marks',
      );
      closeSubpage(route: 'marks', narrow: true, state: state);
      expect(state.marksSelected, isNull);

      // Lunches subpage
      state.lunchToolsOpen = true;
      expect(
        subpageOpen(route: 'lunches', narrow: true, state: state),
        'lunches',
      );
      closeSubpage(route: 'lunches', narrow: true, state: state);
      expect(state.lunchToolsOpen, isFalse);
    });

    testWidgets(
        'P9c More subpages show top-bar back button on phone and navigate back to More',
        (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);

      // Top-level tabs must NOT show back button.
      await tester.pumpWidget(
        buildShellHarness(container: container, initialLocation: '/today'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('topbar_back_btn')), findsNothing);

      // Visiting each More subpage on phone shows top-bar back button -> /more.
      for (final loc in ['/absences', '/activity', '/settings']) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final s = c.read(appStateProvider);
        s.wizardDismissed = true;
        s.setTutorialsEnabled(false);

        await tester.pumpWidget(
          buildShellHarness(container: c, initialLocation: loc),
        );
        await tester.pumpAndSettle();

        final backBtn = find.byKey(const ValueKey('topbar_back_btn'));
        expect(backBtn, findsOneWidget, reason: '$loc must have back button');
        await tester.tap(backBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('topbar_back_btn')), findsNothing,
            reason: 'after tapping back from $loc, /more has no back button');
        final router = GoRouter.of(tester.element(find.byType(NavigationBar)));
        expect(router.routerDelegate.currentConfiguration.uri.path, '/more',
            reason: 'back from $loc must land on More');
      }
    });

    testWidgets(
        'P9c an open Settings section shows only its own back arrow, not a second one in the top bar',
        (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);

      await tester.pumpWidget(
        buildShellHarness(container: container, initialLocation: '/settings'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('topbar_back_btn')), findsOneWidget);

      state.setSettingsSection('wakeup');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('topbar_back_btn')), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(state.settingsOpen, isFalse);
      expect(find.byKey(const ValueKey('topbar_back_btn')), findsOneWidget);
    });

    test('O7 backTarget honors sanitized ?from= origin for absences sub-routes',
        () {
      expect(
        backTarget(
          route: 'absences/limits',
          narrow: true,
          wizardShown: false,
          from: 'settings',
        ),
        'settings',
      );
      expect(
        backTarget(
          route: 'absences/limits',
          narrow: true,
          wizardShown: false,
          from: null,
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/limits',
          narrow: true,
          wizardShown: false,
          from: 'absences',
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/limits',
          narrow: true,
          wizardShown: false,
          from: 'bogus',
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/plan',
          narrow: true,
          wizardShown: false,
          from: 'today',
        ),
        'today',
      );
      expect(
        backTarget(
          route: 'absences/plan',
          narrow: true,
          wizardShown: false,
          from: null,
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/plan',
          narrow: true,
          wizardShown: false,
          from: 'absences',
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/plan',
          narrow: true,
          wizardShown: false,
          from: 'bogus',
        ),
        'absences',
      );
      expect(
        backTarget(
          route: 'absences/plan',
          narrow: true,
          wizardShown: true,
          from: 'today',
        ),
        isNull,
      );
    });

    testWidgets(
        'O7 AppScaffold keeps Absences selected on wide rail and More on phone bar without duplicate topbar_back_btn',
        (tester) async {
      for (final loc in ['/absences/plan', '/absences/limits']) {
        // Wide rail: Absences selected, no topbar_back_btn.
        setViewport(tester, 1240, 800);
        final wideContainer = ProviderContainer();
        addTearDown(wideContainer.dispose);
        final wideState = wideContainer.read(appStateProvider);
        wideState.wizardDismissed = true;
        wideState.setTutorialsEnabled(false);

        await tester.pumpWidget(
          buildShellHarness(container: wideContainer, initialLocation: loc),
        );
        await tester.pumpAndSettle();

        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.selectedIndex, shellRoutes.indexOf('absences'), reason: loc);
        expect(find.byKey(const ValueKey('topbar_back_btn')), findsNothing,
            reason: loc);

        // Phone portrait: More selected, no topbar_back_btn (page owns single arrow).
        setViewport(tester, 390, 844);
        final phoneContainer = ProviderContainer();
        addTearDown(phoneContainer.dispose);
        final phoneState = phoneContainer.read(appStateProvider);
        phoneState.wizardDismissed = true;
        phoneState.setTutorialsEnabled(false);

        await tester.pumpWidget(
          buildShellHarness(container: phoneContainer, initialLocation: loc),
        );
        await tester.pumpAndSettle();

        final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(navBar.selectedIndex, narrowTabs.indexOf('more'), reason: loc);
        expect(find.byKey(const ValueKey('topbar_back_btn')), findsNothing,
            reason: loc);
      }
    });

    testWidgets(
        'O7/M4 live Today tip opens /absences/plan?from=today, plan:back_btn returns to /today, and bogus pendingRoute is cleared',
        (tester) async {
      setViewport(tester, 390, 844);
      Strings.lang = 'cs';
      final fixedNow = DateTime(2026, 9, 10, 10, 0);
      await withClock(Clock.fixed(fixedNow), () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final state = container.read(appStateProvider);
        state.wizardDismissed = true;
        state.setTutorialsEnabled(false);
        state.demoMode = false;
        state.data = {
          'absence': {'Matematika': 2.0},
          'timetable': {
            '11.09.2026': [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
            ],
          },
        };

        final router = buildRouter(initialLocation: '/today');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: tokensFor('dark').toThemeData(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final tipBtn = find.widgetWithText(
          TextButton,
          Strings.get('abs_planner_btn'),
        );
        expect(tipBtn, findsOneWidget);
        await tester.tap(tipBtn);
        await tester.pumpAndSettle();

        expect(
          router.routerDelegate.currentConfiguration.uri.toString(),
          '/absences/plan?from=today',
        );
        expect(find.byType(LivePlannerPage), findsOneWidget);

        await tester.tap(find.byKey(const Key('plan:back_btn')));
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/today');

        // A pendingRoute that matches nothing is cleared rather than sticking.
        state.pendingRoute = 'bogus/nowhere';
        state.onChanged();
        await tester.pumpAndSettle();
        expect(state.pendingRoute, isNull);
        expect(router.routerDelegate.currentConfiguration.uri.path, '/today');
      });
    });

    testWidgets(
        'O8 applyLaunchRoute opens matching routes, legacy planner, alarm section, unknown -> today, and drops while wizard is open',
        (tester) async {
      setViewport(tester, 390, 844);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);

      final router = buildRouter(initialLocation: '/today');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: tokensFor('dark').toThemeData(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      String currentPath() =>
          router.routerDelegate.currentConfiguration.uri.path;

      state.applyLaunchRoute('marks');
      await tester.pumpAndSettle();
      expect(currentPath(), '/marks');

      state.applyLaunchRoute('absences/plan');
      await tester.pumpAndSettle();
      expect(currentPath(), '/absences/plan');

      state.applyLaunchRoute('planner');
      await tester.pumpAndSettle();
      expect(currentPath(), '/absences/plan');

      state.applyLaunchRoute('alarm');
      await tester.pumpAndSettle();
      expect(currentPath(), '/settings');
      expect(state.settingsSection, 'alarm');
      expect(state.settingsOpen, isTrue);

      state.applyLaunchRoute('not/a/real/route');
      await tester.pumpAndSettle();
      expect(currentPath(), '/today');

      // While wizard is open (setupPending), launch routes are dropped and
      // never hijack /wizard.
      final wizContainer = ProviderContainer();
      addTearDown(wizContainer.dispose);
      final wizState = wizContainer.read(appStateProvider);
      expect(wizState.setupPending, isTrue);
      final wizRouter = buildRouter(initialLocation: '/today');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          key: const ValueKey('o8_wizard_scope'),
          container: wizContainer,
          child: MaterialApp.router(
            routerConfig: wizRouter,
            theme: tokensFor('dark').toThemeData(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(wizRouter.routerDelegate.currentConfiguration.uri.path, '/wizard');

      wizState.applyLaunchRoute('marks');
      await tester.pumpAndSettle();
      expect(wizState.pendingRoute, isNull);
      expect(wizRouter.routerDelegate.currentConfiguration.uri.path, '/wizard');
    });
  });
}
