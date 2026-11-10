import 'package:app/controllers/app_state.dart';
import 'package:app/features/activity/activity_live.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/shell/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Port of `tests/test_settings_refresh_interactive.py` (4 cases).
void main() {
  testWidgets('workerTickDoesNotRebuildSettings', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.setTutorialsEnabled(false);

    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, routerState) => AppScaffold(
            location: '/settings',
            child: const LiveSettingsView(),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData.dark(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Settings is visible.
    expect(find.byType(LiveSettingsView), findsOneWidget);

    // Enter text into the first editable field (e.g. signature).
    final fieldFinder = find.byType(TextField);
    expect(fieldFinder, findsWidgets);
    await tester.enterText(fieldFinder.first, 'Test Signature');
    await tester.pump();
    expect(find.text('Test Signature'), findsOneWidget);

    // Trigger background progress tick while refreshing.
    state.refreshRunning = true;
    state.currentStep = 'stahuji data z Bakalářů…';
    container.read(appStateProvider.notifier).emit();
    await tester.pump();

    // Topbar reflects refresh.
    expect(find.byKey(const ValueKey('cancel_refresh')), findsOneWidget);

    // Settings input remains intact and untouched.
    expect(find.text('Test Signature'), findsOneWidget);
  });

  testWidgets('userNavRebuildsSettingsDuringRefresh', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.setTutorialsEnabled(false);

    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, routerState) => AppScaffold(
            location: '/settings',
            child: const LiveSettingsView(),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData.dark(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Turn refresh on.
    state.refreshRunning = true;
    container.read(appStateProvider.notifier).emit();
    await tester.pump();

    // User navigates to a different section (e.g. limits).
    state.setSettingsSection('limits');
    await tester.pump();

    expect(state.settingsSection, 'limits');
    expect(find.byType(LiveSettingsView), findsOneWidget);
  });

  testWidgets('progressTickRebuildsOnlyTheLiveLogToday', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.setTutorialsEnabled(false);

    var buildCount = 0;
    final router = GoRouter(
      initialLocation: '/today',
      routes: [
        GoRoute(
          path: '/today',
          builder: (context, routerState) {
            buildCount++;
            return AppScaffold(
              location: '/today',
              child: const Scaffold(body: Center(child: Text('TodayBody'))),
            );
          },
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData.dark(),
        ),
      ),
    );
    await tester.pump();

    // Progress tick during refresh.
    state.refreshRunning = true;
    state.currentStep = 'stahuji...';
    container.read(appStateProvider.notifier).emit();
    await tester.pump();

    // Today body wasn't re-routed.
    expect(buildCount, equals(1));
    expect(find.text('TodayBody'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel_refresh')), findsOneWidget);
  });

  testWidgets('progressTickRebuildsOnlyTheLiveLogActivity', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.setTutorialsEnabled(false);

    final router = GoRouter(
      initialLocation: '/activity',
      routes: [
        GoRoute(
          path: '/activity',
          builder: (context, routerState) => const AppScaffold(
            location: '/activity',
            child: LiveActivityView(narrow: false),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData.dark(),
        ),
      ),
    );
    await tester.pump();

    // Append log line during refresh.
    state.refreshRunning = true;
    state.logLine('novy radek v protokolu');
    container.read(appStateProvider.notifier).emit();
    await tester.pump();

    expect(find.textContaining('novy radek v protokolu'), findsOneWidget);
  });
}
