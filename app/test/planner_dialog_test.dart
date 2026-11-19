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
        child: PlanMultiDialog(
          controller: controller,
          days: [DateTime(2026, 9, 22)],
          stravaOn: false,
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

  testWidgets(
      'S3 PlanDayDialog defaults cancelLunch on for whole day and flips off for partial unless touched',
      (tester) async {
    final controller = createPlannerController()..stravaEnabled = true;
    final day = DateTime(2026, 9, 22);
    const slots = [
      PickerSlot(period: 1, subject: 'Matematika'),
      PickerSlot(period: 2, subject: 'Fyzika'),
    ];
    Future<void> openDayDialog(PlannerController ctrl) async {
      await tester.pumpWidget(
        buildDialogHost(
          child: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => PlanDayDialog(
                  controller: ctrl,
                  day: day,
                  stravaOn: true,
                  slots: slots,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    await openDayDialog(controller);

    Finder lunchBox() => find.widgetWithText(
      CheckboxListTile,
      Strings.get('plan_cancel_lunch'),
    );
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isTrue);

    // Expand lessons and untick one -> partial day -> cancelLunch auto-flips off.
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. Matematika'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();
    expect(controller.plannedSkips, hasLength(1));
    expect(controller.plannedSkips.first['cancel_lunch'], isFalse);

    // Manually ticking cancelLunch back on sticks even after unticking a lesson.
    final c2 = createPlannerController()..stravaEnabled = true;
    await openDayDialog(c2);
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. Matematika'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isFalse);
    await tester.tap(lunchBox());
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();
    expect(c2.plannedSkips.first['cancel_lunch'], isTrue);
  });

  testWidgets(
      'S3 PlanMultiDialog defaults cancelLunch off when any day is partial and on when all whole',
      (tester) async {
    final day1 = DateTime(2026, 9, 22);
    final day2 = DateTime(2026, 9, 23);
    Finder lunchBox() => find.widgetWithText(
      CheckboxListTile,
      Strings.get('plan_cancel_lunch'),
    );

    // Partial day present -> starts false.
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanMultiDialog(
          controller: createPlannerController()..stravaEnabled = true,
          days: [day1, day2],
          pickedByDay: {day1: {1, 2}, day2: {1}},
          taughtByDay: {day1: {1, 2}, day2: {1, 2}},
          stravaOn: true,
        ),
      ),
    );
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isFalse);

    // All days whole -> starts true.
    await tester.pumpWidget(
      buildDialogHost(
        child: PlanMultiDialog(
          key: const ValueKey('all_whole'),
          controller: createPlannerController()..stravaEnabled = true,
          days: [day1, day2],
          pickedByDay: {day1: {1, 2}, day2: {1, 2}},
          taughtByDay: {day1: {1, 2}, day2: {1, 2}},
          stravaOn: true,
        ),
      ),
    );
    expect(tester.widget<CheckboxListTile>(lunchBox()).value, isTrue);
  });

  testWidgets(
    'PlanMultiDialog skips days missing from non-null pickedByDay (R3c code M5)',
    (tester) async {
      final day1 = DateTime(2026, 9, 22);
      final day2 = DateTime(2026, 9, 23);
      final c = createPlannerController()..stravaEnabled = true;

      await tester.pumpWidget(
        buildDialogHost(
          child: PlanMultiDialog(
            controller: c,
            days: [day1, day2],
            pickedByDay: {day2: {1, 2}},
            taughtByDay: {day1: {1, 2}, day2: {1, 2}},
            stravaOn: true,
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
      await tester.pumpAndSettle();

      expect(c.plannedSkips, hasLength(1));
      expect(c.plannedSkips.single['start_date'], '2026-09-23');
      expect(c.plannedSkips.single['end_date'], '2026-09-23');
    },
  );
}
