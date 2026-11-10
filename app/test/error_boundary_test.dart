import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/scaffold.dart';
import 'package:app/shell/theme.dart';
import 'package:app/widgets/error_boundary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _CrashingWidget extends StatelessWidget {
  const _CrashingWidget();

  @override
  Widget build(BuildContext context) {
    throw StateError('Simulated view crash in build()');
  }
}

void main() {
  setUp(() {
    installErrorWidgetBuilder();
  });

  tearDown(() {
    restoreErrorWidgetBuilder();
  });

  testWidgets(
      'ViewErrorBoundary catches crashing view build, displays status_error card, and reports to AppState',
      (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;

    final router = GoRouter(
      initialLocation: '/today',
      routes: [
        ShellRoute(
          builder: (context, routerState, child) => AppScaffold(
            location: routerState.uri.path,
            child: child,
          ),
          routes: [
            GoRoute(
              path: '/today',
              builder: (context, routerState) => const _CrashingWidget(),
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: tokensFor('dark').toThemeData(),
        ),
      ),
    );

    // Consume the FlutterError from the crashing widget
    final error = tester.takeException();
    expect(error, isNotNull);
    expect(error, isA<StateError>());

    // Pump to settle post-frame callbacks
    await tester.pump();

    // ViewErrorCard is rendered with status_error text
    expect(find.byKey(const ValueKey('view_error_card')), findsOneWidget);
    expect(find.text(Strings.get('status_error')), findsOneWidget);

    // State recorded the error with correct operation name
    expect(state.lastError, isNotNull);
    expect(state.lastError!['operation'], 'view (today)');
    expect(state.lastError!['summary'], contains('StateError'));

    // AppScaffold top bar and rail are still intact (app did not blank)
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar_status_dot')), findsOneWidget);
  });
}
