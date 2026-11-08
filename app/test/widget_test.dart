// App smoke test: the Flutter shell boots and every route builds.
//
// Replaces the flutter-create counter template test (that widget no longer
// exists). Port of the intent behind `test_ui_views.py`: the app starts on
// a fresh data-less state and every screen renders without throwing.
import 'package:app/main.dart';
import 'package:app/shell/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('App boots and shows the shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pumpAndSettle();
    // Wide test surface (800x600): the extended rail.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });

  testWidgets('Router builds every main screen without throwing',
      (WidgetTester tester) async {
    // Desktop-sized surface: some settings/wizard columns are taller
    // than the default 600 px test viewport (same as a small window).
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    final router =
        GoRouter.of(tester.element(find.byType(Scaffold).first));
    for (final name in [
      'today',
      'timetable',
      'absences',
      'marks',
      'planner',
      'lunches',
      'activity',
      'settings',
      'more',
      'wizard',
    ]) {
      router.go('/$name');
      await tester.pumpAndSettle();
    }
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  test('Layout breakpoints match the Python shell', () {
    // Port of `is_narrow()` / `layout_for()` boundary values.
    expect(isNarrowSize(719, 800), isTrue);
    expect(isNarrowSize(1280, 800), isFalse);
    expect(isNarrowSize(1280, 519), isTrue);
    expect(layoutForSize(1280, 800), ShellLayout.wide);
    expect(layoutForSize(390, 844), ShellLayout.bar);
    expect(layoutForSize(844, 390), ShellLayout.side);
  });
}
