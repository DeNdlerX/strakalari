import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/shell/router.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' show setEnvironmentOverride;

Widget _buildHarness({
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
    tmp = Directory.systemTemp.createTempSync('strakalari_wizard_isolation_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  testWidgets(
      'Fresh install with needsSetup renders wizard full-screen without rail, bottom bar or top bar',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    // Fresh install: no credentials, not dismissed -> needsSetup is true
    expect(state.needsSetup(), isTrue);
    expect(state.setupPending, isTrue);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    // WizardView is displayed
    expect(find.byType(WizardView), findsOneWidget);

    // Shell chrome is absent: no rail, no bottom bar, no topbar status dot or refresh
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('topbar_status_dot')), findsNothing);
    expect(find.byKey(const ValueKey('refresh')), findsNothing);
    expect(find.byKey(const ValueKey('cancel_refresh')), findsNothing);
  });

  testWidgets(
      'Saving credentials mid-wizard keeps wizard full-screen without shell chrome (regression test_wizard_stays_after_bakalari_step)',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    expect(state.needsSetup(), isTrue);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    expect(find.byType(WizardView), findsOneWidget);
    expect(state.wizardShown, isTrue);

    // Simulate step 2 saving Bakalari credentials
    state.save({
      'bakalari_url': 'https://skola.bakalari.cz',
      'bakalari_username': 'novak',
      'bakalari_password': 'secret',
    });
    // needsSetup becomes false, but wizard is mid-run (setupPending is still true)
    expect(state.needsSetup(), isFalse);
    expect(state.setupPending, isTrue);

    await tester.pumpAndSettle();

    // Wizard remains on screen and owns the page (no chrome)
    expect(find.byType(WizardView), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('topbar_status_dot')), findsNothing);
    expect(find.byKey(const ValueKey('refresh')), findsNothing);
  });

  testWidgets(
      'Finishing wizard navigates to /today and restores shell chrome',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    expect(find.byType(WizardView), findsOneWidget);

    // Finish wizard
    state.wizardFinished();
    expect(state.wizardDismissed, isTrue);
    expect(state.setupPending, isFalse);

    await tester.pumpAndSettle();

    // Replaces wizard with shell chrome on /today
    expect(find.byType(WizardView), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar_status_dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('refresh')), findsOneWidget);
  });

  testWidgets(
      'Dismissing wizard navigates to /today and restores shell chrome',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    expect(find.byType(WizardView), findsOneWidget);

    // Dismiss wizard
    state.dismissWizard();
    expect(state.wizardDismissed, isTrue);
    expect(state.setupPending, isFalse);

    await tester.pumpAndSettle();

    // Shell chrome is back
    expect(find.byType(WizardView), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar_status_dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('refresh')), findsOneWidget);
  });
}
