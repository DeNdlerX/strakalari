import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/scaffold.dart';
import 'package:app/shell/theme.dart';

Widget _buildTestApp({
  required ProviderContainer container,
}) {
  final router = GoRouter(
    initialLocation: '/today',
    routes: [
      GoRoute(
        path: '/today',
        builder: (context, routerState) => AppScaffold(
          location: '/today',
          child: const Scaffold(body: Center(child: Text('TodayContent'))),
        ),
      ),
      GoRoute(
        path: '/activity',
        builder: (context, routerState) => AppScaffold(
          location: '/activity',
          child: const Scaffold(body: Center(child: Text('ActivityContent'))),
        ),
      ),
    ],
  );

  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      theme: ThemeData.dark(),
    ),
  );
}

void main() {
  group('TopBar tests (B-M1 parity)', () {
    testWidgets('idle status shows idle dot and idle text with tooltip',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      // Top bar has no AppBar title
      expect(find.byType(AppBar), findsNothing);

      // Status pill
      expect(find.text(Strings.get('status_idle')), findsOneWidget);
      final dot = tester.widget<Container>(find.byKey(const ValueKey('topbar_status_dot')));
      final tok = tokensFor('dark');
      expect((dot.decoration as BoxDecoration).color, tok.faint);

      // Refresh button in wide layout is FilledButton
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text(Strings.get('refresh_data')), findsOneWidget);
    });

    testWidgets('status ok shows ok dot and last run label', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      state.runs.add({'finished': '10:00:00', 'ok': true});

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      expect(find.textContaining(Strings.get('status_ok')), findsOneWidget);
      expect(find.textContaining('✓ 10:00:00'), findsOneWidget);

      final dot = tester.widget<Container>(find.byKey(const ValueKey('topbar_status_dot')));
      final tok = tokensFor('dark');
      expect((dot.decoration as BoxDecoration).color, tok.green);
    });

    testWidgets('status error shows error dot and error detail', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      state.status = 'error';
      state.runs.add({'finished': '10:00:00', 'ok': false, 'detail': 'Bakaláři nedostupní'});

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      expect(find.textContaining(Strings.get('status_error')), findsOneWidget);
      expect(find.textContaining('Bakaláři nedostupní'), findsOneWidget);

      final dot = tester.widget<Container>(find.byKey(const ValueKey('topbar_status_dot')));
      final tok = tokensFor('dark');
      expect((dot.decoration as BoxDecoration).color, tok.red);
    });

    testWidgets('tapping status pill navigates to Activity', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      expect(find.text('TodayContent'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('topbar_status_pill')));
      await tester.pumpAndSettle();

      expect(find.text('ActivityContent'), findsOneWidget);
    });

    testWidgets('update banner shows ghost button in wide and icon button in narrow',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      state.updateInfo = {
        'version': '9.9.9',
        'url': 'https://example.com/v9.9.9',
      };

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      // Wide mode shows TextButton with version
      final updateText = Strings.format('update_available', {'v': '9.9.9'});
      expect(find.text(updateText), findsOneWidget);
      expect(find.byKey(const ValueKey('topbar_update_btn')), findsOneWidget);

      // Narrow mode (phone portrait)
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      // Narrow shows icon button with tooltip
      expect(find.byKey(const ValueKey('topbar_update_btn')), findsOneWidget);
    });

    testWidgets('refreshing state shows spinner and close button that cancels refresh',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      state.refreshRunning = true;
      state.currentStep = 'Stahuji rozvrh…';

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pump();

      expect(find.text('Stahuji rozvrh…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel_refresh')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cancel_refresh')));
      await tester.pump();

      expect(state.cancelRequested, isTrue);
    });

    testWidgets('refresh button click triggers refresh and snacks', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      var spawned = 0;
      state.spawn = (job, name) {
        spawned++;
      };

      await tester.pumpWidget(_buildTestApp(container: container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('refresh')));
      await tester.pump();

      expect(spawned, 1);
      expect(state.refreshRunning, isTrue);
      expect(find.text(Strings.get('refresh_started')), findsOneWidget);
    });
  });
}
