import 'package:app/controllers/app_state.dart';
import 'package:app/shell/router.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  testWidgets(
      'Wide layout renders standard 90px rail with padding and border divider',
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
    state.wizardDismissed = true;
    state.orders['2026-11-16'] = '1';
    state.orders['2026-11-17'] = '2';
    state.orders['2026-11-18'] = '1';
    state.pendingOrders.addAll(['2026-11-16', '2026-11-17', '2026-11-18']);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    final railFinder = find.byType(NavigationRail);
    expect(railFinder, findsOneWidget);
    final rail = tester.widget<NavigationRail>(railFinder);

    expect(rail.extended, isFalse);
    expect(rail.minWidth, 90);
    expect(rail.labelType, NavigationRailLabelType.all);

    // Lunch label on wide rail appends (count)
    expect(find.textContaining(' (3)'), findsOneWidget);

    // Divider
    final dividerFinder = find.byType(VerticalDivider);
    expect(dividerFinder, findsOneWidget);
    final divider = tester.widget<VerticalDivider>(dividerFinder);
    final tok = tokensFor('dark');
    expect(divider.color, tok.border);
    expect(divider.width, 1);
    expect(divider.thickness, 1);

    // Content padding
    final paddingFinder = find.byWidgetPredicate(
      (w) => w is Padding && w.padding == EdgeInsets.all(tok.pad + 8),
    );
    expect(paddingFinder, findsOneWidget);
  });

  testWidgets(
      'Side layout (landscape phone) renders side rail with all labels, centered group, and badge',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.orders['2026-11-16'] = '1';
    state.orders['2026-11-17'] = '2';
    state.pendingOrders.addAll(['2026-11-16', '2026-11-17']);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    final railFinder = find.byType(NavigationRail);
    expect(railFinder, findsOneWidget);
    final rail = tester.widget<NavigationRail>(railFinder);

    expect(rail.labelType, NavigationRailLabelType.all);
    expect(rail.groupAlignment, 0.0);

    // Side rail lunch icon has a Badge
    final badgeFinder = find.descendant(
      of: railFinder,
      matching: find.byType(Badge),
    );
    expect(badgeFinder, findsOneWidget);
    expect(find.descendant(of: badgeFinder, matching: find.text('2')),
        findsOneWidget);

    // Content padding on phone
    final paddingFinder = find.byWidgetPredicate(
      (w) =>
          w is Padding &&
          w.padding ==
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
    expect(paddingFinder, findsOneWidget);

    // Divider
    final dividerFinder = find.byType(VerticalDivider);
    expect(dividerFinder, findsOneWidget);
    final divider = tester.widget<VerticalDivider>(dividerFinder);
    final tok = tokensFor('dark');
    expect(divider.color, tok.border);
    expect(divider.width, 1);
    expect(divider.thickness, 1);
  });

  testWidgets('Bar layout (portrait phone) renders navigation bar with badge',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    state.orders['2026-11-16'] = '1';
    state.orders['2026-11-17'] = '2';
    state.orders['2026-11-18'] = '1';
    state.orders['2026-11-19'] = '2';
    state.orders['2026-11-20'] = '1';
    state.pendingOrders.addAll([
      '2026-11-16',
      '2026-11-17',
      '2026-11-18',
      '2026-11-19',
      '2026-11-20',
    ]);

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);

    // Lunch icon has badge
    final badgeFinder = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byType(Badge),
    );
    expect(badgeFinder, findsOneWidget);
    expect(find.descendant(of: badgeFinder, matching: find.text('5')),
        findsOneWidget);

    // Content padding
    final paddingFinder = find.byWidgetPredicate(
      (w) =>
          w is Padding &&
          w.padding ==
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
    expect(paddingFinder, findsOneWidget);
  });

  testWidgets('Rotating swaps bar and side rail',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;

    await tester.pumpWidget(_buildHarness(container: container));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // Rotate to portrait phone
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('Widening leaves more and navigates to today',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;

    await tester.pumpWidget(
      _buildHarness(container: container, initialLocation: '/more'),
    );
    await tester.pumpAndSettle();

    // Widen to desktop
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.selectedIndex, 0); // today is index 0 in shellRoutes
  });
}
