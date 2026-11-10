import 'package:app/features/planner/planner_controller.dart';
import 'package:app/features/planner/planner_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const tplA = 'Template A line1\nA-second-line';
const tplB = 'Template B line1\nB-second-line';

PlannerController createPlannerController() {
  final c = PlannerController({
    'long_absence_excuses': [tplA, tplB],
    'short_absence_excuses': <String>[],
    'late_income_excuses': <String>[],
    'your_signature': '',
  });
  c.stravaEnabled = false;
  return c;
}

Widget buildDialogHost({required Widget child}) {
  return MaterialApp(
    home: Scaffold(
      body: child,
    ),
  );
}

void main() {
  testWidgets('closeDialogPopNoneStillRepaints', (tester) async {
    await tester.pumpWidget(
      buildDialogHost(
        child: Builder(
          builder: (ctx) => TextButton(
            onPressed: () {
              Navigator.of(ctx).maybePop();
            },
            child: const Text('Pop'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pop'));
    await tester.pumpAndSettle();
    expect(find.text('Pop'), findsOneWidget);
  });

  testWidgets('planDialogCancelClosesAndRepaints', (tester) async {
    final controller = createPlannerController();
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanDayDialog(
          controller: controller,
          day: DateTime(2026, 9, 22),
          stravaOn: false,
        ),
      ),
    );
    expect(find.text(Strings.get('cancel')), findsOneWidget);
    await tester.tap(find.text(Strings.get('cancel')));
    await tester.pumpAndSettle();
    expect(controller.plannedSkips, isEmpty);
  });

  testWidgets('planDialogTemplateSelectUpdatesPreview', (tester) async {
    final controller = createPlannerController();
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanDayDialog(
          controller: controller,
          day: DateTime(2026, 9, 22),
          stravaOn: false,
        ),
      ),
    );
    expect(find.text(tplA), findsOneWidget);

    // Open dropdown and select template B
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Šablona 2').last);
    await tester.pumpAndSettle();

    expect(find.text(tplB), findsOneWidget);
  });

  testWidgets('planDialogTemplateSelectDataFallback', (tester) async {
    final controller = createPlannerController();
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanDayDialog(
          controller: controller,
          day: DateTime(2026, 9, 22),
          stravaOn: false,
        ),
      ),
    );
    // Select second item
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Šablona 2').last);
    await tester.pumpAndSettle();
    expect(find.text(tplB), findsOneWidget);
  });

  testWidgets('planDialogConfirmUsesPickedTemplate', (tester) async {
    final controller = createPlannerController();
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanDayDialog(
          controller: controller,
          day: DateTime(2026, 9, 22),
          stravaOn: false,
        ),
      ),
    );
    // Select template B
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Šablona 2').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text(Strings.get('confirm')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    expect(controller.plannedSkips.first['template'], tplB);
  });

  testWidgets('customDialogTemplateSelectAndCancel', (tester) async {
    tester.view.physicalSize = const Size(1280, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = createPlannerController();
    await tester.pumpWidget(
      buildDialogHost(
        child: CustomPlanDialog(
          controller: controller,
          stravaOn: false,
          lessonsFor: (_) => const [],
          freeDays: const {},
          initialMonth: DateTime(2026, 9, 1),
        ),
      ),
    );
    expect(find.text('Šablona 1'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Šablona 2').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text(Strings.get('cancel')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, isEmpty);
  });
}
