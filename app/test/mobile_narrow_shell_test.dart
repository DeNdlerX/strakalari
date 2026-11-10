import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/shell/router.dart';
import 'package:app/shell/scaffold.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
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

    testWidgets('everyScreenBuilds', (tester) async {
      setViewport(tester, 1280, 800);
      for (final route in [
        '/today',
        '/timetable',
        '/absences',
        '/marks',
        '/planner',
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
        container.dispose();
      }
    });

    test('backStepsUp', () {
      expect(
        backTarget(route: 'today', narrow: true, wizardShown: false),
        isNull,
      );
      expect(
        backTarget(route: 'planner', narrow: true, wizardShown: false),
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
        backTarget(route: 'planner', narrow: false, wizardShown: false),
        'today',
      );
      expect(
        backTarget(route: 'planner', narrow: true, wizardShown: true),
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
  });
}
